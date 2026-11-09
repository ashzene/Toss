import Foundation
import Darwin

// Real Python subprocess IPC with synthetic JSON only. This binary links solely
// CaptureWorker.swift: no TossApp, AX, key monitoring, clipboard or device code.
@main
@MainActor
struct CaptureWorkerTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Response {
        let data: Data
        let exit: Int32
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
    }
    final class Box { var responses: [Response] = [] }
    static var passed = 0

    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw Failure(description: "Supply absolute Python and synthetic fixture paths")
        }
        setbuf(stdout, nil)
        let python = CommandLine.arguments[1], fixture = CommandLine.arguments[2]
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipad-worker-ipc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        if ProcessInfo.processInfo.environment["TOSS_FLOW_REGRESSION"] != nil {
            try await flowingAndConcurrentTests(python: python, fixture: fixture, root: root)
            print("CaptureWorker flow regression: \(passed) assertions passed.")
            return
        }

        if ProcessInfo.processInfo.environment["TOSS_ADAPTIVE_REGRESSION_CASE"] != nil {
            try await adaptiveThresholdTests(python: python, fixture: fixture, root: root)
            print("CaptureWorker adaptive regression: \(passed) assertions passed.")
            return
        }

        if ProcessInfo.processInfo.environment["TOSS_USB_REGRESSION_CASE"] != nil {
            try await usbRegressionTests(python: python, fixture: fixture, root: root)
            print("CaptureWorker USB regression: \(passed) assertions passed.")
            return
        }

        func context(_ name: String, _ mode: String) throws -> (URL, CaptureWorker.Configuration) {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try mode.write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            return (folder, .init(python: python, script: fixture,
                                 stateDirectory: folder.path, outputDirectory: folder.path))
        }

        // A fake monotonic clock covers the exact notice boundary without sleeps.
        for elapsed in [0.0, 1.0, 1.99] {
            try expect(!CaptureProgressPolicy.shouldShow(startedAt: 100, now: 100 + elapsed, finished: false), "normal capture must not show progress before 2 seconds")
        }
        try expect(CaptureProgressPolicy.shouldShow(startedAt: 100, now: 102, finished: false), "waiting at 2 seconds shows progress")
        try expect(!CaptureProgressPolicy.shouldShow(startedAt: 100, now: 103, finished: true), "finished capture never reopens a slow notice")

        do {
            let (folder, config) = try context("prepare-reuse", "normal")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) {
                audit(folder).contains { $0["event"] as? String == "started" }
            }
            let initial = audit(folder).first { $0["event"] as? String == "started" } ?? [:]
            let preparedPID = initial["worker_pid"] as? Int
            try expect(preparedPID != nil, "prepared worker did not start")
            try expect(initial["preconnect"] as? Bool == true, "prepare omitted --preconnect")
            try expect(initial["idle_seconds"] as? String == "1800", "prepared worker idle timeout was not 1800")
            try expect(initial["timings_file"] as? String == FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Toss/screenshot-success-times.json").path,
                "timing history moved alongside a legacy state directory")
            try expect(!worker.isBusy, "prepare incorrectly created pending capture")
            try worker.prepare(configuration: config)
            try worker.prepare(configuration: config)
            try await Task.sleep(nanoseconds: 75_000_000)
            try expect(audit(folder).filter { $0["event"] as? String == "started" }.count == 1,
                       "repeated prepare restarted same configuration")
            try expect(audit(folder).filter { $0["event"] as? String == "request" }.isEmpty,
                       "prepare sent a capture request")
            let first = Box()
            try request(worker, config, folder, first)
            let captured = try await response(first, within: 1.5)
            try expect(captured.exit == 0 && captured.json["worker_pid"] as? Int == preparedPID,
                       "first capture failed to reuse prepared worker")
            try expect(captured.json["sequence"] as? Int == 1, "prepare consumed a capture sequence")
            let routes = captured.json["route_attempts"] as? [[String: Any]]
            try expect(routes?.count == 1 && routes?.first?["worker_role"] as? String == "wifi_primary" && routes?.first?["reason"] as? String == "ok", "direct Wi-Fi success must record route_attempts")
            print("PASS prepare sends no capture; direct Wi-Fi route logged; repeated prepare and first capture reuse one child")
        }
        do {
            let (folder, config) = try context("prepare-stop", "normal")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) {
                audit(folder).contains { $0["event"] as? String == "started" }
            }
            let oldPID = audit(folder).first?["worker_pid"] as? Int
            try expect(oldPID != nil, "prepared worker PID unavailable")
            worker.stop()
            let box = Box()
            try request(worker, config, folder, box)
            let result = try await response(box, within: 1.5)
            try expect(result.exit == 0 && result.json["worker_pid"] as? Int != oldPID,
                       "capture after stop reused prepared generation")
            let launches = audit(folder).filter { $0["event"] as? String == "started" }
            try expect(launches.count == 2, "capture after prepare-stop did not create exactly one new child")
            try expect(launches.last?["preconnect"] as? Bool == false,
                       "ordinary cold capture incorrectly used --preconnect")
            try expect(launches.last?["idle_seconds"] as? String == "1800", "cold worker idle timeout was not 1800")
            print("PASS stopping prepared worker makes next capture start a new cold child")
        }
        do {
            let (folder, config) = try context("prepare-busy", "delay")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: config)
            let box = Box()
            try request(worker, config, folder, box)
            do {
                try worker.prepare(configuration: config)
                throw Failure(description: "prepare interrupted an active capture")
            } catch CaptureWorkerError.busy { passed += 1 }
            let result = try await response(box, within: 1.5)
            try expect(result.exit == 0 && box.responses.count == 1,
                       "busy prepare disrupted original capture")
            try expect(audit(folder).filter { $0["event"] as? String == "started" }.count == 1,
                       "busy prepare launched another child")
            try expect(audit(folder).filter { $0["event"] as? String == "request" }.count == 1,
                       "busy prepare queued another capture")
            print("PASS prepare while busy rejects without interrupting capture")
        }
        do {
            let (oldFolder, oldConfig) = try context("prepare-config-old", "normal")
            let (newFolder, newConfig) = try context("prepare-config-new", "normal")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: oldConfig)
            try await waitUntil(within: 1.5) {
                audit(oldFolder).contains { $0["event"] as? String == "started" }
            }
            let oldPID = audit(oldFolder).first?["worker_pid"] as? Int
            try worker.prepare(configuration: newConfig)
            try await waitUntil(within: 1.5) {
                audit(newFolder).contains { $0["event"] as? String == "started" }
            }
            let launch = audit(newFolder).first ?? [:]
            try expect(launch["worker_pid"] as? Int != oldPID && launch["preconnect"] as? Bool == true,
                       "configuration change did not launch a new prepared generation")
            let box = Box()
            try request(worker, newConfig, newFolder, box)
            let result = try await response(box, within: 1.5)
            try expect(result.exit == 0 && result.json["worker_pid"] as? Int == launch["worker_pid"] as? Int,
                       "changed configuration did not remain usable")
            try expect(audit(oldFolder).filter { $0["event"] as? String == "request" }.isEmpty,
                       "new capture was sent to previous configuration")
            print("PASS prepare configuration change replaces child and routes capture correctly")
        }
        for recoverWithPrepare in [false, true] {
            let name = recoverWithPrepare ? "prepare-exit-reprepare" : "prepare-exit-capture"
            let (folder, config) = try context(name, "prepare-exit")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) {
                audit(folder).contains { $0["event"] as? String == "preconnect_exiting" }
            }
            let oldPID = audit(folder).first?["worker_pid"] as? Int
            try await Task.sleep(nanoseconds: 100_000_000)
            try expect(!worker.isBusy, "abnormal preconnect exit left capture pending")
            if recoverWithPrepare {
                try "normal".write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
                try worker.prepare(configuration: config)
            }
            let box = Box()
            try request(worker, config, folder, box)
            let result = try await response(box, within: 1.5)
            try expect(result.exit == 0 && result.json["worker_pid"] as? Int != oldPID,
                       "abnormally closed prepared worker failed to recover")
            let launches = audit(folder).filter { $0["event"] as? String == "started" }
            try expect(launches.count == 2, "abnormal preconnect recovery spawned wrong number of children")
            try expect(launches.last?["preconnect"] as? Bool == recoverWithPrepare,
                       "recovery used incorrect preconnect launch mode")
            print("PASS abnormal preconnect exit recovers via \(recoverWithPrepare ? "prepare" : "cold capture")")
        }

        // The child stays alive with its output pipe open; completion must not
        // wait for EOF. A second request must reuse that exact PID.
        do {
            let (folder, config) = try context("reuse", "normal")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            let first = Box()
            let started = ProcessInfo.processInfo.systemUptime
            try request(worker, config, folder, first)
            let response1 = try await response(first, within: 1.5)
            try expect(response1.exit == 0, "first JSONL request failed")
            try expect(ProcessInfo.processInfo.systemUptime - started < 1.5,
                       "JSONL completion waited for pipe EOF")
            let second = Box()
            try request(worker, config, folder, second)
            let response2 = try await response(second, within: 1.5)
            try expect(response2.exit == 0, "second JSONL request failed")
            try expect(response1.json["worker_pid"] as? Int == response2.json["worker_pid"] as? Int,
                       "successful requests did not reuse process")
            try expect(response2.json["sequence"] as? Int == 2, "second request not received exactly once")
            print("PASS immediate line without EOF; two requests reuse one child")
        }
        do {
            let (folder, config) = try context("busy", "delay")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            let first = Box(), second = Box()
            try request(worker, config, folder, first)
            do {
                try request(worker, config, folder, second)
                throw Failure(description: "busy capture was accepted")
            } catch CaptureWorkerError.busy { passed += 1 }
            let result = try await response(first, within: 1.5)
            try expect(result.exit == 0, "original busy request failed")
            try await Task.sleep(nanoseconds: 100_000_000)
            try expect(second.responses.isEmpty, "busy request was queued")
            try expect(audit(folder).filter { $0["event"] as? String == "request" }.count == 1,
                       "child received queued busy request")
            print("PASS busy request rejected without queue")
        }
        do {
            let (folder, config) = try context("connection-events", "connection-events")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            var states: [TossConnectionStatus.State] = []
            worker.onConnectionChange = { states.append($0.state) }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.state == .ready }
            try expect(!worker.isBusy, "idle ready event created a capture")
            try expect(audit(folder).filter { $0["event"] as? String == "request" }.isEmpty,
                       "connection observation took a screenshot")
            let box = Box()
            try request(worker, config, folder, box)
            let result = try await response(box, within: 1.5)
            try expect(result.exit == 0 && box.responses.count == 1,
                       "connection events consumed or duplicated a capture receipt")
            try expect(states.contains(.disconnected) && worker.connectionStatus.state == .ready,
                       "disconnected/reconnected state was not delivered during capture")
            worker.stop()
            try expect(worker.connectionStatus == .notChecked, "stopped worker still claims connected")
            print("PASS idle/in-flight connection events never complete or request a screenshot")
        }
        for mode in ["wrong-id", "oversize", "no-newline-oversize", "malformed", "malformed-event", "eof"] {
            let (folder, config) = try context(mode, mode)
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            let box = Box()
            try request(worker, config, folder, box)
            let result = try await response(box, within: 1.5)
            try expect(result.exit != 0 && result.json["ok"] as? Bool == false,
                       "invalid IPC \(mode) was accepted")
            try expect(!worker.isBusy, "invalid IPC \(mode) left worker busy")
            try await Task.sleep(nanoseconds: 75_000_000)
            try expect(box.responses.count == 1, "invalid IPC \(mode) completed more than once")
            print("PASS invalid IPC rejected: \(mode)")
        }
        do {
            let (folder, config) = try context("failed-receipt", "failure")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            let failed = Box()
            try request(worker, config, folder, failed)
            let first = try await response(failed, within: 1.5)
            try expect(first.exit == 1 && first.json["ok"] as? Bool == false, "failure receipt accepted")
            let oldPID = first.json["worker_pid"] as? Int
            try expect(oldPID != nil, "fake failure PID missing")
            try "normal".write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let next = Box()
            try request(worker, config, folder, next)
            let second = try await response(next, within: 1.5)
            try expect(second.exit == 0 && second.json["worker_pid"] as? Int != oldPID,
                       "failed receipt's process was reused")
            print("PASS failure receipt discards whole worker")
        }
        do {
            // 2026-10-25: a black frame is a complete reply rejected on content; the link is
            // healthy, so the same worker process serves the next keypress.
            let (folder, config) = try context("black-receipt", "black")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            let failed = Box()
            try request(worker, config, folder, failed)
            let first = try await response(failed, within: 1.5)
            try expect(first.exit == 1 && first.json["reason"] as? String == "black_frame_rejected", "black frame reported")
            let oldPID = first.json["worker_pid"] as? Int
            try expect(worker.connectionStatus.state != .failed, "black frame marked the link failed")
            try "normal".write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let next = Box()
            try request(worker, config, folder, next)
            let second = try await response(next, within: 1.5)
            try expect(second.exit == 0 && oldPID != nil && second.json["worker_pid"] as? Int == oldPID,
                       "black frame discarded a healthy worker")
            print("PASS black frame keeps the healthy worker")
        }
        do {
            // A timeout reply: the backend closed its session and keeps reconnecting; the same
            // process (with that reconnect) serves the next keypress.
            let (folder, config) = try context("timeout-receipt", "timeout-reply")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            let failed = Box()
            try request(worker, config, folder, failed)
            let first = try await response(failed, within: 1.5)
            try expect(first.exit == 1 && first.json["reason"] as? String == "timeout", "timeout reported")
            try expect(worker.connectionStatus.state == .failed, "timeout still shows the link as failed until it reconnects")
            try "normal".write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let next = Box()
            try request(worker, config, folder, next)
            let second = try await response(next, within: 1.5)
            try expect(second.exit == 0 && second.json["worker_pid"] as? Int == first.json["worker_pid"] as? Int,
                       "timeout reply discarded the reconnecting worker")
            print("PASS timeout reply keeps the reconnecting worker")
        }
        do {
            let domain = "local.toss.limits-tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removeVolatileDomain(forName: UserDefaults.registrationDomain) }
            try expect(CaptureWorker.progressLimits(defaults) == ["first_byte": 800, "stall": 2500, "press_cap": 30000],
                       "default progress limits")
            try expect(CaptureWorker.attemptLimits(["stall": 2500, "press_cap": 8000], role: .usbPrimary) == ["stall": 1200, "press_cap": 8000],
                       "USB keeps the short stall limit")
            try expect(CaptureWorker.attemptLimits(["stall": 2500], role: .wifiPrimary) == ["stall": 2500],
                       "Wi-Fi keeps the longer stall limit")
            var drop = USBDropNotice()
            try expect(!drop.shouldShow(externalConnected: false, usbBack: false, at: 1), "really unplugged: no notice")
            try expect(!drop.shouldShow(externalConnected: nil, usbBack: false, at: 1), "unknown power: no notice")
            try expect(!drop.shouldShow(externalConnected: true, usbBack: true, at: 1), "USB came back: no notice")
            try expect(drop.shouldShow(externalConnected: true, usbBack: false, at: 1), "still powered: notice")
            try expect(!drop.shouldShow(externalConnected: true, usbBack: false, at: 500), "quiet for ten minutes")
            try expect(drop.shouldShow(externalConnected: true, usbBack: false, at: 601), "notice again after ten minutes")
            defaults.register(defaults: ["firstByteLimitMs": 50.0, "pressCapMs": 31000.0])
            let clamped = CaptureWorker.progressLimits(defaults)
            try expect(clamped["first_byte"] == 200 && clamped["press_cap"] == 30000 && clamped["stall"] == 2500,
                       "limits are clamped to what the backend accepts")
            try expect(CaptureWorker.reconnectingFailures == ["timeout", "first_byte_timeout", "stall_timeout", "too_slow", "disconnected", "slow_threshold"],
                       "progress failures keep the reconnecting worker like a timeout")
            print("PASS progress limits")
        }
        do {
            let (folder, config) = try context("closed-stdin", "close-stdin")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            let first = Box()
            try request(worker, config, folder, first)
            let initial = try await response(first, within: 1.5)
            try expect(initial.exit == 0, "initial reply before stdin closure failed")
            try await waitUntil(within: 1.5) {
                audit(folder).contains { $0["event"] as? String == "stdin_closed" }
            }
            let second = Box()
            do {
                try request(worker, config, folder, second)
                throw Failure(description: "write to closed child stdin was accepted")
            } catch CaptureWorkerError.unavailable { passed += 1 }
            try expect(second.responses.isEmpty && !worker.isBusy,
                       "closed-pipe write left pending completion or busy state")
            print("PASS child closes stdin while alive; host survives broken-pipe write")
        }
        do {
            let (folder, config) = try context("generation", "late")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            let old = Box()
            try request(worker, config, folder, old)
            try await waitUntil(within: 1.5) {
                audit(folder).contains { $0["event"] as? String == "request" }
            }
            worker.stop()
            try "normal".write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let current = Box()
            try request(worker, config, folder, current)
            let result = try await response(current, within: 1.5)
            try expect(result.exit == 0, "new generation request failed")
            try await Task.sleep(nanoseconds: 450_000_000)
            try expect(old.responses.isEmpty, "stopped generation called old completion")
            try expect(current.responses.count == 1, "old generation polluted new completion")
            try expect(!worker.isBusy, "stale generation changed new busy state")
            print("PASS stop/late child callbacks cannot pollute new generation")
        }
        do {
            let (folder, config) = try context("timeout", "timeout")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            let box = Box()
            let start = ProcessInfo.processInfo.systemUptime
            try request(worker, config, folder, box, timeout: 4)
            let result = try await response(box, within: 5.5)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            try expect(result.exit == 1 && result.json["reason"] as? String == "timeout",
                       "minimum timeout did not produce timeout receipt")
            try expect(elapsed >= 3.9 && elapsed < 5.5, "4-second IPC timeout outside expected bounds")
            try expect(!worker.isBusy, "timeout did not release busy state")
            try expect((result.json["route_attempts"] as? [[String: Any]])?.first?["reason"] as? String == "timeout", "direct Wi-Fi timeout must record route_attempts too")
            print("PASS four-second minimum timeout")
        }

        do {
            let (folder, config) = try context("usb-lifecycle", "usb-success")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.state == .ready }
            try await Task.sleep(nanoseconds: 60_000_000)
            try expect(audit(folder).filter { $0["event"] as? String == "started" }.count == 1,
                       "no cable must have exactly one process")
            try expect(worker.connectionStatus.transport == "wifi", "uncabled connection should say Wi-Fi")
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            try await waitUntil(within: 1.5) { worker.connectionStatus.transport == "usb" }
            let usbPID = audit(folder).first { $0["event"] as? String == "started" && $0["transport"] as? String == "usb" }?["worker_pid"] as? Int
            worker.invalidateWiFi()
            try expect(worker.connectionStatus.state == .ready && worker.connectionStatus.transport == "usb",
                       "network changes must preserve USB health")
            let box = Box(); try request(worker, config, folder, box)
            let result = try await response(box, within: 1.5)
            try expect(result.exit == 0 && result.json["transport"] as? String == "authenticated_usb", "wired capture route")
            try expect(result.json["worker_pid"] as? Int == usbPID, "network change restarted USB")
            let id = result.json["request_id"] as! String
            try expect(try String(contentsOf: folder.appendingPathComponent(id + ".png"), encoding: .utf8) == "usb",
                       "USB attempt was not promoted to canonical path")
            try expect((result.json["route_attempts"] as? [[String: Any]])?.count == 1, "USB success duplicated attempt")
            try FileManager.default.removeItem(at: folder.appendingPathComponent("usb-present"))
            try await waitUntil(within: 1.5) { worker.connectionStatus.transport == "wifi" }
            let next = Box(); try request(worker, config, folder, next)
            try expect(try await response(next, within: 1.5).json["transport"] as? String == "authenticated_wifi",
                       "unplug did not return to Wi-Fi")
            try expect(audit(folder).filter { $0["event"] as? String == "started" && $0["transport"] as? String == "usb" }.count == 1,
                       "presence replay launched duplicate USB processes")
            print("PASS USB lazy start, preferred route, Wi-Fi-only invalidation and unplug")
        }
        do {
            let (folder, config) = try context("usb-reconnecting", "usb-reconnecting")
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { audit(folder).contains { $0["event"] as? String == "started" && $0["transport"] as? String == "usb" } }
            try await Task.sleep(nanoseconds: 50_000_000)
            // USB is present but the synthetic session has never reported ready.
            for _ in 0..<3 {
                let box = Box(); try request(worker, config, folder, box)
                let result = try await response(box, within: 1.5)
                try expect(result.json["transport"] as? String == "authenticated_usb", "each queued press must prefer a present USB even while reconnecting")
                try expect((result.json["route_attempts"] as? [[String: Any]])?.first?["worker_role"] as? String == "usb_primary", "each serial USB result logs its actual route")
            }
            try expect(audit(folder).filter { $0["event"] as? String == "request" && $0["transport"] as? String == "wifi" }.isEmpty, "a reconnecting USB session was silently bypassed by Wi-Fi")
            print("PASS three serial requests retain USB preference during reconnect")
        }
        do {
            let (folder, config) = try context("usb-draining-queue", "usb-held-after-fallback")
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.isHealthyUSB }
            let first = Box(); try request(worker, config, folder, first)
            _ = try await response(first, within: 1.5) // Wi-Fi already won; USB still draining.
            try "usb-success".write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let second = Box(); try request(worker, config, folder, second)
            try await Task.sleep(nanoseconds: 60_000_000)
            try expect(audit(folder).filter { $0["event"] as? String == "request" }.count == 2,
                       "second press must wait for the old USB owner, without another Wi-Fi request")
            try Data().write(to: folder.appendingPathComponent("release-usb"))
            let result = try await response(second, within: 1.5)
            try expect(result.json["transport"] as? String == "authenticated_usb", "queued press failed to return to USB after cleanup")
            let requests = audit(folder).filter { $0["event"] as? String == "request" }
            try expect(requests.count == 3 && requests[0]["worker_pid"] as? Int == requests[2]["worker_pid"] as? Int,
                       "USB cleanup queue spawned a competing session")
            print("PASS next press waits for draining USB, then reuses USB without a second upload")
        }
        // The cable arrives while a press waits on a stuck Wi-Fi attempt: it moves to USB at once, exactly once.
        do {
            let (folder, config) = try context("usb-arrives", "usb-arrives")
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.state == .ready }
            let box = Box()
            try request(worker, config, folder, box)
            try await waitUntil(within: 1.0) {
                audit(folder).contains { $0["event"] as? String == "request" && $0["transport"] as? String == "wifi" }
            }
            let plugged = ProcessInfo.processInfo.systemUptime
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            let result = try await response(box, within: 2.0)
            try expect(result.exit == 0 && result.json["transport"] as? String == "authenticated_usb", "press did not move to the new cable")
            try expect(ProcessInfo.processInfo.systemUptime - plugged < 1.5, "press waited after the cable arrived")
            let id = result.json["request_id"] as! String
            try expect(try String(contentsOf: folder.appendingPathComponent(id + ".png"), encoding: .utf8) == "usb", "wrong route published")
            try await Task.sleep(nanoseconds: 400_000_000)
            try expect(box.responses.count == 1, "moved press completed twice")
            let routes = (result.json["route_attempts"] as? [[String: Any]])?.compactMap { $0["transport"] as? String }
            try expect(routes == ["usb"], "the moved press must record its USB attempt")
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".capture-attempt-") }.isEmpty,
                       "abandoned attempt file was retained")
            print("PASS usb-arrives: a waiting Wi-Fi press moved to the new cable, exactly once")
        }
        for mode in ["usb-progress-late", "usb-stall-late", "usb-tooslow-late", "usb-failure", "usb-unplug", "usb-wrong-attempt"] {
            let (folder, config) = try context(mode, mode)
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.transport == "usb" }
            let box = Box(), start = ProcessInfo.processInfo.systemUptime
            try request(worker, config, folder, box)
            if mode.contains("late") {
                try await waitUntil(within: 1.0) {
                    audit(folder).contains { $0["event"] as? String == "request" && $0["transport"] as? String == "wifi" }
                }
                try expect(worker.connectionStatus.transport == "wifi", "fallback status must show actual active route")
            }
            let result = try await response(box, within: 1.5)
            try expect(result.exit == 0 && result.json["transport"] as? String == "authenticated_wifi", "USB failure did not fallback once: \(mode)")
            if mode.contains("late") {
                try expect(ProcessInfo.processInfo.systemUptime - start < 0.35, "fallback waited for USB cleanup")
            }
            let id = result.json["request_id"] as! String
            let output = folder.appendingPathComponent(id + ".png")
            try expect(try String(contentsOf: output, encoding: .utf8) == "wifi", "wrong attempt published")
            try await Task.sleep(nanoseconds: 550_000_000)
            try expect(box.responses.count == 1, "late USB result completed keypress twice")
            try expect(try String(contentsOf: output, encoding: .utf8) == "wifi", "late USB overwrote pasted image")
            let requests = audit(folder).filter { $0["event"] as? String == "request" }
            try expect(requests.count == 2, "must send exactly one USB and one Wi-Fi request")
            try expect(requests[0]["request_id"] as? String == requests[1]["request_id"] as? String,
                       "fallback lost transaction identity")
            try expect(requests[0]["attempt_id"] as? String != requests[1]["attempt_id"] as? String,
                       "fallback reused attempt identity")
            try expect(requests[0]["deadline"] as? Double == requests[1]["deadline"] as? Double,
                       "fallback reset press deadline")
            try expect((result.json["route_attempts"] as? [[String: Any]])?.count == 2, "missing route timings")
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".capture-attempt-") }.isEmpty,
                       "late/abandoned attempt file was retained")
            print("PASS \(mode): immediate fallback, shared budget, exactly once and stale cleanup")
        }
        do {
            // This case pins a 2 s press cap (the default is now 4.5 s); the test binary's own domain.
            let (folder, config) = try context("usb-budget", "usb-budget")
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            let worker = CaptureWorker(wifiHedgingEnabled: false,
                progressLimits: ["first_byte": 800, "stall": 1200, "press_cap": 2000]); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.transport == "usb" }
            let box = Box(), start = ProcessInfo.processInfo.systemUptime
            try request(worker, config, folder, box)
            let result = try await response(box, within: 2.3)
            try expect(result.exit == 1 && result.json["reason"] as? String == "timeout", "shared cap accepted late fallback")
            try expect(ProcessInfo.processInfo.systemUptime - start < 2.2, "USB + Wi-Fi exceeded shared 2s cap")
            try await Task.sleep(nanoseconds: 500_000_000)
            try expect(box.responses.count == 1 && !worker.isBusy, "late Wi-Fi completed expired transaction")
            let id = result.json["request_id"] as! String
            try expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(id + ".png").path), "expired attempt was promoted")
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".capture-attempt-") }.isEmpty,
                       "expired attempt file leaked")
            print("PASS shared 2s cap rejects late Wi-Fi and cleans both attempts")
        }
        do {
            let (folder, config) = try context("usb-version", "usb-version")
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.reason == "unexpected_library_version" }
            try await Task.sleep(nanoseconds: 100_000_000)
            try expect(worker.connectionStatus.reason == "unexpected_library_version", "EOF hid explicit version failure")
            let box = Box(); try request(worker, config, folder, box)
            let result = try await response(box, within: 1.5)
            // Claude review 2026-10-25: a USB problem is shown in the status line but never blocks
            // tossing; the press uses the Wi-Fi worker, and the USB runtime is never used.
            try expect(result.exit == 0 && result.json["transport"] as? String == "authenticated_wifi",
                       "version mismatch must not block the Wi-Fi route")
            try expect(audit(folder).filter { $0["event"] as? String == "request" && $0["transport"] as? String == "usb" }.isEmpty,
                       "the mismatched USB runtime was used")
            try expect(worker.connectionStatus.reason == "unexpected_library_version", "the USB problem stays visible")
            print("PASS pinned USB runtime mismatch is explicit and tossing continues over Wi-Fi")
        }
        do {
            let (folder, config) = try context("usb-cancel", "usb-late-stop")
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.transport == "usb" }
            let box = Box(); try request(worker, config, folder, box)
            try await waitUntil(within: 1.5) { audit(folder).contains { $0["event"] as? String == "request" } }
            worker.stop()
            try await Task.sleep(nanoseconds: 1_350_000_000)
            try expect(box.responses.isEmpty, "cancelled USB capture called completion")
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }.isEmpty,
                       "cancel-ignoring USB child leaked image")
            print("PASS USB cancellation discards late child and image")
        }
        // Weak-link simulation is IPC only. A fake child emits observed progress and stalls;
        // no socket, system network setting, device, screenshot prefetch or app is involved.
        for mode in ["wifi-healthy", "wifi-too-slow", "wifi-unknown", "wifi-stall", "wifi-first-byte",
                     "wifi-primary-wins", "wifi-both-fail", "wifi-black", "wifi-bad-progress"] {
            let (folder, config) = try context(mode, mode)
            let worker = CaptureWorker(wifiHedgingEnabled: true); defer { worker.stop() }
            var slowIDs: [String] = []
            worker.onCaptureSlow = { slowIDs.append($0) }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) {
                audit(folder).filter { $0["event"] as? String == "started" }.count == 2 &&
                    audit(folder).filter { $0["event"] as? String == "ready" }.count == 2
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(audit(folder).filter { $0["event"] as? String == "request" }.isEmpty,
                       "standby preparation requested a screenshot")
            let starts = audit(folder).filter { $0["event"] as? String == "started" }
            try expect(Set(starts.compactMap { $0["worker_pid"] as? Int }).count == 2,
                       "two Wi-Fi roles did not use independent processes")
            let box = Box()
            let started = ProcessInfo.processInfo.systemUptime
            try request(worker, config, folder, box)
            let result = try await response(box, within: 2.3)
            let requests = audit(folder).filter { $0["event"] as? String == "request" }
            let hedged = ["wifi-stall", "wifi-first-byte", "wifi-primary-wins", "wifi-both-fail"].contains(mode)
            try expect(requests.count == (hedged ? 2 : 1), "wrong number of screenshot RPCs: \(mode)")
            if hedged {
                try expect(requests[0]["request_id"] as? String == requests[1]["request_id"] as? String &&
                           requests[0]["attempt_id"] as? String != requests[1]["attempt_id"] as? String,
                           "hedge lost transaction/attempt identity")
                try expect(requests[0]["deadline"] as? Double == requests[1]["deadline"] as? Double,
                           "hedge reset shared deadline")
            }
            let failure = ["wifi-both-fail", "wifi-black", "wifi-bad-progress"].contains(mode)
            try expect(result.exit == (failure ? 1 : 0), "wrong simulated result: \(mode)")
            if mode == "wifi-stall" || mode == "wifi-first-byte" {
                try expect(result.json["worker_role"] as? String == "wifi_standby", "standby did not win stalled primary")
                try expect(ProcessInfo.processInfo.systemUptime - started < 1.5, "hedge waited for stalled primary")
            }
            if mode == "wifi-primary-wins" {
                try expect(result.json["worker_role"] as? String == "wifi_primary", "healthy primary lost ownership")
            }
            let id = result.json["request_id"] as! String
            if ["wifi-healthy", "wifi-too-slow", "wifi-unknown"].contains(mode) {
                try expect(slowIDs.isEmpty, "1-second captures must stay quiet until the 2-second notice threshold")
            }
            if mode == "wifi-black" {
                try expect(result.json["reason"] as? String == "black_frame_rejected", "black frame lost its reason")
                let oldPID = result.json["worker_pid"] as? Int
                try "wifi-normal".write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
                let next = Box(); try request(worker, config, folder, next)
                try expect(try await response(next, within: 1.5).json["worker_pid"] as? Int == oldPID,
                           "content rejection killed the healthy worker in hedged mode")
            }
            if mode == "wifi-bad-progress" {
                try expect(result.json["reason"] as? String == "capture_integrity_failed", "malformed progress accepted")
            }
            try await Task.sleep(nanoseconds: 1_350_000_000)
            try expect(box.responses.count == 1 && !worker.isBusy, "late loser completed twice or left transaction busy")
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
                $0.hasPrefix(".capture-attempt-") }.isEmpty, "hedge temporary image leaked")
            if !failure {
                let contents = try String(contentsOf: folder.appendingPathComponent(id + ".png"), encoding: .utf8)
                try expect(contents == result.json["worker_role"] as? String, "late loser overwrote winner")
            }
            print("PASS \(mode): progress-based hedge, shared budget, one completion and image cleanup")
        }
        do {
            let (folder, config) = try context("wifi-no-progress-cap", "wifi-no-progress")
            let worker = CaptureWorker(wifiHedgingEnabled: true,
                progressLimits: ["first_byte": 800, "stall": 1200, "press_cap": 1600])
            defer { worker.stop() }
            var slow = 0; worker.onCaptureSlow = { _ in slow += 1 }
            try worker.prepare(configuration: config)
            // The fixture appends its audit immediately after writing to the pipe;
            // allow the native reader to consume both ready events before choosing a role.
            try await Task.sleep(nanoseconds: 50_000_000)
            let box = Box(), start = ProcessInfo.processInfo.systemUptime
            try request(worker, config, folder, box, timeout: 40)
            let result = try await response(box, within: 2.1)
            try expect(result.json["reason"] as? String == "timeout" && slow == 0,
                       "silent worker missed advisory or outer cap")
            try expect(ProcessInfo.processInfo.systemUptime - start < 2.0, "Wi-Fi outer watchdog used 40s timeout")
            try expect(audit(folder).filter { $0["event"] as? String == "request" }.count == 1,
                       "a wall-clock timer launched hedge without progress evidence")
            print("PASS silent Wi-Fi worker: sub-2s cap stays quiet, no timer-only hedge")
        }
        do {
            let (folder, config) = try context("wifi-invalidate", "wifi-stall")
            let worker = CaptureWorker(wifiHedgingEnabled: true); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { audit(folder).filter { $0["event"] as? String == "ready" }.count == 2 }
            let oldPIDs = Set(audit(folder).filter { $0["event"] as? String == "started" }.compactMap { $0["worker_pid"] as? Int })
            worker.invalidateWiFi()
            try await waitUntil(within: 1.5) { audit(folder).filter { $0["event"] as? String == "started" }.count == 4 }
            let newPIDs = Set(audit(folder).filter { $0["event"] as? String == "started" }.compactMap { $0["worker_pid"] as? Int })
            try expect(newPIDs.subtracting(oldPIDs).count == 2, "network invalidation retained a stale Wi-Fi role")
            print("PASS network invalidation replaces both independent Wi-Fi workers")
        }
        do {
            let (folder, config) = try context("wifi-stale-slow", "wifi-normal")
            let worker = CaptureWorker(wifiHedgingEnabled: true); defer { worker.stop() }
            var slowIDs: [String] = []
            worker.onCaptureSlow = { slowIDs.append($0) }
            let first = Box(); try request(worker, config, folder, first)
            let fast = try await response(first, within: 1.5)
            try await Task.sleep(nanoseconds: 300_000_000)
            try "wifi-notice".write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let second = Box(); try request(worker, config, folder, second)
            let slow = try await response(second, within: 3)
            try expect(slowIDs == [slow.json["request_id"] as! String] &&
                       slowIDs.first != fast.json["request_id"] as? String,
                       "finished request's slow timer contaminated the next transaction")
            print("PASS completed request's slow timer cannot notify a later request")
        }
        do {
            let (folder, config) = try context("wifi-stop-hedge", "wifi-primary-wins")
            let worker = CaptureWorker(wifiHedgingEnabled: true); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { audit(folder).filter { $0["event"] as? String == "ready" }.count == 2 }
            let box = Box(); try request(worker, config, folder, box)
            try await waitUntil(within: 1.5) { audit(folder).filter { $0["event"] as? String == "request" }.count == 2 }
            worker.stop()
            try await Task.sleep(nanoseconds: 1_350_000_000)
            try expect(box.responses.isEmpty && !worker.isBusy, "cancelled hedge produced a completion")
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
                $0.hasSuffix(".png") }.isEmpty, "cancel-ignoring Wi-Fi loser retained an image")
            print("PASS stopping two in-flight Wi-Fi attempts suppresses both results and cleans images")
        }
        try await flowingAndConcurrentTests(python: python, fixture: fixture, root: root)
        try await adaptiveThresholdTests(python: python, fixture: fixture, root: root)
        try await usbRegressionTests(python: python, fixture: fixture, root: root)
        print("CaptureWorker IPC: \(passed) assertions passed. Synthetic Python child only; no UI/device/network.")
    }

    static func flowingAndConcurrentTests(python: String, fixture: String, root: URL) async throws {
        func context(_ name: String, _ mode: String) throws -> (URL, CaptureWorker.Configuration) {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try mode.write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            return (folder, .init(python: python, script: fixture, stateDirectory: folder.path, outputDirectory: folder.path))
        }
        for (mode, direct) in [("flow-12mb", false), ("flow-slow-wifi", false), ("flow-slow-wifi", true),
                               ("flow-no-bytes", false), ("flow-stalled", false), ("flow-too-long", false)] {
            let (folder, config) = try context(mode + (direct ? "-direct" : ""), mode)
            let worker = CaptureWorker(wifiHedgingEnabled: false, wifiOnly: direct); defer { worker.stop() }
            var progress: [Double] = []
            worker.onCaptureProgress = { _, got, total in if total > 0 { progress.append(got / total) } }
            let box = Box(), at = ProcessInfo.processInfo.systemUptime
            try request(worker, config, folder, box, timeout: 40)
            let result = try await response(box, within: mode == "flow-too-long" ? 31 : 12)
            let elapsed = ProcessInfo.processInfo.systemUptime - at
            try expect(result.exit == (["flow-12mb", "flow-slow-wifi"].contains(mode) ? 0 : 1), "\(mode): incorrect outcome \(result.json)")
            if mode == "flow-12mb" {
                try expect(elapsed > 5.5 && elapsed < 8 && progress.count > 10 && progress.last! > 0.9,
                           "flowing transfer or its progress was cut off")
            } else if mode == "flow-slow-wifi" {
                try expect(elapsed >= 10 && elapsed < 12 && progress.count > 20 && progress.last! > 0.9,
                           "iPad transfer must finish beyond the old 8-second cutoff, direct=\(direct)")
            } else if mode == "flow-too-long" { try expect(elapsed >= 29.9 && elapsed < 31, "30-second hard cap moved") }
            else if mode == "flow-stalled" {
                try expect(result.json["reason"] as? String == "stall_timeout" && elapsed >= 2.5 && elapsed < 4.4,
                           "received bytes then a 2.5-second stall must fail before the normal 4.5-second budget")
            } else { try expect(elapsed >= 4.4 && elapsed < 5, "silent transfer must not extend") }
            try expect(box.responses.count == 1, "duplicate completion")
            print("PASS \(mode): \(String(format: "%.2f", elapsed)) seconds, \(progress.count) progress updates")
        }
        let (one, configOne) = try context("parallel-one", "delay")
        let (two, configTwo) = try context("parallel-two", "normal")
        let primary = CaptureWorker(wifiHedgingEnabled: false)
        let secondary = CaptureWorker(wifiHedgingEnabled: false, wifiOnly: true)
        defer { primary.stop(); secondary.stop() }
        let first = Box(), second = Box()
        try request(primary, configOne, one, first)
        try request(secondary, configTwo, two, second)
        _ = try await response(second, within: 1.5)
        try expect(first.responses.isEmpty && primary.isBusy, "second completion blocked behind first")
        _ = try await response(first, within: 1.5)
        try expect(first.responses.count == 1 && second.responses.count == 1, "parallel requests not once-only")
        try expect(first.responses[0].json["worker_pid"] as? Int != second.responses[0].json["worker_pid"] as? Int,
                   "two capture lanes share a process")
        try "timeout-reply".write(to: one.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let failed = Box(), survived = Box()
        try request(primary, configOne, one, failed); try request(secondary, configTwo, two, survived)
        try expect(try await response(failed, within: 1.5).exit == 1, "failure fixture did not fail")
        try expect(try await response(survived, within: 1.5).exit == 0, "one lane failure cancelled the other")
        print("PASS independent processes: second first; ordinary failure isolated")
    }

    static func adaptiveThresholdTests(python: String, fixture: String, root: URL) async throws {
        for (mode, hedging) in [("adaptive-slow", false), ("adaptive-slow", true),
            ("adaptive-connect", true), ("adaptive-cold", true), ("adaptive-validation", true), ("adaptive-ddi", true),
            ("adaptive-relay", true), ("adaptive-relay-slow", true), ("adaptive-hedge", true),
            ("adaptive-hedge-win", true), ("adaptive-validation-black-hedge", true),
            ("adaptive-validation-connecting-hedge", true), ("adaptive-cap", true)] {
            if let selected = ProcessInfo.processInfo.environment["TOSS_ADAPTIVE_REGRESSION_CASE"], selected != mode { continue }
            let folder = root.appendingPathComponent(mode + (hedging ? "-pool" : "-single"))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try mode.write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let config = CaptureWorker.Configuration(python: python, script: fixture,
                stateDirectory: folder.path, outputDirectory: folder.path)
            let relay = mode.hasPrefix("adaptive-relay")
            if relay { try Data().write(to: folder.appendingPathComponent("usb-present")) }
            let worker = CaptureWorker(wifiHedgingEnabled: hedging)
            defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 2) {
                relay ? worker.connectionStatus.isHealthyUSB : audit(folder).filter {
                    $0["event"] as? String == "ready" }.count == (hedging ? 2 : 1)
            }
            // The fixture appends its audit immediately after writing to the pipe;
            // allow the native reader to consume both ready events before choosing a role.
            try await Task.sleep(nanoseconds: 50_000_000)
            let box = Box(), start = ProcessInfo.processInfo.systemUptime
            try request(worker, config, folder, box, timeout: 40)
            let result = try await response(box, within: 5.2)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let black = ["adaptive-validation-black-hedge", "adaptive-validation-connecting-hedge"].contains(mode)
            let fails = ["adaptive-slow", "adaptive-relay-slow", "adaptive-hedge", "adaptive-cap"].contains(mode) || black
            try expect(result.exit == (fails ? 1 : 0), "\(mode): wrong result \(result.json)")
            if black {
                try expect(result.json["reason"] as? String == "black_frame_rejected" && elapsed < 1.8,
                           "completed content rejection should not wait for a hanging hedge")
            } else if fails {
                try expect(result.json["reason"] as? String == "timeout", "no-byte deadline must replace historical cutoff")
                try expect(elapsed >= 4.4 && elapsed < 5.1, "no-byte transfer must retain 4.5 second budget")
            }
            if relay && !fails {
                let attempts = result.json["route_attempts"] as? [[String: Any]] ?? []
                try expect(attempts.first?["transport"] as? String == "usb" &&
                           attempts.first?["reason"] as? String == "first_byte_timeout", "USB must wait for generation before fallback")
                try expect(result.json["transport"] as? String == "authenticated_wifi", "Wi-Fi relay missing")
                try expect(elapsed >= 3.2, "USB fell back before 2.5 seconds")
            }
            if mode.hasPrefix("adaptive-hedge") {
                let requests = audit(folder).filter { $0["event"] as? String == "request" }
                try expect(requests.count == 2, "\(mode): hedge requests \(requests)")
                let firstEnd = requests.first?["deadline"] as? Double ?? 0
                try expect(requests.first?["press_started"] as? Double == requests.last?["press_started"] as? Double,
                           "fallback/hedge reset the normal no-byte budget")
                try expect(abs((requests.last?["screenshot_deadline"] as? Double ?? 0) - firstEnd) < 0.001,
                           "hedge received a fresh hard budget")
            }
            if ["adaptive-connect", "adaptive-cold"].contains(mode) {
                try expect(elapsed >= 1.3, "connection time counted in T")
            }
            if mode == "adaptive-validation" { try expect(elapsed >= 1.2, "validation did not outlive T in fixture") }
            if mode == "adaptive-ddi" { try expect(elapsed >= 1.2, "DDI first capture exemption lost") }
            try await Task.sleep(nanoseconds: 150_000_000)
            try expect(box.responses.count == 1 && !worker.isBusy, "\(mode): more than one completion")
            print("PASS \(mode) hedging=\(hedging): screenshot deadline / relay / one result")
        }
    }

    static func usbRegressionTests(python: String, fixture: String, root: URL) async throws {
        let selected = ProcessInfo.processInfo.environment["TOSS_USB_REGRESSION_CASE"]
        func context(_ name: String, _ mode: String) throws -> (URL, CaptureWorker.Configuration) {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try mode.write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            return (folder, .init(python: python, script: fixture,
                                 stateDirectory: folder.path, outputDirectory: folder.path))
        }
        if selected == nil || selected == "watcher-restart" {
            let (folder, config) = try context("watcher-restart", "usb-success")
            let worker = CaptureWorker(); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.state == .ready }
            try Data().write(to: folder.appendingPathComponent("crash-wifi"))
            try await waitUntil(within: 2.0) {
                audit(folder).filter { $0["event"] as? String == "started" && $0["transport"] as? String == "wifi" }.count == 2
            }
            try expect(audit(folder).filter { $0["event"] as? String == "request" }.isEmpty,
                       "watcher recovery must not manufacture a capture")
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            try await waitUntil(within: 1.5) { worker.connectionStatus.isHealthyUSB }
            try expect(worker.connectionStatus.transport == "usb", "restarted watcher did not notice cable insertion")
            try FileManager.default.removeItem(at: folder.appendingPathComponent("usb-present"))
            try await waitUntil(within: 1.5) { worker.connectionStatus.transport == "wifi" }
            worker.stop()
            let starts = audit(folder).filter { $0["event"] as? String == "started" }.count
            try await Task.sleep(nanoseconds: 650_000_000)
            try expect(audit(folder).filter { $0["event"] as? String == "started" }.count == starts,
                       "stop allowed queued watcher recovery to resurrect a child")
            print("PASS idle Wi-Fi crash restores USB monitoring without another keypress")
        }
        if selected == nil || selected == "wifi-only-cap" {
            UserDefaults.standard.set(800.0, forKey: "pressCapMs")
            defer { UserDefaults.standard.removeObject(forKey: "pressCapMs") }
            let (folder, config) = try context("wifi-only-cap", "timeout")
            // The direct (unrouted) Wi-Fi path exists only with hedging off.
            let worker = CaptureWorker(wifiHedgingEnabled: false); defer { worker.stop() }
            let first = Box()
            let started = ProcessInfo.processInfo.systemUptime
            try request(worker, config, folder, first, timeout: 40)
            let failed = try await response(first, within: 3)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            try expect(failed.exit == 1 && failed.json["reason"] as? String == "timeout",
                       "hung Wi-Fi-only child was not failed at the press cap")
            try expect(elapsed < 2.5, "Wi-Fi-only press waited \(elapsed) s instead of cap + backstop")
            let hungPIDs = audit(folder).filter { $0["event"] as? String == "request" }.compactMap { $0["worker_pid"] as? Int32 }
            try "normal".write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let next = Box()
            try request(worker, config, folder, next, timeout: 40)
            let recovered = try await response(next, within: 3)
            try expect(recovered.exit == 0 && first.responses.count == 1 && !worker.isBusy,
                       "next Wi-Fi-only keypress stayed blocked behind the hung child")
            try await Task.sleep(nanoseconds: 1_300_000_000)
            try expect(hungPIDs.allSatisfy { kill($0, 0) == -1 && errno == ESRCH },
                       "Wi-Fi-only backstop left the hung child alive")
            print("PASS Wi-Fi-only press is capped even when the child hangs")
        }
        if selected == nil || selected == "cap-drains-wifi" {
            UserDefaults.standard.set(800.0, forKey: "pressCapMs")
            defer { UserDefaults.standard.removeObject(forKey: "pressCapMs") }
            let (folder, config) = try context("cap-drains-wifi", "wifi-late-timeout")
            let worker = CaptureWorker(); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.state == .ready }
            let first = Box()
            try request(worker, config, folder, first, timeout: 40)
            let failed = try await response(first, within: 1.5)
            try expect(failed.exit == 1 && failed.json["reason"] as? String == "timeout", "Wi-Fi press not failed at the cap")
            try await Task.sleep(nanoseconds: 1_200_000_000) // the child answers its own cap meanwhile
            try "wifi-healthy".write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            UserDefaults.standard.set(3000.0, forKey: "pressCapMs") // the healthy fixture takes 1.2 s
            let next = Box()
            try request(worker, config, folder, next, timeout: 40)
            let recovered = try await response(next, within: 3)
            try expect(recovered.exit == 0 && first.responses.count == 1, "next press after a drained cap failed")
            let pids = audit(folder).filter { $0["event"] as? String == "request" }.compactMap { $0["worker_pid"] as? Int32 }
            // The next press may use the ready standby; the first child must simply still be alive.
            try expect(!pids.isEmpty && kill(pids[0], 0) == 0, "a child that answered its own cap was killed (cold restart)")
            print("PASS Wi-Fi child that answers its own cap stays warm for the next press")
        }
        if selected == nil || selected == "cap-releases-workers" {
            UserDefaults.standard.set(800.0, forKey: "pressCapMs")
            defer { UserDefaults.standard.removeObject(forKey: "pressCapMs") }
            let (folder, config) = try context("cap-releases-workers", "usb-cap-hang")
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            let worker = CaptureWorker(); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.isHealthyUSB }
            let first = Box()
            try request(worker, config, folder, first, timeout: 40)
            let failed = try await response(first, within: 1.5)
            try expect(failed.exit == 1 && failed.json["reason"] as? String == "timeout", "hung fallback did not reach shared cap")
            let hungPIDs = audit(folder).filter { $0["event"] as? String == "request" }.compactMap { $0["worker_pid"] as? Int32 }
            try expect(hungPIDs.count == 2,
                       "test must hang both the abandoned USB attempt and Wi-Fi fallback")
            try "usb-success".write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let next = Box()
            try request(worker, config, folder, next, timeout: 40)
            let recovered = try await response(next, within: 1.5)
            try expect(recovered.exit == 0, "expired attempts left the next keypress attached to a busy worker")
            try expect(first.responses.count == 1 && next.responses.count == 1 && !worker.isBusy,
                       "deadline completion or recovery was duplicated")
            // A Wi-Fi child gets 1 s to answer its own cap before it is retired (SIGKILL 1 s later).
            try await Task.sleep(nanoseconds: 2_300_000_000)
            try expect(hungPIDs.allSatisfy { kill($0, 0) == -1 && errno == ESRCH },
                       "deadline left a cancellation-ignoring child alive")
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".capture-attempt-") }.isEmpty,
                       "expired worker leaked an attempt file")
            print("PASS shared cap retires hung USB and Wi-Fi children; next keypress works immediately")
        }
        if selected == nil || selected == "progress-route-status" {
            let (folder, config) = try context("progress-route-status", "usb-progress-late")
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            let worker = CaptureWorker(); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.isHealthyUSB }
            let box = Box()
            try request(worker, config, folder, box)
            let result = try await response(box, within: 1.5)
            try expect(result.exit == 0 && result.json["transport"] as? String == "authenticated_wifi",
                       "test did not finish via Wi-Fi")
            try expect(worker.connectionStatus.transport == "wifi" && worker.connectionStatus.state == .ready,
                       "an abandoned USB RPC was advertised as ready after Wi-Fi won")
            print("PASS USB progress failure removes stale ready status before teardown finishes")
        }
        if selected == nil || selected == "active-route-status" {
            let (folder, config) = try context("active-route-status", "usb-version-delayed")
            try Data().write(to: folder.appendingPathComponent("usb-present"))
            let worker = CaptureWorker(); defer { worker.stop() }
            try worker.prepare(configuration: config)
            try await waitUntil(within: 1.5) { worker.connectionStatus.reason == "unexpected_library_version" }
            let box = Box()
            try request(worker, config, folder, box)
            try await waitUntil(within: 1.5) { audit(folder).contains { $0["event"] as? String == "request" } }
            try expect(worker.connectionStatus.transport == "wifi" && worker.connectionStatus.state == .ready,
                       "a USB diagnostic concealed the actual active Wi-Fi route")
            let captured = try await response(box, within: 1.5)
            try expect(captured.exit == 0 && captured.json["transport"] as? String == "authenticated_wifi",
                       "fatal USB diagnostic prevented Wi-Fi capture")
            try expect(worker.connectionStatus.reason == "unexpected_library_version",
                       "idle USB diagnostic was lost after Wi-Fi completion")
            print("PASS active Wi-Fi route takes priority over idle USB diagnostics")
        }
    }

    static func request(_ worker: CaptureWorker, _ config: CaptureWorker.Configuration,
                        _ folder: URL, _ box: Box, timeout: Double = 4) throws {
        let id = UUID().uuidString.lowercased()
        try worker.capture(configuration: config, requestID: id,
                           file: folder.appendingPathComponent("\(id).png"), timeout: timeout) { data, exit in
            box.responses.append(Response(data: data, exit: exit))
        }
    }
    static func response(_ box: Box, within seconds: Double) async throws -> Response {
        try await waitUntil(within: seconds) { !box.responses.isEmpty }
        return box.responses[0]
    }
    static func waitUntil(within seconds: Double, _ ready: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !ready() && ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if !ready() { throw Failure(description: "Timed out awaiting synthetic IPC event") }
    }
    static func audit(_ folder: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("audit.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
    static func expect(_ condition: Bool, _ reason: String) throws {
        if !condition { throw Failure(description: reason) }
        passed += 1
    }
}
