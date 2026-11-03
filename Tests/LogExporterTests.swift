import Foundation
import Darwin

@main
struct LogExporterTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("log-export-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }
        func unzip(_ archive: URL, _ arguments: [String]) throws -> String {
            let result = try LogExporter.runCommand("/usr/bin/unzip", arguments + [archive.path], nil, 5)
            check(result.status == 0, "unzip succeeded")
            return result.stdout
        }
        func members(_ archive: URL) throws -> Set<String> {
            Set(try unzip(archive, ["-Z1"]).split(separator: "\n").map(String.init))
        }
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        let date = ISO8601DateFormatter().date(from: "2026-11-03T10:40:00Z")!
        let app = LogExporter.AppInfo(url: URL(fileURLWithPath: "/Applications/Toss.app"), version: "1.2.3", build: "45")
        var commands = [(String, [String], TimeInterval)]()
        var systemLogsFail = false
        var zipFails = false
        let exporter = LogExporter(run: { executable, arguments, directory, timeout in
            commands.append((executable, arguments, timeout))
            switch executable {
            case "/usr/bin/sw_vers":
                return .init(status: 0, stdout: "ProductName: macOS\nProductVersion: 26.0\nBuildVersion: test", stderr: "")
            case "/usr/bin/codesign":
                return .init(status: 0, stdout: "", stderr: "Executable=/Users/private/Toss.app\nCDHash=0123456789abcdef\n")
            case "/usr/sbin/sysctl": return .init(status: 0, stdout: "MacTest1,1\n", stderr: "")
            case "/usr/bin/log":
                if systemLogsFail { throw LogExporter.ExportError.commandTimedOut }
                return .init(status: 0, stdout: "Toss: /Users/log-user/Library/example\n", stderr: "")
            case "/usr/bin/zip":
                if zipFails { return .init(status: 1, stdout: "", stderr: "synthetic zip failure") }
                return try LogExporter.runCommand(executable, arguments, directory, timeout)
            default: fatalError("unexpected command")
            }
        })

        for (input, expected) in [
            ("/Users/alice/Documents/x /Users/bob/Library/y", "~/Documents/x ~/Library/y"),
            ("home=/Users/alice", "home=~"),
            ("\"/Users/测试用户/桌面\"", "\"~/桌面\""),
            ("\"/Users/Alex Smith/Desktop/a\"", "\"~/Desktop/a\""),
            ("\"/Users/Alex Smith\"", "\"~\""),
            ("file:///Users/alice/a", "file://~/a"),
            (#"{"path":"\/Users\/alice\/Library\/a"}"#, #"{"path":"~\/Library\/a"}"#),
            (#"{"path":"/Users/\u6d4b\u8bd5/Library/a"}"#, #"{"path":"~/Library/a"}"#),
            (#"{"path":"\u002fUsers\u002falice\u002fLibrary"}"#, #"{"path":"~\u002fLibrary"}"#),
            ("/Library/Logs/unaffected", "/Library/Logs/unaffected")
        ] {
            check(LogExporter.redact(input) == expected, "redaction: \(input)")
        }
        check(LogExporter.filename(at: date, timeZone: zone) == "Toss 日志 2026-11-03 18.40.zip", "local filename")
        check(LogExporter.filename(at: date, timeZone: zone, sequence: 2) == "Toss 日志 2026-11-03 18.40 (2).zip", "numbered filename")
        check(LogExporter.filename(at: date, timeZone: TimeZone(secondsFromGMT: 0)!) == "Toss 日志 2026-11-03 10.40.zip", "explicit timezone")

        let support = try directory("support")
        let desktop = try directory("desktop")
        for name in LogExporter.allowedFiles { try write("/Users/alice/Library/\(name)\n", to: support.appendingPathComponent(name)) }
        let deviceState = support.appendingPathComponent("DeviceState")
        try fm.createDirectory(at: deviceState, withIntermediateDirectories: false)
        for name in ["secret.plist", "secret.pem", "secret.key", "pair record", "pair-record.json", "extra.log"] {
            try write("SYNTHETIC-SECRET", to: support.appendingPathComponent(name))
            try write("SYNTHETIC-SECRET", to: deviceState.appendingPathComponent(name))
        }
        let archive = try exporter.export(support: support, destination: desktop, app: app, at: date, timeZone: zone)
        check(try members(archive) == Set(LogExporter.allowedFiles + ["info.txt", "system.log"]), "exact zip whitelist")
        let allText = try unzip(archive, ["-p"])
        check(!allText.contains("SYNTHETIC-SECRET") && !allText.contains("/Users/"), "no keys or home paths")
        for value in ["macOS", "26.0", "Toss version: 1.2.3", "Toss build: 45", "CDHash: 0123456789abcdef", "MacTest1,1", "2026-11-03T18:40:00+08:00", "~/Library/"] {
            check(allText.contains(value), "metadata / sanitized logs: \(value)")
        }
        check((try fm.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private archive")
        let logCommand = commands.first { $0.0 == "/usr/bin/log" }!
        check(Array(logCommand.1.prefix(6)) == ["show", "--last", "2h", "--style", "compact", "--predicate"], "two-hour compact system logs")
        check(logCommand.2 == 30, "system-log deadline is 30 seconds")
        let predicate = logCommand.1.last!
        check(predicate.contains("Toss") && predicate.contains("io.github.ashzene.toss"), "Toss process and subsystem")
        check(predicate.contains("/Applications/Toss.app/Contents/") && !predicate.contains("python3"), "only Toss runtime, not all Python")
        check(commands.contains { $0.0 == "/usr/bin/codesign" && $0.1.last == app.url.path }, "CDHash from this app")
        check(commands.filter { $0.0 == "/usr/bin/zip" }.allSatisfy { !$0.1.contains("-r") }, "zip never recurses")

        let original = try Data(contentsOf: archive)
        let second = try exporter.export(support: support, destination: desktop, app: app, at: date, timeZone: zone)
        check(second.lastPathComponent == "Toss 日志 2026-11-03 18.40 (1).zip", "collision increments")
        check(try Data(contentsOf: archive) == original, "collision preserves existing archive")
        try fm.createDirectory(at: desktop.appendingPathComponent(LogExporter.filename(at: date, timeZone: zone, sequence: 2)), withIntermediateDirectories: false)
        let third = try exporter.export(support: support, destination: desktop, app: app, at: date, timeZone: zone)
        check(third.lastPathComponent.hasSuffix(" (3).zip"), "directory collision also increments")

        systemLogsFail = true
        let emptyDesktop = try directory("empty-desktop")
        let missing = try exporter.export(support: root.appendingPathComponent("missing"), destination: emptyDesktop, app: app, at: date)
        check(try members(missing) == ["info.txt"], "missing support and system log timeout still produce zip")
        let partial = try directory("partial")
        try write("only one log", to: partial.appendingPathComponent("permission-checks.log"))
        let partialZip = try exporter.export(support: partial, destination: emptyDesktop, app: app, at: date)
        check(try members(partialZip) == ["info.txt", "permission-checks.log"], "individual missing files skipped")

        let unsafe = try directory("unsafe")
        try fm.createSymbolicLink(at: unsafe.appendingPathComponent("last-run.json"), withDestinationURL: deviceState.appendingPathComponent("secret.key"))
        try fm.linkItem(at: deviceState.appendingPathComponent("secret.pem"), to: unsafe.appendingPathComponent("capture-history.jsonl"))
        try fm.createDirectory(at: unsafe.appendingPathComponent("link-timeline.jsonl"), withIntermediateDirectories: false)
        try write("SYNTHETIC-SECRET", to: unsafe.appendingPathComponent("link-timeline.jsonl/secret.key"))
        check(mkfifo(unsafe.appendingPathComponent("link-timeline-usb.jsonl").path, 0o600) == 0, "synthetic pipe created")
        try Data([0xff, 0x00, 0xfe]).write(to: unsafe.appendingPathComponent("permission-checks.log"))
        let unsafeZip = try exporter.export(support: unsafe, destination: emptyDesktop, app: app, at: date)
        check(try members(unsafeZip) == ["info.txt"], "symlinks, hardlinks, directories, pipes and binary files excluded")
        let alias = root.appendingPathComponent("support-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: support)
        let aliasZip = try exporter.export(support: alias, destination: emptyDesktop, app: app, at: date)
        check(try members(aliasZip) == ["info.txt"], "support-directory symlink not followed")

        let failureDesktop = try directory("failure-desktop")
        zipFails = true
        do {
            _ = try exporter.export(support: partial, destination: failureDesktop, app: app)
            check(false, "zip error must fail")
        } catch LogExporter.ExportError.archiveFailed { check(true, "zip error surfaced") }
        check(try fm.contentsOfDirectory(atPath: failureDesktop.path).isEmpty, "zip failure leaves no archive")
        zipFails = false
        do {
            _ = try exporter.export(support: partial, destination: root.appendingPathComponent("absent-desktop"), app: app)
            check(false, "invalid desktop must fail")
        } catch { check(true, "desktop write failure surfaced") }
        check(try fm.contentsOfDirectory(atPath: emptyDesktop.path).allSatisfy { !$0.hasPrefix(".Toss-logs-") }, "no pending files after successful publication")

        // Real subprocess deadline: no system logs, device, UI or application access.
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try LogExporter.runCommand("/bin/sleep", ["10"], nil, 0.1)
            check(false, "command must time out")
        } catch LogExporter.ExportError.commandTimedOut { check(true, "timed-out subprocess killed") }
        check(ProcessInfo.processInfo.systemUptime - started < 2, "timeout returns promptly")
        let large = try LogExporter.runCommand("/usr/bin/awk", ["BEGIN { for (i=0;i<20000;i++) print \"synthetic-output\" }"], nil, 5)
        check(large.status == 0 && large.stdout.utf8.count > 200_000, "large output does not block on pipe capacity")
        // Exports go to Toss's own subfolder; earlier exports there are never collected, and only the
        // newest five of our own zips are kept.
        let nestedSupport = try directory("nested-support")
        try write("{}", to: nestedSupport.appendingPathComponent("last-run.json"))
        let exportsFolder = nestedSupport.appendingPathComponent(LogExporter.exportsFolderName)
        try fm.createDirectory(at: exportsFolder, withIntermediateDirectories: false)
        try write("OLD-EXPORT", to: exportsFolder.appendingPathComponent("Toss 日志 2026-01-01 00.00.zip"))
        let nested = try exporter.export(support: nestedSupport, destination: exportsFolder, app: app, at: date, timeZone: zone)
        check(nested.deletingLastPathComponent().standardizedFileURL == exportsFolder.standardizedFileURL, "export lands in the exports subfolder")
        let nestedMembers = try members(nested)
        check(nestedMembers.contains("last-run.json") && !nestedMembers.contains { $0.hasSuffix(".zip") || $0.contains("/") }, "earlier exports are not collected")
        let pruneFolder = try directory("prune")
        for day in 1...7 {
            let url = pruneFolder.appendingPathComponent("Toss 日志 2026-11-0\(day) 10.00.zip")
            try write("zip \(day)", to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(day * 1000))], ofItemAtPath: url.path)
        }
        try write("keep me", to: pruneFolder.appendingPathComponent("notes.zip"))
        try write("keep me", to: pruneFolder.appendingPathComponent("Toss 日志 readme.txt"))
        LogExporter.prune(pruneFolder)
        let left = try fm.contentsOfDirectory(atPath: pruneFolder.path).sorted()
        check(left.filter { $0.hasSuffix(".zip") && $0.hasPrefix("Toss 日志 ") }.count == 5, "five newest exports kept")
        check(!left.contains("Toss 日志 2026-11-01 10.00.zip") && !left.contains("Toss 日志 2026-11-02 10.00.zip"), "oldest exports removed")
        check(left.contains("notes.zip") && left.contains("Toss 日志 readme.txt"), "only our own export zips are pruned")
        print("Log export: \(count) assertions passed (synthetic logs and real zip/unzip only).")
    }
}
