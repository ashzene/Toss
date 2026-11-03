import Foundation
import Darwin

// This service has no capture, pairing, or UI dependencies. Call it off the main thread.
struct LogExporter {
    static let allowedFiles = [
        "last-run.json", "capture-history.jsonl", "link-timeline.jsonl",
        "link-timeline-usb.jsonl", "permission-checks.log", "screenshot-success-times.json"
    ]

    struct AppInfo {
        let url: URL
        let version: String
        let build: String

        static var current: Self {
            Self(url: Bundle.main.bundleURL,
                 version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unavailable",
                 build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unavailable")
        }
    }

    struct CommandOutput {
        let status: Int32
        let stdout: String
        let stderr: String
    }
    enum ExportError: Error { case commandTimedOut, archiveFailed, publicationFailed(Int32) }
    typealias CommandRunner = (String, [String], URL?, TimeInterval) throws -> CommandOutput
    var run: CommandRunner = runCommand

    static func redact(_ text: String) -> String {
        // Include JSON's escaped slashes and Unicode-escaped home-directory names.
        let slash = #"(?:/|\\/|\\u002[fF])"#
        let prefix = slash + "Users" + slash
        let escapedCharacter = #"(?!\\u002[fF])\\u[0-9a-fA-F]{4}"#
        let withSpaces = "(?:" + escapedCharacter + #"|[^/\r\n\"'<>\\,;:)\]}])+"#
        let withoutSpaces = "(?:" + escapedCharacter + #"|[^/\s\"'<>\\,;:)\]}])+"#
        var result = text
        for pattern in [prefix + withSpaces + "(?=" + slash + #"|[\"'\r\n]|$)"#, prefix + withoutSpaces] {
            let expression = try! NSRegularExpression(pattern: pattern)
            result = expression.stringByReplacingMatches(in: result,
                range: NSRange(result.startIndex..., in: result), withTemplate: "~")
        }
        return result
    }

    // Exports live inside Toss's own support folder, not the Desktop: writing to ~/Desktop makes macOS
    // ask for Desktop access, which confuses testers (2026-11-03). Only the top-level allowedFiles are
    // collected, so earlier exports in this subfolder never end up inside a new one.
    static let exportsFolderName = "导出日志"
    static let keptExports = 5

    // Keeps the newest `keep` exports. Only regular files named like our own exports are removed.
    static func prune(_ folder: URL, keep: Int = keptExports) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        var exports: [(url: URL, modified: Date)] = []
        for name in names where name.hasPrefix("Toss 日志 ") && name.hasSuffix(".zip") {
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            exports.append((url, values.contentModificationDate ?? .distantPast))
        }
        for old in exports.sorted(by: { $0.modified > $1.modified }).dropFirst(keep) { try? fm.removeItem(at: old.url) }
    }

    static func filename(at date: Date, timeZone: TimeZone = .current, sequence: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let suffix = sequence == 0 ? "" : " (\(sequence))"
        return "Toss 日志 \(formatter.string(from: date))\(suffix).zip"
    }

    func export(support: URL, destination: URL, app: AppInfo, at date: Date = Date(),
                timeZone: TimeZone = .current) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Toss-log-export-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        var entries = [String]()
        func stage(_ text: String, as name: String) throws {
            let url = staging.appendingPathComponent(name)
            try Data(Self.redact(text).utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            entries.append(name)
        }

        // No directory enumeration or recursive copy, even when files are missing.
        let directory = open(support.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if directory >= 0 {
            defer { close(directory) }
            for name in Self.allowedFiles {
                if let text = try Self.readLog(name, directory: directory) { try stage(text, as: name) }
            }
        } else if errno != ENOENT && errno != ELOOP && errno != ENOTDIR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        func output(_ executable: String, _ arguments: [String]) -> String {
            guard let result = try? run(executable, arguments, nil, 5), result.status == 0 else { return "unavailable" }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let signature = try? run("/usr/bin/codesign", ["-d", "--verbose=4", app.url.path], nil, 5)
        let cdhash = signature.flatMap { result -> String? in
            guard result.status == 0 else { return nil }
            return (result.stdout + "\n" + result.stderr).components(separatedBy: .newlines)
                .first(where: { $0.hasPrefix("CDHash=") }).map { String($0.dropFirst(7)) }
        } ?? "unavailable"
        let timestamp = ISO8601DateFormatter()
        timestamp.timeZone = timeZone
        try stage("""
        macOS (sw_vers):
        \(output("/usr/bin/sw_vers", []))
        Toss version: \(app.version)
        Toss build: \(app.build)
        CDHash: \(cdhash)
        Mac model: \(output("/usr/sbin/sysctl", ["-n", "hw.model"]))
        Exported at: \(timestamp.string(from: date))

        """, as: "info.txt")

        // Never match every Python process: only Toss's executable/subsystem and its bundled runtime.
        var predicate = #"process == "Toss" OR subsystem == "io.github.ashzene.toss" OR subsystem BEGINSWITH "io.github.ashzene.toss.""#
        if app.url.pathExtension == "app" {
            let path = app.url.appendingPathComponent("Contents").path + "/"
            let quoted = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            predicate += " OR processImagePath BEGINSWITH \"\(quoted)\""
        }
        if let logs = try? run("/usr/bin/log", ["show", "--last", "2h", "--style", "compact", "--predicate", predicate], nil, 30),
           logs.status == 0 {
            try stage(logs.stdout, as: "system.log")
        }

        let archive = staging.appendingPathComponent("export.zip")
        let zipped = try run("/usr/bin/zip", ["-q", "-X", archive.path] + entries, staging, 30)
        guard zipped.status == 0 else { throw ExportError.archiveFailed }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)

        // Copy across volumes first, then publish atomically without replacing an existing file.
        let pending = destination.appendingPathComponent(".Toss-logs-" + UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: pending) }
        try fm.copyItem(at: archive, to: pending)
        var sequence = 0
        while true {
            let archive = destination.appendingPathComponent(Self.filename(at: date, timeZone: timeZone, sequence: sequence))
            if renamex_np(pending.path, archive.path, UInt32(RENAME_EXCL)) == 0 { return archive }
            let code = errno
            guard code == EEXIST else { throw ExportError.publicationFailed(code) }
            sequence += 1
        }
    }

    private static func readLog(_ name: String, directory: Int32) throws -> String? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT || errno == ELOOP { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw POSIXError(.EIO) }
        // Reject directories, pipes, symlinks and hard links, including links to DeviceState.
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else { return nil }
        let data = try handle.read(upToCount: Int(metadata.st_size)) ?? Data()
        // Do not package unknown binary content under a whitelisted text filename.
        return String(data: data, encoding: .utf8)
    }

    static func runCommand(_ executable: String, _ arguments: [String], _ directory: URL?,
                           _ timeout: TimeInterval) throws -> CommandOutput {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("Toss-log-command-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let stdout = scratch.appendingPathComponent("stdout")
        let stderr = scratch.appendingPathComponent("stderr")
        fm.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: stderr.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        // File-backed output cannot deadlock on a full pipe during a large log export.
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ExportError.commandTimedOut
        }
        return CommandOutput(status: process.terminationStatus,
                             stdout: String(decoding: try Data(contentsOf: stdout), as: UTF8.self),
                             stderr: String(decoding: try Data(contentsOf: stderr), as: UTF8.self))
    }
}
