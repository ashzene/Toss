import Foundation

// Streaming progress from a synthetic script (/bin/sh), never the real backend.
@main
struct SetupWizardTests {
    @MainActor static func main() async {
        var passed = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAILED: \(message)\n", stderr); exit(1) }
            passed += 1
        }
        let progress = SetupWizard.parse(Data(#"{"schema_version":1,"ok":false,"code":"trust_needed","final":false,"model":"iPad14,3"}"#.utf8))
        check(progress?.code == "trust_needed" && progress?.final == false && progress?.model == "iPad14,3", "progress line")
        let legacy = SetupWizard.parse(Data(#"{"schema_version":1,"ok":true,"code":"ready"}"#.utf8))
        check(legacy?.final == true, "legacy single line is final")
        check(SetupWizard.parse(Data(#"{"schema_version":1,"code":"Bad Code"}"#.utf8)) == nil, "unsafe code rejected")
        check(SetupWizard.parse(Data(#"{"schema_version":2,"code":"ready"}"#.utf8)) == nil, "unknown schema rejected")
        check(SetupWizard.needsIPadAction("trust_needed") && SetupWizard.needsIPadAction("developer_mode_needed"), "iPad prompts")
        check(!SetupWizard.needsIPadAction("ready") && !SetupWizard.needsIPadAction("no_usb_ipad"), "no prompt")
        for code in ["ready", "no_usb_ipad", "trust_needed", "developer_mode_auto", "developer_mode_needed",
                     "ipad_restarting", "developer_mode_confirm", "wifi_waiting", "preparing_image"] {
            check(!SetupWizard.message(for: .init(code: code, model: nil, ipados: nil)).hasPrefix("Pairing failed."), "message for \(code)")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("setup-wizard-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake.sh")
        try? """
        echo '{"schema_version":1,"ok":false,"code":"no_usb_ipad","final":false}'
        sleep 0.2
        echo 'library noise that is not json'
        echo '{"schema_version":1,"ok":false,"code":"trust_needed","final":false}'
        sleep 0.2
        echo '{"schema_version":1,"ok":true,"code":"ready","final":true,"model":"iPad14,3"}'
        """.write(to: script, atomically: true, encoding: .utf8)
        let wizard = SetupWizard()
        var seen: [String] = []
        let result: SetupWizard.Result = await withCheckedContinuation { continuation in
            wizard.run(python: "/bin/sh", script: script.path, action: "auto", stateDirectory: directory.path,
                       progress: { seen.append($0.code) }, completion: { continuation.resume(returning: $0) })
        }
        check(seen == ["no_usb_ipad", "trust_needed"], "progress delivered in order before exit: \(seen)")
        check(result.code == "ready" && result.final && result.model == "iPad14,3", "final result")
        check(!wizard.isRunning, "finished")

        try? "echo '{\"schema_version\":1,\"ok\":false,\"code\":\"trust_needed\",\"final\":false}'\n".write(to: script, atomically: true, encoding: .utf8)
        let truncated: SetupWizard.Result = await withCheckedContinuation { continuation in
            wizard.run(python: "/bin/sh", script: script.path, action: "auto", stateDirectory: directory.path,
                       completion: { continuation.resume(returning: $0) })
        }
        check(truncated.code == "setup_failed", "exit without a final line is a failure")
        print("SetupWizard: \(passed) assertions passed; synthetic script only, no device.")
    }
}
