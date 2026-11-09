import Foundation
import Darwin

// Record encoding and the 250/200-line trim, against a private temporary file.
@main
struct CaptureHistoryTests {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ line: UInt = #line) {
            if !condition { fatalError("CaptureHistory check failed at line \(line)") }
            count += 1
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for code in ["append_confirmed", "append_unconfirmed", "append_failed", "capture_setup_failed",
                     "capture_result_failed", "copied_for_manual_paste", "input_interrupted", "hotkey_rejected", "cancelled", "stopped"] {
            check(CaptureRecord.isOutcome(code))
        }
        for code in ["locating_target", "activating_target", "target_located", "capturing",
                     "revalidating_capture", "captured", "focusing_composer", "paste_posted", "ready"] {
            check(!CaptureRecord.isOutcome(code))
        }

        var record = CaptureRecord(startedAt: Date(timeIntervalSince1970: 1_761_100_000), target: "chatgpt")
        record.reach("locating_target", ms: 2)
        record.reach("append_confirmed", ms: 1310)
        record.takeImage(from: ["bytes": 11_470_282, "width": 2388, "height": 1668, "bit_depth": 16,
                                "sha256": "ab", "request_id": "x", "ok": true, "huge": 1 << 40])
        record.takeImage(from: ["width": "2388"])
        record.timings = ["screenshot": 912.345, "total": 1001.04]
        record.connectionReused = true
        let line = record.line(outcome: "append_confirmed", failure: "none", backend: "captured",
                               formatter: formatter)!
        check(line.last == 0x0A && line.filter { $0 == 0x0A }.count == 1)
        let object = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        check(Set(object.keys) == ["time", "target", "outcome", "failure", "backend", "stages", "image",
                                   "timings_ms", "connection_reused"])
        check(object["time"] as? String == "2025-10-22T02:26:40.000Z")
        check(object["outcome"] as? String == "append_confirmed")
        check((object["image"] as? [String: Int]) == ["bytes": 11_470_282, "width": 2388, "height": 1668, "bit_depth": 16])
        check((object["timings_ms"] as? [String: Double]) == ["screenshot": 912.3, "total": 1001.0])
        check(object["connection_reused"] as? Bool == true)
        let stages = object["stages"] as? [[String: Any]]
        check(stages?.count == 2 && stages?.last?["stage"] as? String == "append_confirmed"
              && stages?.last?["ms_since_hotkey"] as? Int == 1310)
        let empty = CaptureRecord(startedAt: Date(), target: "claude")
            .line(outcome: "capture_setup_failed", failure: "noComposer", backend: "none", formatter: formatter)!
        let emptyObject = try JSONSerialization.jsonObject(with: empty) as! [String: Any]
        check(emptyObject["connection_reused"] is NSNull)
        check((emptyObject["image"] as? [String: Int])?.isEmpty == true)
        check(emptyObject["composers"] == nil)
        var ambiguous = CaptureRecord(startedAt: Date(), target: "claude")
        ambiguous.composers = 2
        let ambiguousObject = try JSONSerialization.jsonObject(
            with: ambiguous.line(outcome: "capture_setup_failed", failure: "composersAmbiguous", backend: "none",
                                 formatter: formatter)!) as! [String: Any]
        check(ambiguousObject["composers"] as? Int == 2)
        check(emptyObject["queued"] == nil) // single presses carry no queue label
        var queuedRecord = CaptureRecord(startedAt: Date(), target: "chatgpt")
        queuedRecord.queued = "bound-returned"
        let queuedObject = try JSONSerialization.jsonObject(
            with: queuedRecord.line(outcome: "append_confirmed", failure: "none", backend: "captured",
                                    formatter: formatter)!) as! [String: Any]
        check(queuedObject["queued"] as? String == "bound-returned")
        check(emptyObject["repeats"] == nil)
        var routed = CaptureRecord(startedAt: Date(), target: "claude")
        routed.takeImage(from: ["transport": "authenticated_wifi", "route_total_ms": 1110.456,
            "route_attempts": [
                ["transport": "usb", "reason": "first_byte_timeout", "elapsed_ms": 802.4,
                 "timings_ms": ["connect": 0.3, "screenshot": 800.5, "secret": 123.0], "device": "PRIVATE"],
                ["transport": "wifi", "reason": "ok", "elapsed_ms": 300.0,
                 "timings_ms": ["connect": 1.0, "screenshot": 280.0, "validation": 3.0]],
                ["transport": "wifi", "worker_role": "wifi_standby", "reason": "ok", "elapsed_ms": 220.0],
                ["transport": "usb", "reason": "ignored", "elapsed_ms": 2.0]]])
        routed.timings = ["screenshot": 280] // TossApp assigns this after takeImage.
        let routedData = routed.line(outcome: "append_confirmed", failure: "none", backend: "captured", formatter: formatter)!
        let routedObject = try JSONSerialization.jsonObject(with: routedData) as! [String: Any]
        check(routedObject["transport"] as? String == "wifi")
        check(routedObject["route_total_ms"] as? Double == 1110.5)
        let attempts = routedObject["route_attempts"] as? [[String: Any]]
        check(attempts?.count == 3 && attempts?.first?["transport"] as? String == "usb")
        check(attempts?.last?["worker_role"] as? String == "wifi_standby")
        check(!CaptureRecord.isOutcome("capture_slow"))
        check((attempts?.first?["timings_ms"] as? [String: Double]) == ["connect": 0.3, "screenshot": 800.5])
        check(!String(data: routedData, encoding: .utf8)!.contains("PRIVATE"))
        var threshold = CaptureRecord(startedAt: Date(), target: "chatgpt")
        threshold.takeImage(from: ["route_attempts": [
            ["transport": "usb", "reason": "slow_threshold", "elapsed_ms": 751.0,
             "timings_ms": ["slow_threshold": 751.0, "slow_sample_count": 100.0, "slow_threshold_exempt": 0.0]],
            ["transport": "wifi", "reason": "slow_threshold", "elapsed_ms": 1608.0,
             "timings_ms": ["slow_threshold": 1608.0, "slow_sample_count": 61.0, "slow_threshold_exempt": 0.0]]]])
        threshold.timings = ["slow_threshold": 1608, "slow_sample_count": 61, "slow_threshold_exempt": 0]
        let thresholdObject = try JSONSerialization.jsonObject(with: threshold.line(outcome: "capture_result_failed",
            failure: "captureFailed", backend: "slow_threshold", formatter: formatter)!) as! [String: Any]
        let thresholdAttempts = thresholdObject["route_attempts"] as! [[String: Any]]
        check(thresholdObject["backend"] as? String == "slow_threshold")
        check((thresholdObject["timings_ms"] as? [String: Double])?["slow_sample_count"] == 61)
        check((thresholdAttempts[0]["timings_ms"] as? [String: Double])?["slow_threshold"] == 751)
        check((thresholdAttempts[1]["timings_ms"] as? [String: Double])?["slow_sample_count"] == 61)
        check((thresholdAttempts[1]["timings_ms"] as? [String: Double])?["slow_threshold_exempt"] == 0)

