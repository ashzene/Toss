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
        check(progress?.deviceClass == .iPad, "legacy setup infers ProductType")
        check(legacy?.deviceClass == nil, "absent identity remains unknown")
        for (value, expected): (String, Int?) in [("0", 0), ("37", 37), ("100", 100),
                                                 ("101", nil), ("true", nil), ("null", nil)] {
            let data = Data(#"{"schema_version":1,"code":"downloading_image","final":false,"download_percent":\#(value)}"#.utf8)
            check(SetupWizard.parse(data)?.downloadPercent == expected, "download progress field: \(value)")
        }
        let installing = SetupWizard.parse(Data(#"{"schema_version":1,"code":"preparing_image","final":false,"download_percent":90}"#.utf8))
        check(installing?.downloadPercent == nil, "installation has no download percentage")
        let phone = SetupWizard.parse(Data(#"{"schema_version":1,"code":"ready","device_class":"iPhone","model":"iPhone14,6","ipados":"17.7","os_version":"17.7"}"#.utf8))
        check(phone?.deviceClass == .iPhone && phone?.osVersion == "17.7" && phone?.ipados == "17.7", "new fields and unchanged legacy version")
        let oldPhone = SetupWizard.parse(Data(#"{"schema_version":1,"code":"wifi_waiting","model":"iPhone14,6","ipados":"18.1","final":false}"#.utf8))
        check(oldPhone?.deviceClass == .iPhone && oldPhone?.osVersion == "18.1" && oldPhone?.final == false, "legacy iPhone and version fallback")
        let target = SetupWizard.parse(Data(#"{"schema_version":1,"code":"developer_mode_needed","setup_device_hash":"phone"}"#.utf8))
        check(target?.setupDeviceHash == "phone", "setup target survives progress parsing")
        check(SetupWizard.canAttachUSBPrompt(running: true, targetHash: nil, code: "no_usb_ipad", candidateHashes: ["phone"]), "background USB wait attaches")
        check(SetupWizard.canAttachUSBPrompt(running: true, targetHash: "phone", code: "developer_mode_needed", candidateHashes: ["phone"]), "current devmode attaches")
        check(!SetupWizard.canAttachUSBPrompt(running: true, targetHash: "phone", code: "developer_mode_needed", candidateHashes: ["other-phone"]), "same class different hash defers")
        check(!SetupWizard.canAttachUSBPrompt(running: true, targetHash: "phone", code: "developer_mode_needed", candidateHashes: ["phone", "pad"]), "mixed pending set stays pending")
        check(SetupWizard.canAttachUSBPrompt(running: false, targetHash: "phone", code: "ready", candidateHashes: ["pad"]), "completion releases pending target")
        check(!SetupWizard.canAttachUSBPrompt(running: true, targetHash: nil, code: "developer_mode_needed", candidateHashes: ["phone"]), "unknown active target defers")
        check(!SetupWizard.canAttachUSBPrompt(running: true, targetHash: nil, code: "not_run", candidateHashes: ["phone"]), "wait for first progress before deciding target")
        let versions = SetupWizard.parse(Data(#"{"schema_version":1,"code":"ready","device_class":"iPad","ipados":"18.1","os_version":"18.2"}"#.utf8))
        check(versions?.deviceClass == .iPad && versions?.ipados == "18.1" && versions?.osVersion == "18.2", "version fields parsed separately")
        let corrupt = SetupWizard.parse(Data(#"{"schema_version":1,"code":"ready","device_class":42,"model":"iPad14,3","os_version":[]}"#.utf8))
        check(corrupt?.deviceClass == nil && corrupt?.osVersion == nil, "wrong-typed fields do not crash or infer a class")
        for code in ["unsupported_device", "mixed_usb_devices"] {
            for final in [false, true] {
                let data = try! JSONSerialization.data(withJSONObject: ["schema_version": 1, "code": code, "final": final])
                let parsed = SetupWizard.parse(data)!
                check(parsed.code == code && parsed.final == final && parsed.deviceClass == nil, "new code preserved: \(code)")
                let expected = code == "mixed_usb_devices"
                    ? "Keep only the iPad or the iPhone plugged in."
                    : "Connect an iPad or iPhone, version 17 or later."
                check(SetupWizard.message(for: parsed) == expected, "dedicated message for \(code)")
            }
            check(!SetupWizard.needsIPadAction(code), "new error does not ask for Trust or developer mode")
        }
        check(SetupWizard.parse(Data(#"{"schema_version":1,"code":"Bad Code"}"#.utf8)) == nil, "unsafe code rejected")
        check(SetupWizard.parse(Data(#"{"schema_version":2,"code":"ready"}"#.utf8)) == nil, "unknown schema rejected")
        check(SetupWizard.needsIPadAction("trust_needed") && SetupWizard.needsIPadAction("developer_mode_needed"), "iPad prompts")
        check(!SetupWizard.needsIPadAction("ready") && !SetupWizard.needsIPadAction("no_usb_ipad"), "no prompt")
        for code in ["ready", "no_usb_ipad", "trust_needed", "developer_mode_auto", "developer_mode_needed",
                     "ipad_restarting", "developer_mode_confirm", "wifi_waiting", "downloading_image",
                     "preparing_image", "developer_image_download_failed"] {
            check(!SetupWizard.message(for: .init(code: code, model: nil, ipados: nil)).hasPrefix("Pairing failed."), "message for \(code)")
        }

        for (device, en, zh, enOS, zhOS): (String?, String, String, String, String) in [
            (nil, "iPad or iPhone", "iPad 或 iPhone", "iPadOS or iOS", "iPadOS 或 iOS"),
            ("iPad", "iPad", "iPad", "iPadOS", "iPadOS"), ("iPhone", "iPhone", "iPhone", "iOS", "iOS")
        ] {
            let previousDevice = DeviceCopy.deviceClass, previousLanguage = AppLanguage.override
            DeviceCopy.deviceClass = device
            defer { DeviceCopy.deviceClass = previousDevice; AppLanguage.override = previousLanguage }
            let shortName = device ?? "device", subject = device ?? "the device"
            let titles = [
                ("trust_needed", "Tap Trust on Your \(en)", "在 \(zh) 上点「信任」"),
                ("developer_mode_needed", "Enable Developer Mode on Your \(en)", "在 \(zh) 上打开开发者模式"),
                ("developer_mode_confirm", "Confirm Developer Mode on Your \(en)", "在 \(zh) 上确认开发者模式"),
                ("unlock_needed", "Unlock Your \(en)", "解锁 \(zh)"),
                ("unknown", "\(en) Pairing", "配对 \(zh)")
            ]
            let messages = [
                ("no_usb_ipad", "Plug in your \(en) and unlock it.", "插上 \(zh) 并解锁。"),
                ("multiple_usb_ipads", "Keep only one \(en) plugged in.", "只插要配对的那一台 \(zh)。"),
                ("mixed_usb_devices", "Keep only the iPad or the iPhone plugged in.", "iPad 和 iPhone 只插要配对的那一台。"),
                ("unsupported_device", "Connect an iPad or iPhone, version 17 or later.", "请连接 iPad 或 iPhone，系统 17 或更新。"),
                ("unlock_needed", "Unlock your \(en).", "请解锁 \(zh)。"),
                ("unsupported_ipados", "Needs \(enOS) 17 or later.", "需要 \(zhOS) 17 或更新。"),
                ("trust_needed", "Tap Trust on your \(shortName), enter the passcode.", "在 \(zh) 上点「信任」，输入密码。"),
                ("developer_mode_auto", "Turning on Developer Mode; \(subject) restarts.", "正在打开开发者模式，\(zh) 会重启。"),
                ("developer_mode_needed", "Turn on Developer Mode on your \(en).", "在 \(zh) 上打开开发者模式。"),
                ("ipad_restarting", "\(en) is restarting. Keep the cable in.", "\(zh) 正在重启，数据线别拔。"),
                ("developer_mode_confirm", "On your \(shortName), tap Turn On, enter passcode.", "在 \(zh) 上点「打开」，输入密码。"),
                ("downloading_image", "Downloading the screenshot component…", "正在下载截图组件…"),
                ("preparing_image", "Installing the screenshot component…", "正在安装截图组件…"),
                ("developer_image_download_failed", "The screenshot component couldn't download. Check your internet connection and try again.", "截图组件下载失败。 请检查网络连接，然后重试。"),
                ("wifi_waiting", "Looking for the \(en) on your Wi-Fi…", "正在 Wi-Fi 上找 \(zh)…"),
                ("not_paired", "Nothing paired yet. Plug in an iPad or iPhone.", "还没配对设备，插上 iPad 或 iPhone 就开始。")
            ]
            for chinese in [false, true] {
                AppLanguage.override = chinese
                for (code, english, chineseText) in titles {
                    check(SetupWizard.title(for: code) == (chinese ? chineseText : english), "\(device ?? "nil") title \(code), Chinese=\(chinese)")
                }
                for (code, english, chineseText) in messages {
                    check(SetupWizard.message(for: .init(code: code, model: nil, ipados: nil)) == (chinese ? chineseText : english),
                          "\(device ?? "nil") message \(code), Chinese=\(chinese)")
                }
            }
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
        echo '{"schema_version":1,"ok":false,"code":"downloading_image","final":false,"download_percent":64}'
        echo '{"schema_version":1,"ok":false,"code":"preparing_image","final":false}'
        echo '{"schema_version":1,"ok":true,"code":"ready","final":true,"model":"iPad14,3"}'
        """.write(to: script, atomically: true, encoding: .utf8)
        let wizard = SetupWizard()
        var seen: [SetupWizard.Result] = []
        let result: SetupWizard.Result = await withCheckedContinuation { continuation in
            wizard.run(python: "/bin/sh", script: script.path, action: "auto", stateDirectory: directory.path,
                       progress: { seen.append($0) }, completion: { continuation.resume(returning: $0) })
        }
        check(seen.map(\.code) == ["no_usb_ipad", "trust_needed", "downloading_image", "preparing_image"],
              "progress delivered in order before exit: \(seen)")
        check(seen[2].downloadPercent == 64 && seen[3].downloadPercent == nil, "streaming download hands off to installation")
        check(result.code == "ready" && result.final && result.model == "iPad14,3", "final result")
        check(!wizard.isRunning, "finished")

        try? "echo '{\"schema_version\":1,\"ok\":false,\"code\":\"trust_needed\",\"final\":false}'\n".write(to: script, atomically: true, encoding: .utf8)
        let truncated: SetupWizard.Result = await withCheckedContinuation { continuation in
            wizard.run(python: "/bin/sh", script: script.path, action: "auto", stateDirectory: directory.path,
                       completion: { continuation.resume(returning: $0) })
        }
        check(truncated.code == "setup_failed", "exit without a final line is a failure")
        try? """
        echo '{"schema_version":1,"code":"trust_needed","final":false,"device_class":"iPhone","model":"iPhone14,6","ipados":"17.7","os_version":"17.7"}'
        """.write(to: script, atomically: true, encoding: .utf8)
        var streamed: SetupWizard.Result?
        let phoneFailure: SetupWizard.Result = await withCheckedContinuation { continuation in
            wizard.run(python: "/bin/sh", script: script.path, action: "auto", stateDirectory: directory.path,
                       progress: { streamed = $0 }, completion: { continuation.resume(returning: $0) })
        }
        check(streamed?.deviceClass == .iPhone && streamed?.osVersion == "17.7", "new metadata delivered on progress")
        check(phoneFailure.code == "setup_failed" && phoneFailure.final && phoneFailure.deviceClass == .iPhone && phoneFailure.osVersion == "17.7", "truncated stream retains metadata in synthesized failure")
        print("SetupWizard: \(passed) assertions passed; synthetic script only, no device.")
    }
}
