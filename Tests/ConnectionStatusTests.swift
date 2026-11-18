import Foundation

@main
struct ConnectionStatusTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool) { precondition(condition); count += 1 }
        let ready: [String: Any] = ["schema_version": 1, "event": "connection",
                                   "state": "ready", "reason": "ready"]
        check(TossConnectionStatus.event(ready)?.state == .ready)
        let usb = TossConnectionStatus(state: .ready, reason: "ready", transport: "usb")
        check(usb.isHealthyUSB && usb.transportLabel == "USB")
        check(!TossConnectionStatus(state: .failed, reason: "timeout", transport: "usb").isHealthyUSB)
        check(!TossConnectionStatus(state: .ready, reason: "ready", transport: "wifi").isHealthyUSB)
        check(TossConnectionStatus(state: .ready, reason: "ready", transport: "wifi").transportLabel == "Wi-Fi")
        check(TossConnectionStatus.notChecked.transportLabel == nil)
        check(TossConnectionStatus(state: .failed, reason: "unexpected_library_version", transport: "usb")
            .errorMessage?.contains("newer Toss") == true)
        for (key, value) in [("schema_version", true as Any), ("schema_version", 1.5),
                             ("event", "capture"), ("state", "invented"),
                             ("reason", "PRIVATE DATA"), ("reason", "connecting")] {
            var malformed = ready
            malformed[key] = value
            check(TossConnectionStatus.event(malformed) == nil)
        }
        var receipt = ready
        receipt["request_id"] = UUID().uuidString
        check(TossConnectionStatus.event(receipt) == nil)
        check(TossTransferPhase.from(code: "capture_slow") == .slow)
        check(TossConnectionStatus(state: .ready, reason: "ready", transport: "wifi").errorMessage == nil)
        for code in ["target_located", "capturing", "capture_slow", "captured", "revalidating_capture",
                     "focusing_composer", "paste_posted"] {
            check(TossTransferPhase.from(code: code).animates)
        }
        for code in ["append_confirmed", "capture_setup_failed", "capture_result_failed",
                     "append_failed", "append_unconfirmed", "input_interrupted", "cancelled",
                     "stopped", "ready", "hotkey_rejected"] {
            check(!TossTransferPhase.from(code: code).animates)
        }
        for (device, en, zh, enOS, zhOS): (String?, String, String, String, String) in [
            (nil, "iPad or iPhone", "iPad 或 iPhone", "iPadOS or iOS", "iPadOS 或 iOS"),
            ("iPad", "iPad", "iPad", "iPadOS", "iPadOS"), ("iPhone", "iPhone", "iPhone", "iOS", "iOS")
        ] {
            let previousDevice = DeviceCopy.deviceClass, previousLanguage = AppLanguage.override
            DeviceCopy.deviceClass = device
            defer { DeviceCopy.deviceClass = previousDevice; AppLanguage.override = previousLanguage }
            let shortName = device ?? "device", subject = device ?? "The device"
            for (reason, english, chinese) in [
                ("usb_ipados_unsupported", "USB needs \(enOS) 17.4 or later.", "USB 需要 \(zhOS) 17.4 或更新。"),
                ("rsd_device_identity_mismatch", "This isn't the paired \(en). Pair it again.", "这不是配对过的 \(zh)，请重新配对。"),
                ("timeout", "Unlock your \(shortName), use your Mac's network.", "解锁 \(zh)，和 Mac 连同一个网络。"),
                ("developer_image_unavailable", "\(subject) isn't ready. Unlock it and check again.", "\(zh) 还没准备好，解锁后再检查。"),
                ("service_unavailable", "\(subject) isn't ready. Unlock it and check again.", "\(zh) 还没准备好，解锁后再检查。"),
                ("disconnected", "\(en) disconnected. Reconnecting…", "\(zh) 断开了，正在重连…")
            ] {
                let status = TossConnectionStatus(state: .failed, reason: reason)
                AppLanguage.override = false; check(status.errorMessage == english)
                AppLanguage.override = true; check(status.errorMessage == chinese)
            }
        }
        print("Connection status: \(count) assertions passed.")
    }
}
