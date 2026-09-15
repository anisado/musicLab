import Foundation

/// Runs Demucs as a subprocess and reports progress per track. One job at a
/// time: separation saturates the machine.
@MainActor
final class Separator: ObservableObject {
    @Published var jobs: [String: StemState] = [:]
    @Published private(set) var helper: [String]?

    /// Process command line that runs `demucs`, best first:
    /// the bundled PyInstaller helper when shipped, then an installed or
    /// development venv, then a plain demucs on the usual paths.
    private func resolveHelper() -> [String]? {
        let env = ProcessInfo.processInfo.environment
        if let bundled = Bundle.main.url(forResource: "stems-tool", withExtension: nil) {
            return [bundled.path]
        }
        if let override = env["MUSICLAB_DEMUCS"], !override.isEmpty {
            return override.split(separator: " ").map(String.init)
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let candidates = [
            support.appendingPathComponent("MusicLab/venv/bin/demucs"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("helper/venv/bin/demucs"),
            URL(fileURLWithPath: "/opt/homebrew/bin/demucs"),
            URL(fileURLWithPath: "/usr/local/bin/demucs")
        ]
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return [url.path]
        }
        return nil
    }

    var available: Bool { helper != nil }

    init() {
        helper = resolveHelper()
    }

    /// Serialises jobs like the semaphore in the web service did.
    private actor Gate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func waitTurn() async {
            if !busy {
                busy = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty { busy = false }
            else { waiters.removeFirst().resume() }
        }
    }

    private let gate = Gate()

    /// env defaults tuned for Apple Silicon; override via the process environment
    private func arguments(source: URL, output: URL) -> [String] {
        let env = ProcessInfo.processInfo.environment
        var args = [
            "-n", env["DEMUCS_MODEL"] ?? AppPrefs.demucsModel,
            "-d", env["DEMUCS_DEVICE"] ?? "mps",
            "--mp3", "--mp3-bitrate", "192",
            "-o", output.path,
            "--filename", "{stem}.{ext}"
        ]
        if let jobs = env["DEMUCS_JOBS"], !jobs.isEmpty { args += ["--jobs", jobs] }
        if let overlap = env["DEMUCS_OVERLAP"], !overlap.isEmpty { args += ["--overlap", overlap] }
        args.append(source.path)
        return args
    }

    /// Separate `track` into `stemsDir/<id>/` and return the produced stem names.
    func separate(track: Track, source: URL, stemsDir: URL) async -> [String] {
        guard let helper else {
            jobs[track.id] = .failed("no demucs helper — run scripts/setup-venv.sh")
            return []
        }
        await gate.waitTurn()
        defer { Task { await gate.release() } }

        jobs[track.id] = .running(progress: 0)
        let scratch = stemsDir.appendingPathComponent("\(track.id).tmp")
        let target = stemsDir.appendingPathComponent(track.id)
        let fm = FileManager.default
        try? fm.removeItem(at: scratch)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        let status = await run(helper + arguments(source: source, output: scratch)) { [weak self] progress in
            Task { @MainActor in self?.jobs[track.id] = .running(progress: progress) }
        }

        // demucs nests output under <scratch>/<model>/ — lift the stems up
        let model = ProcessInfo.processInfo.environment["DEMUCS_MODEL"] ?? AppPrefs.demucsModel
        var produced: [String] = []
        for stem in ["vocals", "drums", "bass", "other"] {
            let file = scratch.appendingPathComponent("\(model)/\(stem).mp3")
            if fm.fileExists(atPath: file.path) {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                try? fm.removeItem(at: target.appendingPathComponent("\(stem).mp3"))
                try? fm.moveItem(at: file, to: target.appendingPathComponent("\(stem).mp3"))
                produced.append(stem)
            }
        }
        try? fm.removeItem(at: scratch)

        if status == 0, !produced.isEmpty {
            jobs[track.id] = .done(stems: produced)
        } else {
            jobs[track.id] = .failed("demucs exited with \(status)")
        }
        return produced
    }

    /// Run the helper, parsing demucs' `NN%|…` progress bars off its output.
    private func run(_ argv: [String], onProgress: @escaping (Double) -> Void) async -> Int32 {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())

            let env = ProcessInfo.processInfo.environment
            var environment = env
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            environment["TORCH_HOME"] = support.appendingPathComponent("MusicLab/models").path
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let percent = try! NSRegularExpression(pattern: #"(\d+)%\|"#)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard let text = String(data: data, encoding: .utf8) else { return }
                for part in text.split(whereSeparator: { $0.isNewline || $0 == "\r" }) {
                    let line = String(part)
                    if let match = percent.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                       let range = Range(match.range(at: 1), in: line),
                       let value = Double(line[range]) {
                        onProgress(min(value / 100, 1))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                return Int32(-1)
            }
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            return process.terminationStatus
        }.value
    }
}
