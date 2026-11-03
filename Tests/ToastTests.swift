import AppKit

// Exercise preference reads/writes without creating a domain in ~/Library/Preferences.
private final class InMemoryToastDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

// No NSApplication, NSWindow, device, target process, or real preference domain.
@main
enum ToastTests {
    @MainActor
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let codex = ToastContent.success(target: .chatGPT)
        let claude = ToastContent.success(target: .claude)
        check(codex.title == "Tossed successfully", "ChatGPT target success copy")
        check(claude.title == "Tossed successfully", "Claude target success copy")
        check(codex.reason.isEmpty && claude.reason.isEmpty, "success needs no reason")
        check(ToastContent.success(target: .chatGPT, language: .chinese).title == "已成功 Toss", "Chinese Codex copy")
        check(ToastContent.success(target: .claude, language: .chinese).title == "已成功 Toss", "Chinese Claude copy")
        check(ToastCopy.strings(.english).notifications == "Show notifications", "English settings row")
        check(ToastCopy.strings(.chinese).notifications == "显示通知", "Chinese settings row")
        for code in ["capture_setup_failed", "capture_result_failed", "append_failed", "append_unconfirmed"] {
            let plain = code == "append_unconfirmed" ? "Check your draft" : "Didn't attach"
            check(ToastContent.failure(reason: "Failed", code: code, cue: true)?.title == plain, "cued keypress failure: \(code)")
            check(ToastContent.failure(reason: "Failed", code: code, cue: false) == nil, "uncued failure: \(code)")
        }
        for code in ["input_interrupted", "connection_check_failed", "enable_failed", "target_check_failed", "cancelled", "unknown"] {
            check(ToastContent.failure(reason: "Failed", code: code, cue: true) == nil, "non-keypress path stays silent: \(code)")
        }
        let failure = ToastContent.failure(reason: "  The draft\nchanged.\tTry again.  ", code: "append_failed", cue: true)!
        check(failure.title == "Didn't attach", "failure is independent of the target")
        check(failure.reason.isEmpty, "failure toast has no reason line (2026-10-24)")
        check(ToastContent.shortReason("  The draft\nchanged.\tTry again.  ") == "The draft changed. Try again.", "reason is trimmed to one line")
        check(ToastContent.failure(reason: "", code: "append_failed", cue: true, language: .chinese)?.title == "没贴进去", "Chinese failure copy")
        check(ToastContent.failure(reason: "", code: "capture_result_failed", cue: true, backend: "black_frame_rejected")?.title
              == "iPad screenshot is black", "black frame: reports content without claiming screen/lock state")
        check(ToastContent.failure(reason: "", code: "capture_result_failed", cue: true, backend: "black_frame_rejected",
                                   language: .chinese)?.title == "iPad 截图是黑的", "Chinese black-frame copy")
        // One title per actual cause (2026-10-28).
        for (backend, english, chinese) in [("timeout", "iPad connection too slow", "iPad 连接太慢"),
                                            ("slow_threshold", "iPad connection too slow", "iPad 连接太慢"),
                                            ("first_byte_timeout", "iPad connection too slow", "iPad 连接太慢"),
                                            ("stall_timeout", "iPad connection too slow", "iPad 连接太慢"),
                                            ("too_slow", "iPad connection too slow", "iPad 连接太慢"),
                                            ("no_authenticated_remote_wifi_connection", "iPad not connected", "iPad 没连上"),
                                            ("worker_failed", "iPad not connected", "iPad 没连上"),
                                            ("unexpected_device_pin", "Pair your iPad again", "需要重新配对 iPad"),
                                            ("remote_pair_verify_rejected", "Pair your iPad again", "需要重新配对 iPad"),
                                            ("capture_integrity_failed", "Didn't attach", "没贴进去")] {
            check(ToastContent.failure(reason: "", code: "capture_result_failed", cue: true, backend: backend)?.title == english,
                  "English title for \(backend)")
            check(ToastContent.failure(reason: "", code: "capture_result_failed", cue: true, backend: backend,
                                       language: .chinese)?.title == chinese, "Chinese title for \(backend)")
        }
        check(ToastContent.failure(reason: "", code: "append_unconfirmed", cue: true, language: .chinese)?.title == "看看草稿里有没有",
              "a sent but unconfirmed paste says it may be in the draft")
        check(ToastContent.failure(reason: "", code: "capture_setup_failed", cue: true, backend: "timeout")?.title
              == "Didn't attach", "a stale backend reason does not relabel a setup failure")
        check(ToastContent.failure(reason: "", code: "append_failed", cue: true, backend: "black_frame_rejected")?.title
              == "Didn't attach", "a stale backend reason does not relabel a paste failure")
        // The original chat could not take the paste: the screenshot stays on the clipboard (2026-10-28).
        check(ToastContent.failure(reason: "", code: "copied_for_manual_paste", cue: true)?.title == "Copied — paste it yourself",
              "manual-paste fallback names what to do")
        check(ToastContent.failure(reason: "", code: "copied_for_manual_paste", cue: true, language: .chinese)?.title
              == "已复制，可以手动粘贴", "Chinese manual-paste copy")
        check(ToastContent.failure(reason: "", code: "copied_for_manual_paste", cue: false) == nil, "uncued fallback stays silent")
        check(ToastContent.shortReason(String(repeating: "a", count: 101)).count == 100, "long reason is bounded")
        check(ToastContent.shortReason(String(repeating: "a", count: 101)).hasSuffix("…"), "truncated reason has ellipsis")
        check(ToastContent.shortReason(String(repeating: "👨‍👩‍👧‍👦", count: 102)).count == 100, "truncate graphemes, not bytes")
        check(ToastContent.shortReason("\n\t").isEmpty, "empty reason stays optional")
        check(ToastContent.shortReason("abc", limit: 0).isEmpty, "zero length is safe")
        check(codex.holdDuration == 1.6 && failure.holdDuration == 2.6, "success and failure dwell times")

