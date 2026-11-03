import Foundation
import CoreFoundation

// Connection metadata is never a screenshot receipt. These events may arrive
// with no request pending and must not complete, cancel or extend a capture.
struct TossConnectionStatus: Equatable {
    enum State: String {
        case notChecked, connecting, ready, disconnected, failed
    }
    let state: State
    let reason: String
    var transport: String? = nil
    var isHealthyUSB: Bool { state == .ready && transport == "usb" }
    var transportLabel: String? {
        switch transport {
        case "usb": return "USB"
        case "wifi": return "Wi-Fi"
        default: return nil
        }
    }
    static let notChecked = Self(state: .notChecked, reason: "not_checked")

    static func event(_ value: [String: Any]) -> Self? {
        guard Set(value.keys) == ["schema_version", "event", "state", "reason"],
              let version = value["schema_version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
              version.doubleValue == 1,
              value["event"] as? String == "connection",
              let raw = value["state"] as? String, let state = State(rawValue: raw),
              state != .notChecked,
              let reason = value["reason"] as? String,
              reason.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil else { return nil }
        guard state != .ready || reason == "ready",
              state != .connecting || reason == "connecting" else { return nil }
        return Self(state: state, reason: reason)
    }

    var errorMessage: String? {
        guard state == .failed || state == .disconnected else { return nil }
        switch reason {
        case "unexpected_library_version":
            return L("USB needs a newer Toss. Wi-Fi still works.", "USB 要更新 Toss，Wi-Fi 照常能用。")
        case "usb_ipados_unsupported":
            return L("USB needs iPadOS 17.4 or later.", "USB 需要 iPadOS 17.4 或更新。")
        case "rsd_device_identity_mismatch":
            return L("This isn't the paired iPad. Pair it again.", "这不是配对过的 iPad，请重新配对。")
        case "network_unavailable": return L("Your Mac is offline.", "Mac 没联网。")
        case "timeout": return L("Unlock your iPad, use your Mac's network.", "解锁 iPad，和 Mac 连同一个网络。")
        case "developer_image_unavailable", "service_unavailable":
            return L("iPad isn't ready. Unlock it and check again.", "iPad 还没准备好，解锁后再检查。")
        case "private_existing_state_directory_required", "unexpected_device_pin":
            return L("Pairing info missing. Pair again.", "找不到配对信息，请重新配对。")
        case "worker_failed", "capture_integrity_failed":
            return L("The connection stopped. Check again.", "连接停了，再检查一次。")
        case "disconnected":
            return L("iPad disconnected. Reconnecting…", "iPad 断开了，正在重连…")
        case "cancelled": return L("Check cancelled.", "检查已取消。")
        default: return L("Put both on the same Wi-Fi, then check again.", "两台设备连同一个 Wi-Fi，再检查一次。")
        }
    }
}

enum TossTransferPhase: Equatable {
    case idle, preparing, uploading, slow, completed, failed, cancelled
    var animates: Bool { self == .uploading || self == .slow }

    static func from(code: String) -> Self {
        switch code {
        case "activating_target", "locating_target": return .preparing
        case "capture_slow": return .slow
        case "target_located", "capturing", "revalidating_capture", "captured",
             "focusing_composer", "paste_posted": return .uploading
        case "append_confirmed": return .completed
        case "cancelled", "input_interrupted", "hotkey_rejected": return .cancelled
        default: return code.contains("failed") || code.contains("unconfirmed") ? .failed : .idle
        }
    }
}