        var invalidRoute = CaptureRecord(startedAt: Date(), target: "claude")
        invalidRoute.takeImage(from: ["transport": "untrusted", "route_total_ms": Double.infinity,
            "route_attempts": [["transport": "usb", "reason": "bad reason", "elapsed_ms": -1]]])
        let invalidObject = try JSONSerialization.jsonObject(with: invalidRoute.line(outcome: "failed", failure: "none",
            backend: "none", formatter: formatter)!) as! [String: Any]
        check(invalidObject["transport"] == nil && invalidObject["route_total_ms"] == nil && invalidObject["route_attempts"] == nil)
        ambiguous.repeats = [("capturing", 640), ("pasted", 1200)]
        let repeatsObject = try JSONSerialization.jsonObject(
            with: ambiguous.line(outcome: "append_confirmed", failure: "none", backend: "captured",
                                 formatter: formatter)!) as! [String: Any]
        let repeats = repeatsObject["repeats"] as? [[String: Any]]
        check(repeats?.count == 2 && repeats?.first?["phase"] as? String == "capturing"
              && repeats?.last?["ms"] as? Int == 1200)

        // Menu receipts come from this shortcut, including its winning route and
        // whole hotkey-to-result duration, not just backend transfer time.
        var delivered = CaptureRecord(startedAt: Date(), target: "claude")
        delivered.takeImage(from: ["bytes": 3_200_000, "transport": "authenticated_wifi",
            "route_attempts": [["transport": "usb", "reason": "first_byte_timeout", "elapsed_ms": 800.0]]])
        delivered.reach("paste_posted", ms: 1200)
        delivered.reach("append_confirmed", ms: 1400)
        let success = delivered.menuResult(outcome: "append_confirmed")
        check(success.outcome == .confirmed && success.transport == "wifi")
        check(success.elapsedMilliseconds == 1400 && success.byteCount == 3_200_000)
        AppLanguage.override = true
        check(success.summary == "Claude · 3.2 MB · 1.4 秒 · Wi-Fi")
        check(success.status == "成功" && success.detail.isEmpty)
        AppLanguage.override = false
        check(success.summary == "Claude · 3.2 MB · 1.4 s · Wi-Fi")
        check(success.status == "Success")
        for outcome in ["append_unconfirmed", "cancelled", "stopped", "input_interrupted", "unfinished", "append_failed"] {
            let result = delivered.menuResult(outcome: outcome)
            check(result.outcome == .unconfirmed && result.status == "Not successful")
            check(result.detail.contains("Check the draft"))
        }
        var recovered = CaptureRecord(startedAt: Date(), target: "chatgpt")
        recovered.takeImage(from: ["bytes": 2_000_000, "transport": "authenticated_usb"])
        recovered.reach("copied_for_manual_paste", ms: 2300)
        let manual = recovered.menuResult(outcome: "copied_for_manual_paste")
        check(manual.outcome == .manualPaste)
        check(manual.summary == "Clipboard · 2.0 MB · 2.3 s · USB")
        check(manual.detail == "Not delivered to Codex. Paste it yourself.")
        var failed = CaptureRecord(startedAt: Date(), target: "claude")
        failed.reach("capture_setup_failed", ms: 210)
        let failure = failed.menuResult(outcome: "capture_setup_failed")
        check(failure.outcome == .failed && failure.summary == "Claude · 0.2 s")
        check(failure.byteCount == nil && failure.transport == nil)
        check(failed.menuResult(outcome: "cancelled").outcome == .cancelled)
        check(failed.menuResult(outcome: "append_unconfirmed").outcome == .unconfirmed)
        let noReceipt = CaptureRecord(startedAt: Date(), target: "chatgpt").menuResult(outcome: "unfinished")
        check(noReceipt.summary == "Codex" && noReceipt.elapsedMilliseconds == nil)
        check(invalidRoute.menuResult(outcome: "capture_result_failed").transport == nil)
        var tiny = CaptureRecord(startedAt: Date(), target: "claude")
        tiny.takeImage(from: ["bytes": 16_000])
        check(tiny.menuResult(outcome: "append_confirmed").summary == "Claude · <0.1 MB")
        AppLanguage.override = nil