        let domain = "local.toss.toast-tests.\(UUID().uuidString)"
        let defaults = InMemoryToastDefaults(suiteName: domain)!
        let preferences = ToastPreferences(defaults: defaults)
        check(ToastPreferences.key == "toastEnabled", "stable preference key")
        check(preferences.enabled, "default on without writing real app preferences")
        preferences.enabled = false
        check(!ToastPreferences(defaults: defaults).enabled, "off persists between instances")
        preferences.enabled = true
        check(ToastPreferences(defaults: defaults).enabled, "on persists between instances")

        // Result order, pinned on the source (the script runs from the project root): the
        // sound plays before any toast or jelly setup, and the toast before the jelly.
        func order(_ file: String, _ markers: [String], from start: String) -> Bool {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8),
                  let origin = text.range(of: start) else { return false }
            var cursor = origin.upperBound
            for marker in markers {
                guard let hit = text.range(of: marker, range: cursor..<text.endIndex) else { return false }
                cursor = hit.upperBound
            }
            return true
        }
        check(order("Sources/TossApp.swift", ["self.successSound { self.cueQueue.async", "self.captureAnimation.confirmed("],
                    from: "self.transaction?.appendConfirmed = true"),
              "success: the sound starts (off the main thread) before the toast and jelly are set up")
        check(order("Sources/TossApp.swift", ["failureSound { cueQueue.async", "captureAnimation.failCurrent("],
                    from: "let text = code == \"append_unconfirmed\""),
              "failure: the sound plays before the toast")
        check(order("Sources/CaptureAnimation.swift", ["showToast(success: true", "startLanding("],
                    from: "func confirmed(requestID"),
              "success: the toast is shown before the jelly window is created")

        // 2026-10-28 (paste where it was pressed): an app switch during the capture brings the original
        // chat back before the first composer focus, which would otherwise fail into the manual fallback.
        do {
            let text = (try? String(contentsOfFile: "Sources/TossApp.swift", encoding: .utf8)) ?? ""
            let start = text.range(of: "code: \"focusing_composer\")")
            let firstFocus = start.flatMap { text.range(of: "chatTarget.focusLease(tx.lease)", range: $0.upperBound..<text.endIndex) }
            let between = (start != nil && firstFocus != nil) ? String(text[start!.upperBound..<firstFocus!.lowerBound]) : ""
            check(between.contains("try await self.refocusIfUserMoved(tx, chatTarget)"),
                  "refocus runs before the first focus of the leased composer")
        }
        check(order("Sources/CaptureAnimation.swift", ["catcher.onTouch = { teardown.touched() }",
                                                       "?.onTouch = { teardown.touched() }", "teardown.finish()"],
                    from: "func detachLanding()"),
              "a detached landing's shields stay wired to its own teardown")

        do {
            let app = (try? String(contentsOfFile: "Sources/TossApp.swift", encoding: .utf8)) ?? ""
            // A changed queued destination is refused before the first composer focus or any paste.
            check(order("Sources/TossApp.swift", ["if self.transaction?.destinationChanged == true { throw TargetFailure.conversationChanged }",
                                                    "try await self.refocusIfUserMoved(tx, chatTarget)",
                                                    "try await chatTarget.focusLease(tx.lease)"],
                        from: "code: \"focusing_composer\")"),
                  "a queued press never focuses or pastes into a chat it was not pressed in")
            // Changed destinations preserve the image for manual paste; queued frames remain saved.
            check(order("Sources/TossApp.swift", [".targetChanged, .conversationChanged"], from: "private static func leavesForManualPaste"),
                  "a changed queued destination ends in the manual-paste notice")
            check(order("Sources/TossApp.swift", ["leaveForManualPaste()", "manualDeliveryPaused = true", "cleanup(cancelProcess: false)"],
                        from: "private func preserveReceivedCapture"),
                  "manual recovery preserves the image before cleanup and pauses later deliveries")
            // Binding at the key event reads memory only: no AX locate in the key handler.
            if let start = app.range(of: "private func bindQueuedPress()"),
               let end = app.range(of: "\n    }\n", range: start.upperBound..<app.endIndex) {
                let body = String(app[start.upperBound..<end.lowerBound])
                check(!body.contains("locate") && !body.contains("AXUIElement") && !body.contains("inspect"),
                      "binding a queued press does no Accessibility read on the key event")
            } else { check(false, "bindQueuedPress present") }
            // Going back to the bound chat happens only on a mismatch, before beginCapture compares again.
            check(order("Sources/TossApp.swift", ["!bound.sameDestination(as: lease)", "QueuedDestinationPolicy.restore(",
                                                    "self.beginCapture(request, kind: kind, config: config, lease: lease)"],
                        from: "let lease = try await self.locateAfterActivation(kind, queued: queued)") ||
                  order("Sources/TossApp.swift", ["!bound.sameDestination(as: lease)", "QueuedDestinationPolicy.restore(",
                                                    "self.beginCapture(request, kind: kind, config: config, lease: lease)"],
                        from: "var lease = try await self.locateAfterActivation(kind, queued: queued)"),
                  "a queued press goes back to its chat only when it changed, then is checked again")
            // 13:29 fixes: readback after Cmd+V reads the same composer in front or not; refocus and
            // the pre-Cmd+V re-check are bounded; the burst ends with the queue.
            for (file, start) in [("Sources/StrictTarget.swift", "func verifyAppend(_ lease: TargetLease"),
                                  ("Sources/ClaudeTarget.swift", "func verifyAppend(_ lease: ClaudeLease")] {
                let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
                if let s = text.range(of: start), let e = text.range(of: "\n    }\n", range: s.upperBound..<text.endIndex) {
                    let body = String(text[s.upperBound..<e.lowerBound])
                    check(!body.contains("requireForeground: true"), "readback does not need the app in front: \(file)")
                    check(body.contains("CFEqual(") && body.contains("lease.composer"), "readback still pins the bound composer: \(file)")
                } else { check(false, "verifyAppend present: \(file)") }
            }
            check(order("Sources/TossApp.swift", ["for attempt in 1...QueuedDestinationPolicy.refocusAttempts",
                                                    "try await chatTarget.focusLease(tx.lease)"],
                        from: "private func refocusIfUserMoved"), "refocus retries are bounded")
            check(order("Sources/TossApp.swift", ["try await self.refocusIfUserMoved(tx, chatTarget)",
                                                    "try chatTarget.revalidateLease(tx.lease, requireFocused: true)",
                                                    "try PasteKeystroke.postOnce(to: tx.lease.pid)",
                                                    "catch TossError.foregroundChanged where foregroundRetries < QueuedDestinationPolicy.foregroundRetriesBeforePaste"],
                        from: "var foregroundRetries = 0"),
                  "every Cmd+V retry re-verifies the focused bound composer first")
            check(order("Sources/TossApp.swift", ["_ = core.reset(keepQueue: true)", "if core.queuedCount == 0 { burstLeases.removeAll() }"],
                        from: "private func cleanup"), "the burst's chats are forgotten when the queue runs empty")
            // Queued presses still raise their app with the v21.1 activation path.
            check(order("Sources/TossApp.swift", ["TargetActivator.bringForward(kind", "self.locateAfterActivation(kind, queued: queued)"],
                        from: "private func startCapture"), "queued presses use the v21.1 activation path")
        }

        // A capture error right after activation is always reported (✕ and cue), never dropped,
        // and a worker busy with an abandoned early request is freed for the next keypress.
        check(order("Sources/TossApp.swift", ["self.activationTask = nil",
                    "do { try self.beginCapture(request, kind: kind, config: config, lease: lease) }",
                    "catch { self.captureSetupFailed(request, error) }"],
                    from: "var lease = try await self.locateAfterActivation(kind, queued: queued)"),
              "activation path: a beginCapture error reaches captureSetupFailed")
        check(order("Sources/TossApp.swift", ["abandonedCaptureID = early.uuid"], from: "private func discardEarlyCapture()")
              && order("Sources/TossApp.swift", ["releaseAbandonedCapture()", "try captureWorker.capture("],
                       from: "private func startEarlyCapture(")
              && order("Sources/TossApp.swift", ["try captureWorker.capture("],
                       from: "startEarlyFocus(request.id, kind: kind, lease: lease)\n        releaseAbandonedCapture()"),
              "an abandoned early request never blocks the next keypress")

        check(ToastContent.failure(reason: "App changed", code: "append_unconfirmed", cue: true,
                                   language: .chinese)?.title == "看看草稿里有没有", "uncertain receipt never claims paste failed")

        // Toss's own cues are present, 48 kHz 24-bit stereo AIFF, and the
        // app and build no longer reference the Codex sound.
        func aiffFormat(_ path: String) -> (channels: Int, bits: Int, rate: Double)? {
            guard let data = FileManager.default.contents(atPath: path), data.count > 12,
                  data.prefix(4) == Data("FORM".utf8), data[8..<12] == Data("AIFF".utf8),
                  let comm = data.range(of: Data("COMM".utf8)) else { return nil }
            let b = [UInt8](data[(comm.upperBound + 4)..<(comm.upperBound + 22)])
            let channels = Int(b[0]) << 8 | Int(b[1]), bits = Int(b[6]) << 8 | Int(b[7])
            let exponent = Int(b[8] & 0x7f) << 8 | Int(b[9])
            var mantissa: UInt64 = 0
            for byte in b[10..<18] { mantissa = mantissa << 8 | UInt64(byte) }
            return (channels, bits, Double(mantissa) * pow(2, Double(exponent - 16383 - 63)))
        }
        for cue in ["Toss-Success", "Toss-Failure"] {
            let format = aiffFormat("Assets/Sounds/\(cue).aiff")
            check(format.map { $0.channels == 2 && $0.bits == 24 && $0.rate == 48000 } == true,
                  "\(cue).aiff is bundled as 48 kHz 24-bit stereo AIFF")
        }
        let app = (try? String(contentsOfFile: "Sources/TossApp.swift", encoding: .utf8)) ?? ""
        let build = (try? String(contentsOfFile: "scripts/build-release.py", encoding: .utf8)) ?? ""
        check(app.contains("sound(\"Toss-Success\")") && app.contains("sound(\"Toss-Failure\")"),
              "the app loads both of Toss's own cues by name")
        check(!app.contains("Codex-Appshot") && !build.contains("Codex-Appshot"),
              "no Codex sound in the app or the bundle")

        // Wire the fake-clock scheduler tests to the adapter's actual call path.
        check(!app.contains("parallelCaptureWorker") && app.contains("private var capturePipeline = CapturePipeline()"),
              "the app uses the serial scheduler and has no Wi-Fi-only second capture lane")
        check(order("Sources/TossApp.swift", ["pumpCaptures()", "startQueuedPress(waited: 1)"], from: "private func admitCapture"),
              "admission starts capture and targeting in the same key callback")
        check(order("Sources/TossApp.swift", ["capturePipeline.takeForTargeting()", "core.beginDelivery"], from: "private func startQueuedPress"),
              "targeting reserves an in-flight capture instead of waiting for a ready receipt")
        check(app.contains("startingQueuedPress = press.queued") &&
              app.contains("CapturePipeline.bindingMissing(queued: press.queued"),
              "a single key retains the ordinary activation and automatic-paste path")
        check(app.contains(".now() + CaptureProgressPolicy.noticeDelay"), "pipeline and worker use the same two-second notice threshold")
        check(order("Sources/TossApp.swift", ["CaptureReceipt.validate(", "clipboard.publish(file: early.image)", "manualDeliveryPaused = true"],
                    from: "private func finishTargetlessCapture"), "failed early target lookup preserves a validated arrived image for manual paste")

        check(TransferNotice.text(received: 6, expected: 10, queued: 2, language: .chinese) == "图片正在传过来… 60%\n还有 2 张", "progress and queue count")
        check(TransferNotice.text(received: 9, expected: 10, queued: 0, language: .english) == "Image on its way… 90%", "progress updates")
        check(TransferNotice.text(received: 6, expected: 0, queued: 0, language: .chinese) == "图片正在传过来…", "unknown size has no guessed percentage")
        check(TransferNotice.text(received: 11, expected: 10, queued: 0, language: .english) == "Image on its way… 100%", "percentage bounded")

        print("Toast: \(checks) checks passed (no windows or devices).")
    }
}
