"""Entry point: `stems-tool tags ...` handles metadata tagging, `stems-tool
beats <wav> [min_bpm max_bpm]` tracks beats, otherwise demucs."""

import json
import sys

# mutagen "easy" keys — uniform across mp3/m4a/flac/ogg
EASY_KEYS = [
    "title", "artist", "album", "albumartist", "genre", "date",
    "tracknumber", "discnumber", "bpm", "composer", "isrc",
    "grouping", "mood", "organization", "copyright", "lyricist",
    "language", "originaldate", "version", "catalognumber", "barcode",
    "replaygain_track_gain", "compilation",
]

# iTunes-style freeform atoms for the fields mp4 has no standard atom for
M4A_KEY = "----:com.apple.iTunes:initialkey"
M4A_REMIXER = "----:com.apple.iTunes:remixer"
M4A_RATING = "----:com.apple.iTunes:RATING"


def _stars(value):
    """Normalize a stored rating to 0-5 stars: POPM uses 0-255 with the WMP
    breakpoints, the vorbis/freeform convention is 0-100."""
    if value <= 5:
        return value
    if value > 100:
        for boundary, stars in ((224, 5), (160, 4), (96, 3), (32, 2), (1, 1)):
            if value >= boundary:
                return stars
        return 0
    return min(5, int(value / 20 + 0.5))
M4A = ("m4a", "mp4", "aac")


def _ext(path):
    return path.rsplit(".", 1)[-1].lower()


def _read_comment(raw, ext):
    try:
        if ext == "mp3":
            frames = raw.tags.getall("COMM")
            if frames and frames[0].text:
                return str(frames[0].text[0])
        elif ext in M4A:
            values = raw.tags.get("\xa9cmt")
            if values:
                return str(values[0])
        else:
            values = raw.tags.get("comment")
            if values:
                return str(values[0])
    except Exception:
        pass
    return ""


def _has_artwork(raw, ext):
    try:
        if ext == "mp3":
            return bool(raw.tags.getall("APIC"))
        if ext in M4A:
            return bool(raw.tags.get("covr"))
        if ext == "flac":
            return bool(raw.pictures)
        return bool(raw.tags.get("metadata_block_picture"))
    except Exception:
        return False


def _read_key(raw, ext):
    """Musical key: TKEY on mp3, a freeform atom on m4a, vorbis elsewhere."""
    try:
        if ext == "mp3":
            frame = raw.tags.get("TKEY")
            if frame and frame.text:
                return str(frame.text[0])
        elif ext in M4A:
            values = raw.tags.get(M4A_KEY)
            if values:
                return values[0].decode("utf-8", "replace")
        else:
            values = raw.tags.get("initialkey")
            if values:
                return str(values[0])
    except Exception:
        pass
    return ""


def _read_remixer(raw, ext):
    try:
        if ext == "mp3":
            frame = raw.tags.get("TPE4")
            if frame and frame.text:
                return str(frame.text[0])
        elif ext in M4A:
            values = raw.tags.get(M4A_REMIXER)
            if values:
                return values[0].decode("utf-8", "replace")
        else:
            values = raw.tags.get("remixer")
            if values:
                return str(values[0])
    except Exception:
        pass
    return ""


def _read_rating(raw, ext):
    try:
        if ext == "mp3":
            frames = raw.tags.getall("POPM")
            if frames:
                return _stars(frames[0].rating)
        elif ext in M4A:
            values = raw.tags.get(M4A_RATING)
            if values:
                return _stars(int(values[0].decode("utf-8", "replace")))
        else:
            values = raw.tags.get("rating")
            if values:
                return _stars(int(str(values[0])))
    except Exception:
        pass
    return 0


def tags_read(path):
    from mutagen import File

    out = {}
    easy = File(path, easy=True)
    if easy is not None and easy.tags:
        for key in EASY_KEYS:
            values = easy.tags.get(key)
            if values:
                out[key] = str(values[0])
    raw = File(path)
    if raw is not None and getattr(raw, "tags", None) is not None:
        comment = _read_comment(raw, _ext(path))
        if comment:
            out["comment"] = comment
        key = _read_key(raw, _ext(path))
        if key:
            out["initialkey"] = key
        remixer = _read_remixer(raw, _ext(path))
        if remixer:
            out["remixer"] = remixer
        rating = _read_rating(raw, _ext(path))
        if rating:
            out["rating"] = str(rating)
        out["_artwork"] = "true" if _has_artwork(raw, _ext(path)) else "false"
    return out


