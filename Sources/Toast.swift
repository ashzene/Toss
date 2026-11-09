import Foundation

// Text, gating and preference for the result toast. The toast itself is drawn in
// CaptureAnimation.swift; since 2026-10-24 it is the only thing shown in the corner.

// All user-facing toast strings live here; the language follows Settings → Language.
enum ToastCopy {
    enum Language { case english, chinese }
    static var language: Language { AppLanguage.isChinese ? .chinese : .english }
    struct Strings {
        let codex: String
        let claude: String
        let failure: String
        let manualPaste: String
        let blackScreen: String
        let slow: String
        let notConnected: String
        let pairing: String
        let unconfirmed: String
        let notifications: String
    }
    static func strings(_ language: Language = language) -> Strings {
        switch language {
        case .english:
            return Strings(codex: Translations.text("Tossed successfully"), claude: Translations.text("Tossed successfully"),
                           failure: Translations.text("Didn't attach"), manualPaste: Translations.text("Copied — paste it yourself"),
                           blackScreen: Translations.text("iPad screenshot is black"),
                           slow: Translations.text("iPad connection too slow"), notConnected: Translations.text("iPad not connected"),
                           pairing: Translations.text("Pair your iPad again"), unconfirmed: Translations.text("Check your draft"),
                           notifications: Translations.text("Show notifications"))
        case .chinese:
            return Strings(codex: "已成功 Toss", claude: "已成功 Toss",
                           failure: "没贴进去", manualPaste: "已复制，可以手动粘贴",
                           blackScreen: "iPad 截图是黑的",
                           slow: "iPad 连接太慢", notConnected: "iPad 没连上",
                           pairing: "需要重新配对 iPad", unconfirmed: "看看草稿里有没有",
                           notifications: "显示通知")
        }
    }
}

struct ToastContent: Equatable {
    enum Kind { case success, failure }
    let kind: Kind
    let title: String
    let reason: String
    var holdDuration: TimeInterval { kind == .success ? 1.6 : 2.6 }

    static func success(target: TargetKind, language: ToastCopy.Language = ToastCopy.language) -> Self {
        let copy = ToastCopy.strings(language)
        return Self(kind: .success, title: target == .claude ? copy.claude : copy.codex, reason: "")
    }

    // Report the observed frame content; black pixels alone do not verify lock/sleep state.
    static func failure(reason: String, code: String, cue: Bool, backend: String? = nil,
                        language: ToastCopy.Language = ToastCopy.language) -> Self? {
        // Keep silent cancellation, setup and connection checks silent, even if
        // a future caller accidentally passes cue: true for one of those paths.
        guard cue, ["capture_setup_failed", "capture_result_failed", "append_failed", "append_unconfirmed",
                    "copied_for_manual_paste"].contains(code)
        else { return nil }
        return Self(kind: .failure, title: failureTitle(code: code, backend: backend, copy: ToastCopy.strings(language)),
                    reason: showsFailureReason ? shortReason(reason) : "")
    }

    // Ashley 2026-10-28 ("换成对应报错"): one short title per actual cause instead of a single
    // "Didn't attach". Only the screenshot step has a backend reason; paste-side failures keep the
    // plain title, except a paste that was sent but not confirmed, which may well be in the draft.
    static let slowReasons: Set<String> = ["timeout", "first_byte_timeout", "stall_timeout", "too_slow", "slow_threshold"]
    static let notConnectedReasons: Set<String> = ["no_authenticated_remote_wifi_connection", "network_unavailable", "disconnected",
        "lan_interface_not_identified", "service_unavailable", "worker_failed", "capture_failed", "attempt_failed"]
    static let pairingReasons: Set<String> = ["unexpected_device_pin", "rsd_device_identity_mismatch",
        "pairing_state_missing", "pairing_state_not_private", "strict_remote_pairing_record_mismatch",
        "strict_remote_pairing_record_incomplete", "remote_pairing_record_not_private", "remote_pair_verify_rejected",
        "remote_pair_verify_m4_rejected", "remote_peer_signature_not_verified", "remote_peer_identifier_mismatch",
        "initial_usb_remote_pairing_required", "private_existing_state_directory_required"]
    static func failureTitle(code: String, backend: String?, copy: ToastCopy.Strings) -> String {
        if code == "copied_for_manual_paste" { return copy.manualPaste }
        if code == "append_unconfirmed" { return copy.unconfirmed }
        guard code == "capture_result_failed", let backend else { return copy.failure }
        if backend == "black_frame_rejected" { return copy.blackScreen }
        if slowReasons.contains(backend) { return copy.slow }
        if notConnectedReasons.contains(backend) { return copy.notConnected }
        if pairingReasons.contains(backend) { return copy.pairing }
        return copy.failure
    }

    // Ashley 2026-10-24: the failure toast shows only "Didn't attach"; the reason stays
    // in Diagnostics. Flip this to bring the grey second line back.
    static let showsFailureReason = false

    static func shortReason(_ reason: String, limit: Int = 100) -> String {
        let line = reason.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard limit > 0 else { return "" }
        return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
    }
}

@MainActor
final class ToastPreferences {
    static let key = "toastEnabled"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var enabled: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

enum TransferNotice {
    static func text(received: Double, expected: Double, queued: Int,
                     language: ToastCopy.Language = ToastCopy.language) -> String {
        var value = language == .chinese ? "图片正在传过来…" : Translations.text("Image on its way…")
        if received.isFinite, expected.isFinite, expected > 0, received >= 0 {
            value += " \(Int(min(100, max(0, received / expected * 100))))%"
        }
        if queued > 0 { value += language == .chinese ? "\n还有 \(queued) 张" : Translations.text("\n\(queued) more") }
        return value
    }
}
