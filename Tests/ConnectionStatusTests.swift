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
        print("Connection status: \(count) assertions passed.")
    }
}
