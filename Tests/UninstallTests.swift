import Foundation
import Darwin

@main
@MainActor
struct UninstallTests {
    enum Failure: Error { case injected }
    static var assertions = 0
    static let fm = FileManager.default
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    static func main() async throws {
        precondition(CommandLine.arguments.count == 3, "Pass source directory and existing Python")
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("toss-uninstall-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        try compareScripts(source)
        try testRemoval(root)
        try testDefaults()
        await testSequence()
        try await testProcessShutdown(root, python: CommandLine.arguments[2])
        print("Uninstall: \(assertions) assertions passed; fake homes, synthetic children and injected system actions only.")
    }

    static func captures(_ pattern: String, in text: String) throws -> [[String]] {
        let expression = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    static func compareScripts(_ source: URL) throws {
        for name in ["Uninstall.command"] {
            let script = try String(contentsOf: source.appendingPathComponent(name), encoding: .utf8)
            let assignments = try captures(#"^(TASK_[A-Z_]+)="\$HOME/([^"]+)"$"#, in: script)
            let removalLines = script.components(separatedBy: .newlines).filter { $0.hasPrefix("/bin/rm ") }
            check(removalLines.count == 1, "One explicit legacy removal command")
            let command = removalLines[0]
            let operands = try captures(#""\$(TASK_[A-Z_]+)""#, in: command).map { $0[0] }
            check(command == "/bin/rm -rf -- " + operands.map { "\"$\($0)\"" }.joined(separator: " "),
                  "No unparsed/literal extra removal operand")
            check(operands.filter { $0 == "TASK_APP" }.count == 1, "App is exactly one separately recycled operand")
            let dataOperands = operands.filter { $0 != "TASK_APP" }
            let paths = try dataOperands.map { variable -> String in
                let values = assignments.filter { $0[0] == variable }
                guard values.count == 1 else { throw Failure.injected }
                return values[0][1]
            }
            check(paths.sorted() == UninstallPolicy.relativePaths.sorted(), "Exact path equality with \(name)")
            check(script.contains("Accessibility stays granted"), "Command scripts preserve Accessibility permission")
        }
        let build = try String(contentsOf: source.appendingPathComponent("scripts/build-release.py"), encoding: .utf8)
        check(!build.contains("Uninstall.command"), "DMG build no longer stages a command uninstaller")
    }

    static func write(_ url: URL, _ text: String = "keep") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func testRemoval(_ root: URL) throws {
        let home = root.appendingPathComponent("home")
        let outside = root.appendingPathComponent("outside/important.txt")
        try write(outside)
        let decoys = ["Library/Application Support/AnotherApp/data", "Library/Caches/AnotherApp/cache",
                      "Library/Preferences/another.app.plist", "Library/Preferences/io.github.ashzene.toss.plist",
                      "Library/Application Support/Toss-neighbor", "Documents/do-not-delete.txt"]
        for path in decoys { try write(home.appendingPathComponent(path)) }
        for path in UninstallPolicy.relativePaths {
            let folder = home.appendingPathComponent(path)
            try write(folder.appendingPathComponent("nested/deep/private.txt"), "remove")
            try fm.createSymbolicLink(at: folder.appendingPathComponent("outside-directory"),
                                      withDestinationURL: outside.deletingLastPathComponent())
            try fm.createSymbolicLink(at: folder.appendingPathComponent("nested/outside-file"), withDestinationURL: outside)
            try fm.createSymbolicLink(at: folder.appendingPathComponent("loop"), withDestinationURL: folder)
        }
        let remover = UninstallDataRemover(home: home)
        for path in UninstallPolicy.relativePaths {
            try remover.remove(path)
            check(!exists(home.appendingPathComponent(path)), "Allowlisted tree removed, including link entries")
            try remover.remove(path) // Missing paths are already clean.
        }
        for path in decoys { check(exists(home.appendingPathComponent(path)), "Decoy survives: \(path)") }
        let remaining = try String(contentsOf: outside, encoding: .utf8)
        check(remaining == "keep", "External link target survives")
        for forbidden in ["Library", "Library/Preferences/io.github.ashzene.toss.plist", "../outside",
                          "/Library/Caches/Toss", UninstallPolicy.relativePaths[0] + "/../AnotherApp"] {
            do { try remover.remove(forbidden); preconditionFailure("Non-allowlisted path accepted") }
            catch UninstallDataRemover.RemovalError.pathNotAllowed { assertions += 1 }
        }
        // A root itself may be a link: delete only that link, never its target.
        for path in UninstallPolicy.relativePaths {
            let link = home.appendingPathComponent(path)
            try fm.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
            try remover.remove(path)
            check(!exists(link) && exists(outside), "Top-level symlink unlinked without following")
        }
        // Reject redirecting ancestors at every depth, including the supplied home.
        for ancestor in ["", "Library", "Library/Application Support", "Library/Caches"] {
            let synthetic = root.appendingPathComponent("ancestor-" + UUID().uuidString)
            let target = root.appendingPathComponent("target-" + UUID().uuidString)
            let path = ancestor == "Library/Caches" ? UninstallPolicy.relativePaths[1] : UninstallPolicy.relativePaths[0]
            let suffix = ancestor.isEmpty ? path : String(path.dropFirst(ancestor.count + 1))
            let marker = target.appendingPathComponent(suffix).appendingPathComponent("untouched")
            try write(marker)
            let link = ancestor.isEmpty ? synthetic : synthetic.appendingPathComponent(ancestor)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
            do { try UninstallDataRemover(home: synthetic).remove(path); preconditionFailure("Ancestor symlink followed") }
            catch { check(exists(marker) && exists(link), "Ancestor redirect refused: \(ancestor)") }
        }
    }

    static func testSequence() async {
        let app = URL(fileURLWithPath: "/private/tmp/fake-only/Toss.app")
        let ordinary = ["capture", "setup", "login", "owned"] + UninstallPolicy.relativePaths.map { "remove:" + $0 } +
            ["domain"] + UninstallPolicy.permissionServices.map { "reset:" + $0 }
        for failed in [Set<String>()] + ordinary.map({ Set([$0]) }) + [Set(ordinary), Set(["recycle"]), Set(["recycle", "reveal", "notice"])] {
            var calls: [String] = []
            func record(_ step: String) throws {
                calls.append(step)
                if failed.contains(step) { throw Failure.injected }
            }
            // The reset path itself stays tested even though the shipped default keeps permissions.
            let controller = UninstallController(app: app, resetPermissions: true, actions: .init(
                stopCapture: { try record("capture") }, stopSetup: { try record("setup") },
                unregisterLogin: { try record("login") }, clearOwnedPreferences: { try record("owned") },
                removeData: { try record("remove:" + $0) },
                clearDomain: { domain in check(domain == UninstallPolicy.domain, "Only own defaults domain"); try record("domain") },
                resetPermission: { service, domain in
                    check(domain == UninstallPolicy.domain, "TCC resets scoped to own bundle")
                    try record("reset:" + service)
                },
                recycle: { url in check(url == app, "Recycle only the injected current app"); try record("recycle") },
                reveal: { url in check(url == app, "Finder selects that same app"); try record("reveal") },
                showManualRemoval: { text in check(text == "Drag Toss to the Trash", "Manual removal copy"); try record("notice") },
                terminate: { calls.append("exit") }))
            let result = await controller.run()!
            let fallback = failed.contains("recycle") ? ["reveal", "notice"] : []
            check(calls == ordinary + ["recycle"] + fallback + ["exit"], "Every later step runs despite \(failed)")
            check(result.failedSteps.count == failed.count, "Failures recorded without aborting cleanup")
            check(result.recycled == !failed.contains("recycle"), "Accurate recycle outcome")
            let repeated = await controller.run()
            check(repeated == result && calls.filter { $0 == "exit" }.count == 1, "Repeated confirmation is idempotent")
        }
        for chinese in [false, true] {
            AppLanguage.override = chinese
            var resets = 0
            var notice = ""
            let controller = UninstallController(app: app, resetPermissions: false, actions: .init(
                stopCapture: {}, stopSetup: {}, unregisterLogin: {}, clearOwnedPreferences: {}, removeData: { _ in },
                clearDomain: { _ in AppLanguage.override = !chinese },
                resetPermission: { _, _ in resets += 1 }, recycle: { _ in throw Failure.injected },
                reveal: { _ in }, showManualRemoval: { notice = $0 }, terminate: {}))
            _ = await controller.run()
            check(resets == 0, "Policy switch disables all three resets")
            check(notice == (chinese ? "请把 Toss 拖进废纸篓" : "Drag Toss to the Trash"), "Language survives preference clearing")
        }
        AppLanguage.override = nil
        check(!UninstallPolicy.resetPermissions, "Default keeps Accessibility, as Uninstall.command does (Ashley 2026-10-29)")
        check(UninstallPolicy.domain == "io.github.ashzene.toss" &&
              UninstallPolicy.permissionServices == ["Accessibility", "PostEvent", "ListenEvent"],
              "Exact permission services and bundle ID required by the task")
    }

    final class MemoryDefaults: UninstallPreferenceClearing {
        var domains = [UninstallPolicy.domain: ["onboarding": "seen", "language": "zh"], "unrelated.app": ["keep": "yes"]]
        var calls: [String] = []
        var syncOK = true
        func removeObject(forKey key: String) { preconditionFailure("Whole-domain cleanup does not guess keys") }
        func removePersistentDomain(forName domainName: String) {
            calls.append("remove:" + domainName)
            domains.removeValue(forKey: domainName)
        }
        func synchronize() -> Bool { calls.append("sync"); return syncOK }
    }

    static func testDefaults() throws {
        let defaults = MemoryDefaults()
        try UninstallPreferences.clearDomain(UninstallPolicy.domain, in: defaults)
        check(defaults.calls == ["remove:" + UninstallPolicy.domain, "sync"], "Remove persistent domain then synchronize")
        check(defaults.domains[UninstallPolicy.domain] == nil, "Onboarding and all owned defaults removed")
        check(defaults.domains["unrelated.app"] == ["keep": "yes"], "Unrelated preferences preserved")
        defaults.syncOK = false
        do { try UninstallPreferences.clearDomain(UninstallPolicy.domain, in: defaults); preconditionFailure("Sync failure hidden") }
        catch UninstallPreferences.CleanupError.syncFailed { assertions += 1 }
        let before = defaults.calls
        do { try UninstallPreferences.clearDomain("unrelated.app", in: defaults); preconditionFailure("Foreign domain accepted") }
        catch UninstallPreferences.CleanupError.wrongDomain { check(defaults.calls == before, "Foreign domain rejected before any effect") }
    }

    static func testProcessShutdown(_ root: URL, python: String) async throws {
        let folder = root.appendingPathComponent("children")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let script = folder.appendingPathComponent("fake-child.py")
        try """
        import os, pathlib, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        state = pathlib.Path(sys.argv[sys.argv.index('--state-dir') + 1])
        (state / (str(os.getpid()) + '.pid')).write_text(str(os.getpid()))
        while True:
            time.sleep(0.05)
        """.write(to: script, atomically: true, encoding: .utf8)
        let config = CaptureWorker.Configuration(python: python, script: script.path,
                                                  stateDirectory: folder.path, outputDirectory: folder.path)
        func pids() -> [Int32] {
            (try? fm.contentsOfDirectory(atPath: folder.path))?.compactMap {
                $0.hasSuffix(".pid") ? Int32($0.dropLast(4)) : nil
            } ?? []
        }
        func waitForCount(_ count: Int) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while pids().count < count && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            check(pids().count >= count, "Synthetic children started")
        }
        defer { for pid in pids() where kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) } }
        let retired = CaptureWorker(wifiHedgingEnabled: false, wifiOnly: true)
        try retired.prepare(configuration: config)
        try await waitForCount(1)
        retired.stop()
        let worker = CaptureWorker(wifiHedgingEnabled: false, wifiOnly: true)
        try worker.prepare(configuration: config)
        try await waitForCount(2)
        let secondWorker = CaptureWorker(wifiHedgingEnabled: false, wifiOnly: true)
        try secondWorker.prepare(configuration: config)
        try await waitForCount(3)
        let wizard = SetupWizard()
        var callbacks = 0
        wizard.run(python: python, script: script.path, action: "auto", stateDirectory: folder.path,
                   completion: { _ in callbacks += 1 })
        try await waitForCount(4)
        wizard.cancel()
        wizard.run(python: python, script: script.path, action: "auto", stateDirectory: folder.path,
                   completion: { _ in callbacks += 1 })
        try await waitForCount(5)
        // Freeze every owner before draining the shared child registry.
        worker.beginUninstall()
        secondWorker.beginUninstall()
        try await worker.stopForUninstall()
        try await secondWorker.stopForUninstall()
        try await wizard.stopForUninstall()
        check(!wizard.isRunning && !worker.isBusy && !secondWorker.isBusy, "Both device workers and setup stopped")
        check(pids().allSatisfy { kill($0, 0) != 0 && errno == ESRCH }, "Active AND retired children exited before deletion")
        check(callbacks == 0, "Cancelled setup cannot call back and rewrite settings")
        do { try worker.prepare(configuration: config); preconditionFailure("Worker restarted during uninstall") }
        catch { assertions += 1 }
        do { try secondWorker.prepare(configuration: config); preconditionFailure("Second worker restarted during uninstall") }
        catch { assertions += 1 }
        wizard.run(python: python, script: script.path, action: "auto", stateDirectory: folder.path,
                   completion: { _ in callbacks += 1 })
        check(!wizard.isRunning, "Setup cannot restart during uninstall")
    }
}
