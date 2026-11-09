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
        default: return L("Use the same Wi-Fi or connect via USB, then check again.", "两台设备连同一个 Wi-Fi，或用 USB 连接，再检查一次。")
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

// A finished shortcut's receipt, independent of the connection's current state.
// No chat content or window identifiers: the app, result and transfer metadata only.
struct TossCaptureResult: Equatable {
    enum Outcome { case confirmed, unconfirmed, manualPaste, cancelled, failed }
    let target: String
    let outcome: Outcome
    let byteCount: Int?
    let elapsedMilliseconds: Int?
    let transport: String?

    var targetName: String {
        switch target {
        case "claude": return "Claude"
        case "chatgpt": return "Codex"
        default: return L("Target app", "目标应用")
        }
    }

    var summary: String {
        var parts = [outcome == .manualPaste ? L("Clipboard", "剪贴板") : targetName]
        if let bytes = byteCount, bytes > 0 {
            let size = Double(bytes) / 1_000_000
            parts.append(size < 0.1 ? "<0.1 MB" : Self.decimal(size) + " MB")
        }
        if let ms = elapsedMilliseconds, ms >= 0 {
            let seconds = Self.decimal(Double(ms) / 1_000)
            parts.append(L("\(seconds) s", "\(seconds) 秒"))
        }
        // Only the route reported for this screenshot, never the live connection.
        if transport == "usb" { parts.append("USB") }
        else if transport == "wifi" { parts.append("Wi-Fi") }
        return parts.joined(separator: " · ")
    }

    var status: String {
        switch outcome {
        case .confirmed: return L("Success", "成功")
        case .unconfirmed, .manualPaste, .cancelled, .failed:
            return L("Not successful", "不成功")
        }
    }

    var detail: String {
        switch outcome {
        case .confirmed: return ""
        case .unconfirmed: return L("Paste requested. Check the draft before trying again.", "已请求粘贴，请先检查草稿再重试。")
        case .manualPaste: return L("Not delivered to \(targetName). Paste it yourself.", "未投递到 \(targetName)，请手动粘贴。")
        case .cancelled: return L("Cancelled", "已取消")
        case .failed: return L("No paste was requested.", "尚未请求粘贴。")
        }
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