        check(CaptureHistory.trimmed(Data("a\nb\nc\n".utf8), keep: 2) == Data("b\nc\n".utf8))
        check(CaptureHistory.trimmed(Data("a\nb\npartial".utf8), keep: 2) == Data("b\npartial\n".utf8))
        check(CaptureHistory.trimmed(Data(), keep: 2).isEmpty)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture-history.jsonl")
        let history = CaptureHistory(url: url)
        for index in 1...251 { history.append(Data("{\"n\":\(index)}\n".utf8)) }
        history.flush()
        var text = try String(contentsOf: url, encoding: .utf8)
        var rows = text.split(separator: "\n")
        check(rows.count == CaptureHistory.keep && rows.first == "{\"n\":52}" && rows.last == "{\"n\":251}")
        var info = stat()
        check(stat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        for index in 252...300 { history.append(Data("{\"n\":\(index)}\n".utf8)) }
        history.flush()
        text = try String(contentsOf: url, encoding: .utf8)
        rows = text.split(separator: "\n")
        check(rows.count == 249 && rows.last == "{\"n\":300}") // Not past 250 yet: no rewrite.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        check(leftovers == ["capture-history.jsonl"])

        // An existing file that is not private is fixed, a symlink is refused.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        history.append(Data("{\"n\":301}\n".utf8))
        history.flush()
        check(stat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        let target = directory.appendingPathComponent("elsewhere.txt")
        try Data().write(to: target)
        let linked = directory.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        let viaLink = CaptureHistory(url: linked)
        viaLink.append(Data("{}\n".utf8))
        viaLink.flush()
        check(try Data(contentsOf: target).isEmpty)

        print("CaptureHistory: \(count) assertions passed; private temporary files only.")
    }
}