def tags_readmany(paths_json):
    out = {}
    for path in json.loads(paths_json):
        try:
            out[path] = tags_read(path)
        except Exception:
            out[path] = {}
    print(json.dumps(out))


def tags_artwork(path, out_path):
    from mutagen import File

    raw = File(path)
    ext = _ext(path)
    data = None
    try:
        if ext == "mp3":
            frames = raw.tags.getall("APIC")
            if frames:
                data = bytes(frames[0].data)
        elif ext in M4A:
            covers = raw.tags.get("covr")
            if covers:
                data = bytes(covers[0])
        elif ext == "flac":
            if raw.pictures:
                data = bytes(raw.pictures[0].data)
        else:
            import base64

            values = raw.tags.get("metadata_block_picture")
            if values:
                from mutagen.flac import Picture

                data = bytes(Picture(base64.b64decode(values[0])).data)
    except Exception:
        pass
    if data:
        with open(out_path, "wb") as handle:
            handle.write(data)


def tags_write(path, payload):
    data = json.loads(payload)
    ext = _ext(path)

    # comment and artwork first on the raw tag object — they are format
    # specific — then reopen for the easy text keys so nothing is clobbered
    from mutagen import File

    raw = File(path)
    if raw is None:
        sys.exit(1)
    changed = False

    if "comment" in data:
        comment = data["comment"]
        if ext == "mp3":
            from mutagen.id3 import COMM

            if raw.tags is None:
                raw.add_tags()
            raw.tags.delall("COMM")
            if comment:
                raw.tags.add(COMM(lang="eng", desc="", text=[comment]))
            changed = True
        elif ext in M4A:
            if comment:
                raw.tags["\xa9cmt"] = [comment]
            else:
                raw.tags.pop("\xa9cmt", None)
            changed = True
        elif raw.tags is not None:
            if comment:
                raw.tags["comment"] = [comment]
            elif "comment" in raw.tags:
                del raw.tags["comment"]
            changed = True

    if "initialkey" in data:
        key = data["initialkey"]
        if ext == "mp3":
            from mutagen.id3 import TKEY

            if raw.tags is None:
                raw.add_tags()
            raw.tags.delall("TKEY")
            if key:
                raw.tags.add(TKEY(encoding=3, text=[key]))
            changed = True
        elif ext in M4A:
            from mutagen.mp4 import MP4FreeForm

            if key:
                raw.tags[M4A_KEY] = [MP4FreeForm(key.encode("utf-8"))]
            else:
                raw.tags.pop(M4A_KEY, None)
            changed = True
        elif raw.tags is not None:
            if key:
                raw.tags["initialkey"] = [key]
            elif "initialkey" in raw.tags:
                del raw.tags["initialkey"]
            changed = True

    if "remixer" in data:
        remixer = data["remixer"]
        if ext == "mp3":
            from mutagen.id3 import TPE4

            if raw.tags is None:
                raw.add_tags()
            raw.tags.delall("TPE4")
            if remixer:
                raw.tags.add(TPE4(encoding=3, text=[remixer]))
            changed = True
        elif ext in M4A:
            from mutagen.mp4 import MP4FreeForm

            if remixer:
                raw.tags[M4A_REMIXER] = [MP4FreeForm(remixer.encode("utf-8"))]
            else:
                raw.tags.pop(M4A_REMIXER, None)
            changed = True
        elif raw.tags is not None:
            if remixer:
                raw.tags["remixer"] = [remixer]
            elif "remixer" in raw.tags:
                del raw.tags["remixer"]
            changed = True

    if "rating" in data:
        stars = int(data["rating"]) if str(data["rating"]).isdigit() else 0
        if ext == "mp3":
            from mutagen.id3 import POPM

            if raw.tags is None:
                raw.add_tags()
            raw.tags.delall("POPM")
            if stars:
                # WMP breakpoints on the 0-255 scale
                raw.tags.add(POPM(
                    email="musiclab",
                    rating=[0, 1, 64, 128, 196, 255][stars],
                ))
            changed = True
        elif ext in M4A:
            from mutagen.mp4 import MP4FreeForm

            if stars:
                raw.tags[M4A_RATING] = [MP4FreeForm(str(stars * 20).encode("utf-8"))]
            else:
                raw.tags.pop(M4A_RATING, None)
            changed = True
        elif raw.tags is not None:
            if stars:
                raw.tags["rating"] = [str(stars * 20)]
            elif "rating" in raw.tags:
                del raw.tags["rating"]
            changed = True

    artwork = data.get("_artwork")
    if artwork:
        with open(artwork, "rb") as handle:
            art = handle.read()
        if ext == "mp3":
            from mutagen.id3 import APIC

            if raw.tags is None:
                raw.add_tags()
            raw.tags.delall("APIC")
            raw.tags.add(APIC(mime="image/jpeg", type=3, desc="", data=art))
            changed = True
        elif ext in M4A:
            from mutagen.mp4 import MP4Cover

            fmt = MP4Cover.FORMAT_PNG if art[:8] == b"\x89PNG\r\n\x1a\n" else MP4Cover.FORMAT_JPEG
            raw.tags["covr"] = [MP4Cover(art, imageformat=fmt)]
            changed = True
        elif ext == "flac":
            from mutagen.flac import Picture

            picture = Picture()
            picture.data = art
            picture.type = 3
            picture.mime = "image/png" if art[:8] == b"\x89PNG\r\n\x1a\n" else "image/jpeg"
            raw.clear_pictures()
            raw.add_picture(picture)
            changed = True

    if changed:
        raw.save()

    easy = File(path, easy=True)
    if easy is None:
        sys.exit(1)
    if easy.tags is None:
        easy.add_tags()
    for key in EASY_KEYS:
        if key not in data:
            continue
        value = data[key]
        try:
            if value:
                easy[key] = [value]
            elif key in easy:
                del easy[key]
        except Exception:
            pass
    easy.save()


