import Foundation
import Darwin

// One JSON line per hotkey transaction in Application Support/Toss/
// capture-history.jsonl (mode 600), so a "sometimes slow" keypress can be read
// afterwards: every stage's ms since the hotkey, the frame's size and bit depth,
// the backend timings. Metadata only: no image content, identifiers or addresses.
struct CaptureRecord {
    let startedAt: Date
    let target: String
    private(set) var stages: [(stage: String, ms: Int)] = []
    var image: [String: Int] = [:] // bytes, width, height, bit_depth from the receipt
    var timings: [String: Double] = [:]
    var connectionReused: Bool?
    private var transport: String?
    private var routeAttempts: [[String: Any]] = []
    private var routeTotal: Double?
    var composers: Int? // Claude candidates, recorded when no composer could be chosen.
    // Queued presses: "unbound", "bound", "bound-returned" (went back to its chat), "bound-not-provable"
    // (manual paste). Labels only; no chat names, URLs or window identities are stored.
    var queued: String?
    var repeats: [(phase: String, ms: Int)] = [] // chords pressed again while this one ran

    init(startedAt: Date, target: String) {
        self.startedAt = startedAt
        self.target = target
    }

    mutating func reach(_ stage: String, ms: Int) {
        stages.append((stage, ms))
    }

    // Statuses that end a hotkey transaction.
    static func isOutcome(_ code: String) -> Bool {
        if code == "stopped" || code == "copied_for_manual_paste" { return true }
        switch TossTransferPhase.from(code: code) {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    static let imageKeys = ["bytes", "width", "height", "bit_depth"]

    // Receipt fields as plain bounded integers; anything else is left out.
    mutating func takeImage(from receipt: [String: Any]) {
        if let route = receipt["transport"] as? String,
           ["authenticated_wifi", "authenticated_usb"].contains(route) {
            transport = route == "authenticated_usb" ? "usb" : "wifi"
        }
        if let total = Self.milliseconds(receipt["route_total_ms"]) { routeTotal = total }
        if let attempts = receipt["route_attempts"] as? [[String: Any]] {
            // A USB attempt may fall back to primary Wi-Fi and then one standby hedge.
            routeAttempts = attempts.prefix(3).compactMap { attempt in
                guard let route = attempt["transport"] as? String, ["usb", "wifi"].contains(route),
                      let reason = attempt["reason"] as? String,
                      reason.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil,
                      let elapsed = Self.milliseconds(attempt["elapsed_ms"]) else { return nil }
                var clean: [String: Any] = ["transport": route, "reason": reason, "elapsed_ms": elapsed]
                if let role = attempt["worker_role"] as? String,
                   (route == "usb" && role == "usb_primary") ||
                   (route == "wifi" && ["wifi_primary", "wifi_standby"].contains(role)) {
                    clean["worker_role"] = role
                }
                if let times = attempt["timings_ms"] as? [String: Any] {
                    var accepted: [String: Double] = [:]
                    for key in ["connect", "screenshot", "validation", "total", "link_first_byte",
                                "link_stall_max", "link_stall_total", "slow_threshold", "slow_sample_count", "slow_threshold_exempt"] {
                        if let value = Self.milliseconds(times[key]) { accepted[key] = value }
                    }
                    clean["timings_ms"] = accepted
                }
                return clean
            }
        }
        for key in Self.imageKeys {
            if let value = receipt[key] as? Int, (0...64 * 1024 * 1024).contains(value) { image[key] = value }
        }
    }

    private static func milliseconds(_ value: Any?) -> Double? {
        guard let value = value as? Double, value.isFinite, (0...60_000).contains(value) else { return nil }
        return (value * 10).rounded() / 10
    }

    func line(outcome: String, failure: String, backend: String, formatter: ISO8601DateFormatter) -> Data? {
        var object: [String: Any] = [
            "time": formatter.string(from: startedAt), "target": target,
            "outcome": outcome, "failure": failure, "backend": backend,
            "stages": stages.map { ["stage": $0.stage, "ms_since_hotkey": $0.ms] },
            "image": image, "timings_ms": timings.mapValues { ($0 * 10).rounded() / 10 },
            "connection_reused": connectionReused as Any? ?? NSNull()]
        if let composers { object["composers"] = composers }
        if let queued { object["queued"] = queued }
        if let transport { object["transport"] = transport }
        if !routeAttempts.isEmpty { object["route_attempts"] = routeAttempts }
        if let routeTotal { object["route_total_ms"] = routeTotal }
        if !repeats.isEmpty { object["repeats"] = repeats.map { ["phase": $0.phase, "ms": $0.ms] } }
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data
    }
}

final class CaptureHistory: @unchecked Sendable {
    static let keep = 200
    static let rewriteAbove = 250
    private let url: URL
    private let queue = DispatchQueue(label: "Toss.capture-history", qos: .utility)
    private var lines: Int?

    init(url: URL) {
        self.url = url
    }

    // Appends off the main thread; failures only lose this history line.
    func append(_ line: Data) {
        queue.async { [self] in write(line) }
    }

    // Tests: wait for queued writes.
    func flush() {
        queue.sync {}
    }

    // The last `keep` complete lines.
    static func trimmed(_ data: Data, keep: Int = keep) -> Data {
        let parts = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var out = Data()
        for part in parts.suffix(keep) {
            out.append(contentsOf: part)
            out.append(0x0A)
        }
        return out
    }

    private func write(_ line: Data) {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600 || fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            return
        }
        let written = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard written == line.count else { return }
        if lines == nil, let existing = try? Data(contentsOf: url) {
            lines = existing.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        } else {
            lines? += 1
        }
        guard let count = lines, count > Self.rewriteAbove, let existing = try? Data(contentsOf: url) else { return }
        let kept = Self.trimmed(existing)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("capture-history-" + UUID().uuidString + ".tmp")
        let output = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { return }
        let copied = kept.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
        close(output)
        if copied == kept.count, rename(temporary.path, url.path) == 0 {
            lines = Self.keep
        } else {
            unlink(temporary.path)
        }
    }
}