def tags_main(argv):
    if argv[0] == "read":
        print(json.dumps(tags_read(argv[1])))
    elif argv[0] == "readmany":
        tags_readmany(argv[1])
    elif argv[0] == "artwork":
        tags_artwork(argv[1], argv[2])
    elif argv[0] == "write":
        tags_write(argv[1], argv[2])
    else:
        sys.exit(2)


def _beats_madmom(path, min_bpm, max_bpm):
    """RNN onset activations decoded by a dynamic Bayesian network: the
    tracker follows tempo changes beat by beat instead of fitting one period."""
    from madmom.features.beats import DBNBeatTrackingProcessor, RNNBeatProcessor

    activations = RNNBeatProcessor()(path)
    tracker = DBNBeatTrackingProcessor(
        fps=100, min_bpm=min_bpm, max_bpm=max_bpm, transition_lambda=60
    )
    return [float(t) for t in tracker(activations)]


def _beats_librosa(path, min_bpm, max_bpm):
    import librosa
    import numpy as np

    y, sr = librosa.load(path, sr=22050, mono=True)
    onset = librosa.onset.onset_strength(y=y, sr=sr)
    tempo, frames = librosa.beat.beat_track(
        onset_envelope=onset, sr=sr, trim=False, units="frames"
    )
    times = librosa.frames_to_time(frames, sr=sr)
    return [float(t) for t in np.asarray(times)]


def beats_main(argv):
    path = argv[0]
    min_bpm = float(argv[1]) if len(argv) > 1 else 60.0
    max_bpm = float(argv[2]) if len(argv) > 2 else 200.0
    errors = []
    for engine, fn in (("madmom", _beats_madmom), ("librosa", _beats_librosa)):
        try:
            beats = fn(path, min_bpm, max_bpm)
        except Exception as error:  # missing package, decode failure
            errors.append(f"{engine}: {error}")
            continue
        if len(beats) >= 4:
            print(json.dumps({"engine": engine, "beats": beats}))
            return
        errors.append(f"{engine}: too few beats")
    print(json.dumps({"error": "; ".join(errors)}))
    sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "tags":
        tags_main(sys.argv[2:])
    elif len(sys.argv) > 1 and sys.argv[1] == "beats":
        beats_main(sys.argv[2:])
    else:
        from demucs.separate import main

        main()
