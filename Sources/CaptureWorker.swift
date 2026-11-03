import Foundation
import Darwin
import CoreFoundation

enum CaptureWorkerError: LocalizedError {
    case busy, unavailable
    var errorDescription: String? {
        switch self {
        case .busy: return "A screenshot is still being processed. This request was not queued."
        case .unavailable: return L("Wireless capture isn't running. No retry.", "无线截图进程不可用，没有重试。")
        }
    }
}

enum CaptureProgressPolicy {
    static let noticeDelay: Double = 2
    static func shouldShow(startedAt: Double, now: Double, finished: Bool) -> Bool {
        !finished && now - startedAt >= noticeDelay
    }
}

// An anonymous-pipe child owned by this helper, not a listener or daemon. It
// retains no screenshot for reuse. All results still pass CaptureReceipt before
// any target focus or paste. Cancelling invalidates the whole process generation.
@MainActor
final class CaptureWorkerProcess {
    // Keep even recently retired children until they exit. Uninstall must drain
    // the whole owned process pool, not just the current dictionary of workers.
    private static var ownedProcesses: [Process] = []
    private(set) static var uninstalling = false

    static func beginUninstall() { uninstalling = true }
    static func drainForUninstall() async throws {
        let grace = ProcessInfo.processInfo.systemUptime + 1.1
        while ownedProcesses.contains(where: \.isRunning) && ProcessInfo.processInfo.systemUptime < grace {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        for process in ownedProcesses where process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ownedProcesses.contains(where: \.isRunning) && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        ownedProcesses.removeAll { !$0.isRunning }
        if !ownedProcesses.isEmpty { throw CaptureWorkerError.unavailable }
    }
    struct Configuration: Equatable {
        let python: String
        let script: String
        let stateDirectory: String
        let outputDirectory: String
    }
    private struct Pending {
        let id: String
        let attemptID: String?
        let completion: (Data, Int32) -> Void
    }
    let role: CaptureWorkerRole
    init(role: CaptureWorkerRole) { self.role = role }
    var onUSBPresence: ((Bool) -> Void)?
    var onAttemptFailure: ((String, String, String, [String: Any]) -> Void)?
    var onProgress: ((String, String?, String, String, [String: Any]) -> Void)?
    var onScreenshotStarted: ((String, String?, [String: Any]) -> Void)?
    var onScreenshotCompleted: ((String, String?, Double) -> Void)?
    private var child: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var configuration: Configuration?
    private var generation: UInt64 = 0
    private var pending: Pending?
    var isBusy: Bool { pending != nil }
    var pendingRequestID: String? { pending?.id }
    // The backend already closed its session and reconnects in the background: keep the process.
    static let reconnectingFailures: Set<String> = ["timeout", "first_byte_timeout", "stall_timeout", "too_slow",
                                                    "disconnected", "slow_threshold"]

    // Wi-Fi's first-byte threshold remains advisory. Once bytes have arrived, a
    // 1.2 s stall ends a serial transfer; this does not discard later keypresses.
    static let progressLimitDefaults: [(key: String, field: String, value: Double, range: ClosedRange<Double>)] = [
        ("firstByteLimitMs", "first_byte", 800, 200...5000),
        ("stallLimitMs", "stall", 1200, 200...5000),
        ("pressCapMs", "press_cap", 8000, 800...8000)]
    static func progressLimits(_ defaults: UserDefaults = .standard) -> [String: Double] {
        var limits: [String: Double] = [:]
        for item in progressLimitDefaults {
            let set = defaults.object(forKey: item.key) as? Double ?? item.value
            let value = set.isFinite ? set : item.value
            limits[item.field] = min(max(value, item.range.lowerBound), item.range.upperBound)
        }
        return limits
    }

    // Content rejections after a complete reply; must match LINK_SAFE_FAILURES in capture_service.py.
    static let linkSafeFailures: Set<String> = ["black_frame_rejected", "invalid_png", "empty_frame",
                                                "frame_too_large", "unexpected_dimensions"]
    private(set) var connectionStatus = TossConnectionStatus.notChecked
    var onConnectionChange: ((TossConnectionStatus) -> Void)?

    private func publishConnection(_ status: TossConnectionStatus) {
        let status = TossConnectionStatus(state: status.state, reason: status.reason,
            transport: status.state == .notChecked ? nil : role.transport)
        guard connectionStatus != status else { return }
        connectionStatus = status
        onConnectionChange?(status)
    }

    // User Enable may prepare authentication while the chat's accessibility
    // mode starts up. No capture request, file path or result is produced here.
    // The child keeps reconnecting in the background until it is stopped.
    func prepare(configuration: Configuration) throws {
        guard pending == nil else { throw CaptureWorkerError.busy }
        if child?.isRunning == true && self.configuration == configuration { return }
        stop()
        try launch(configuration, preconnect: true)
    }

    func capture(configuration: Configuration, requestID: String, file: URL,
                 timeout: Double = 40, attemptID: String? = nil, deadline: Double? = nil,
                 limits: [String: Double]? = nil, screenshotDeadline: Double? = nil, pressStarted: Double? = nil,
                 completion: @escaping (Data, Int32) -> Void) throws {
        guard pending == nil else { throw CaptureWorkerError.busy }
        guard UUID(uuidString: requestID)?.uuidString.lowercased() == requestID,
              timeout.isFinite, (4...45).contains(timeout) else { throw CaptureWorkerError.unavailable }
        if child?.isRunning != true || self.configuration != configuration {
            stop()
            try launch(configuration)
        }
        var payload: [String: Any] = ["action": "capture", "request_id": requestID,
            "output_file": file.path, "timeout": timeout, "limits_ms": limits ?? Self.progressLimits()]
        if let attemptID, let deadline {
            payload["attempt_id"] = attemptID
            payload["deadline_monotonic"] = deadline
        }
        if let screenshotDeadline { payload["screenshot_deadline_monotonic"] = screenshotDeadline }
        if let pressStarted { payload["press_started_monotonic"] = pressStarted }
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count < 4096 else { throw CaptureWorkerError.unavailable }
        data.append(0x0a)
        let token = generation
        pending = Pending(id: requestID, attemptID: attemptID, completion: completion)
        do {
            guard let input else { throw CaptureWorkerError.unavailable }
            try input.write(contentsOf: data)
        }
        catch { stop(); throw CaptureWorkerError.unavailable }
        // A lost or blocked child cannot hold the hotkey transaction forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.generation == token, self.pending?.id == requestID else { return }
            self.failCurrent(reason: "timeout")
        }
    }

    func stop() {
        generation &+= 1
        pending = nil
        let previous = child
        child = nil
        configuration = nil
        try? input?.close(); input = nil
        // The reader owns and closes this descriptor. Closing it from this
        // thread could let a later child reuse the fd while the old read wakes.
        // Terminating the old child releases its pipe and unblocks that reader.
        output = nil
        if let previous, previous.isRunning {
            previous.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if previous.isRunning { _ = kill(previous.processIdentifier, SIGKILL) }
            }
        }
        publishConnection(.notChecked)
    }

    private func launch(_ config: Configuration, preconnect: Bool = false) throws {
        guard !Self.uninstalling else { throw CaptureWorkerError.unavailable }
        guard FileManager.default.isExecutableFile(atPath: config.python),
              FileManager.default.fileExists(atPath: config.script) else { throw CaptureWorkerError.unavailable }
        let process = Process()
        let incoming = Pipe(), outgoing = Pipe()
        // A child can exit between isRunning and write(). Make a closed pipe
        // throw EPIPE instead of delivering SIGPIPE to the menu-bar helper.
        guard fcntl(incoming.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw CaptureWorkerError.unavailable
        }
        process.executableURL = URL(fileURLWithPath: config.python)
        process.arguments = [config.script, "--state-dir", config.stateDirectory,
            "--output-dir", config.outputDirectory, "--idle-seconds", "1800",
            "--timings-file", FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Toss/screenshot-success-times.json").path]
        // Keep an authenticated connection ready and re-establish it whenever
        // the iPad drops it (sleep, restart, network change), mounting the
        // developer image again after a restart. Never requests a frame.
        process.arguments?.append("--keep-warm")
        process.arguments?.append("--connection-events")
        process.arguments? += ["--transport", role.transport, "--worker-role", role.rawValue]
        if role == .wifiPrimary { process.arguments?.append("--watch-usb") }
        if preconnect { process.arguments?.append("--preconnect") }
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        process.environment = environment
        process.standardInput = incoming
        process.standardOutput = outgoing
        process.standardError = FileHandle.nullDevice
        try process.run()
        Self.ownedProcesses.removeAll { !$0.isRunning }
        Self.ownedProcesses.append(process)
        child = process
        input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading
        configuration = config
        publishConnection(.init(state: .connecting, reason: "connecting"))
        let token = generation
        let reader = outgoing.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { try? reader.close() }
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            do {
                // Foundation read(upToCount:) waits for the requested length or
                // EOF on macOS. A persistent child emits short JSON lines, so
                // use POSIX short reads to deliver each line immediately.
                while true {
                    let count = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw CaptureWorkerError.unavailable
                    }
                    buffer.append(contentsOf: bytes.prefix(count))
                    while let newline = buffer.firstIndex(of: 0x0a) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard !line.isEmpty, line.count < 16_384 else {
                            throw CaptureWorkerError.unavailable
                        }
                        DispatchQueue.main.async { [weak self] in
                            self?.receive(line, generation: token)
                        }
                    }
                    guard buffer.count < 16_384 else { throw CaptureWorkerError.unavailable }
                }
            } catch { /* Only a fixed protocol-failure code crosses this boundary. */ }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.failCurrent(reason: "worker_failed")
            }
        }
    }

    private func receive(_ data: Data, generation token: UInt64) {
        guard generation == token else { return }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            failCurrent(reason: "capture_integrity_failed")
            return
        }
        guard value["worker_role"] as? String == role.rawValue,
              value["transport"] as? String == "authenticated_" + role.transport else {
            failCurrent(reason: "capture_integrity_failed"); return
        }
        var eventValue = value
        eventValue.removeValue(forKey: "worker_role")
        eventValue.removeValue(forKey: "transport")
        if value["event"] as? String == "usb_presence" {
            guard role == .wifiPrimary, Self.schemaOne(value),
                  Set(eventValue.keys) == ["schema_version", "event", "present"],
                  let number = value["present"] as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else {
                failCurrent(reason: "capture_integrity_failed"); return
            }
            onUSBPresence?(number.boolValue)
            return
        }
        if value["event"] as? String == "capture_started" {
            let fields: Set<String> = ["schema_version", "event", "request_id", "capture_started_monotonic",
                "screenshot_deadline_monotonic", "slow_threshold_ms", "slow_sample_count", "slow_threshold_exempt"]
            guard Self.schemaOne(value), Set(eventValue.keys).subtracting(["attempt_id"]) == fields,
                  let active = pending, value["request_id"] as? String == active.id,
                  value["attempt_id"] as? String == active.attemptID,
                  ["capture_started_monotonic", "screenshot_deadline_monotonic", "slow_threshold_ms", "slow_sample_count"].allSatisfy({ key in
                      guard let n = value[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
                      return n.doubleValue.isFinite && n.doubleValue >= 0
                  }), let threshold = value["slow_threshold_ms"] as? Double,
                  ((role.transport == "usb" ? 600.0 : 1000.0)...4500.0).contains(threshold),
                  let count = value["slow_sample_count"] as? Double, count <= 100, count.rounded() == count,
                  let exempt = value["slow_threshold_exempt"] as? NSNumber,
                  CFGetTypeID(exempt) == CFBooleanGetTypeID()
            else { failCurrent(reason: "capture_integrity_failed"); return }
            onScreenshotStarted?(active.id, active.attemptID, value)
            return
        }
        if value["event"] as? String == "capture_completed" {
            guard Self.schemaOne(value), Set(eventValue.keys).subtracting(["attempt_id"]) ==
                    ["schema_version", "event", "request_id", "capture_completed_monotonic"],
                  let active = pending, value["request_id"] as? String == active.id,
                  value["attempt_id"] as? String == active.attemptID,
                  let completed = value["capture_completed_monotonic"] as? NSNumber,
                  CFGetTypeID(completed) != CFBooleanGetTypeID(), completed.doubleValue.isFinite,
                  completed.doubleValue >= 0
            else { failCurrent(reason: "capture_integrity_failed"); return }
            onScreenshotCompleted?(active.id, active.attemptID, completed.doubleValue)
            return
        }
        if value["event"] as? String == "capture_progress" {
            let required: Set<String> = ["schema_version", "event", "request_id", "elapsed_ms",
                                         "received_bytes", "idle_ms", "reason", "source"]
            guard Self.schemaOne(value),
                  Set(eventValue.keys).subtracting(["attempt_id", "expected_bytes", "rpc_received_bytes"]) == required,
                  let active = pending, value["request_id"] as? String == active.id,
                  value["attempt_id"] as? String == active.attemptID,
                  let reason = value["reason"] as? String,
                  ["progress", "first_byte_timeout", "stall_timeout", "too_slow"].contains(reason),
                  let source = value["source"] as? String, ["rpc", "tunnel", "unknown"].contains(source),
                  (["elapsed_ms", "received_bytes", "idle_ms"] + ["expected_bytes", "rpc_received_bytes"].filter { value[$0] != nil }).allSatisfy({ key in
                      guard let n = value[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID()
                      else { return false }
                      return n.doubleValue.isFinite && n.doubleValue >= 0
                  }) else { failCurrent(reason: "capture_integrity_failed"); return }
            onProgress?(active.id, active.attemptID, reason, source, value)
            return
        }
        if value["event"] as? String == "attempt_failed" {
            guard role == .usbPrimary, Self.schemaOne(value),
                  Set(eventValue.keys).subtracting(["timings_ms"]) == ["schema_version", "event", "request_id", "attempt_id", "reason"],
                  let active = pending, let attempt = active.attemptID,
                  value["request_id"] as? String == active.id,
                  value["attempt_id"] as? String == attempt,
                  let reason = value["reason"] as? String,
                  ["first_byte_timeout", "stall_timeout", "too_slow", "slow_threshold"].contains(reason) else {
                failCurrent(reason: "capture_integrity_failed"); return
            }
            // The old RPC is already unusable even while Python is tearing it
            // down. Do not advertise USB as ready after the Wi-Fi reply wins.
            publishConnection(.init(state: .failed, reason: reason))
            onAttemptFailure?(active.id, attempt, reason, value)
            return
        }
        if value["event"] != nil {
            guard let event = TossConnectionStatus.event(eventValue) else {
                failCurrent(reason: "capture_integrity_failed")
                return
            }
            publishConnection(event)
            return
        }
        guard let active = pending,
              value["request_id"] as? String == active.id,
              value["attempt_id"] as? String == active.attemptID,
              let ok = value["ok"] as? Bool else {
            failCurrent(reason: "capture_integrity_failed")
            return
        }
        pending = nil // Advance before exposing the result; never retry a request.
        if !ok {
            let reason = value["reason"] as? String ?? "worker_failed"
            // A complete reply that was only rejected on its content (a black or malformed frame)
            // left the link healthy; the backend keeps its session, so keep the worker too
            // (2026-10-25: 13 black frames each tore down a good connection). Anything else:
            // unknown connection state is discarded as a whole.
            // A timeout reply means the backend already closed its uncertain session itself and
            // keeps a reconnect running for the next keypress (capture_service.py); killing the
            // process here threw that away and made the next keypress start cold (2026-10-25).
            let clean = reason.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil ? reason : "worker_failed"
            if !Self.linkSafeFailures.contains(reason) {
                if !Self.reconnectingFailures.contains(reason) { stop() }
                publishConnection(.init(state: .failed, reason: clean))
            }
        }
        active.completion(data, ok ? 0 : 1)
    }

    private static func schemaOne(_ value: [String: Any]) -> Bool {
        guard let n = value["schema_version"] as? NSNumber else { return false }
        return CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue == 1
    }

    private func failCurrent(reason: String) {
        let active = pending
        stop()
        publishConnection(.init(state: .failed, reason: reason))
        guard let active else { return }
        var value: [String: Any] = ["schema_version": 1, "request_id": active.id,
            "ok": false, "reason": reason, "transport": "authenticated_" + role.transport,
            "worker_role": role.rawValue]
        if let attempt = active.attemptID { value["attempt_id"] = attempt }
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        active.completion(data, 1)
    }
}

// A PyTCP stack belongs to one process. Roles are independent even when two
// roles eventually use Wi-Fi; presence monitoring lives in the primary worker.
enum CaptureWorkerRole: String {
    case wifiPrimary = "wifi_primary", usbPrimary = "usb_primary", wifiStandby = "wifi_standby"
    var transport: String { self == .usbPrimary ? "usb" : "wifi" }
}

@MainActor
final class CaptureWorker {
    typealias Configuration = CaptureWorkerProcess.Configuration
    static let progressLimitDefaults = CaptureWorkerProcess.progressLimitDefaults
    static let reconnectingFailures = CaptureWorkerProcess.reconnectingFailures
    static let linkSafeFailures = CaptureWorkerProcess.linkSafeFailures
    static func progressLimits(_ defaults: UserDefaults = .standard) -> [String: Double] {
        CaptureWorkerProcess.progressLimits(defaults)
    }
    private static let fatalUSBFailures: Set<String> = ["unexpected_library_version",
        "rsd_device_identity_mismatch", "unexpected_device_pin", "usb_ipados_unsupported",
        "another_userspace_tunnel_active_in_process"]

    @MainActor private final class Transaction {
        let id: String, file: URL, configuration: Configuration, timeout: Double
        let limits: [String: Double], started = ProcessInfo.processInfo.systemUptime
        let completion: (Data, Int32) -> Void
        var hardDeadline: Double { started + min(8, timeout, (limits["press_cap"] ?? 8000) / 1000) }
        var normalDeadline: Double { min(hardDeadline, started + 4.5) }
        var lastByteAt: Double?
        var receivedByAttempt: [String: Double] = [:]
        var lastByteByAttempt: [String: Double] = [:]
        var deadline: Double { min(hardDeadline, max(normalDeadline,
            (lastByteAt ?? started) + (limits["stall"] ?? 1200) / 1000)) }
        struct Attempt {
            let id: String, role: CaptureWorkerRole, file: URL, started: Double
        }
        var role: CaptureWorkerRole = .wifiPrimary
        var active: [String: Attempt] = [:]
        var usedRoles: Set<CaptureWorkerRole> = []
        var attempts: [[String: Any]] = []
        var files: Set<URL> = []
        var progressed: Set<String> = [] // attempt ids that reported any RPC progress
        struct ScreenshotPhase {
            let started: Double, deadline: Double, threshold: Double, count: Double, exempt: Bool
            var completed = false
            var timings: [String: Double] { ["slow_threshold": threshold, "slow_sample_count": count,
                                             "slow_threshold_exempt": exempt ? 1 : 0] }
        }
        var screenshotPhases: [String: ScreenshotPhase] = [:] // keyed by attempt id (role for direct mode)
        var wifiDeadline: Double?
        var routed = false
        init(id: String, file: URL, configuration: Configuration, timeout: Double,
             limits: [String: Double], completion: @escaping (Data, Int32) -> Void) {
            self.id = id; self.file = file; self.configuration = configuration
            self.timeout = timeout; self.completion = completion
            self.limits = limits
        }
    }
    // Rollback switch: a disabled pool retains one Wi-Fi worker. No standby ever prefetches a frame.
    private let wifiHedgingEnabled: Bool
    private let configuredLimits: [String: Double]?
    private let wifiOnly: Bool
    init(wifiHedgingEnabled: Bool = UserDefaults.standard.object(forKey: "wifiHedgingEnabled") as? Bool ?? true,
         progressLimits: [String: Double]? = nil, wifiOnly: Bool = false) {
        self.wifiHedgingEnabled = wifiHedgingEnabled
        self.configuredLimits = progressLimits
        self.wifiOnly = wifiOnly
    }
    private var workers: [CaptureWorkerRole: CaptureWorkerProcess] = [:]
    private var configuration: Configuration?
    private var usbPresent = false
    private var usbFatalReason: String?
    private var usbRetry: DispatchWorkItem?
    private var wifiRetry: DispatchWorkItem?
    private var wifiRetryDelay = 0.5 // doubles up to 30 s while the primary keeps failing; reset on ready
    private var pending: Transaction?
    private var attemptFiles: [URL: CaptureWorkerRole] = [:]
    var isBusy: Bool { pending != nil }
    var pendingRequestID: String? { pending?.id }
    private(set) var connectionStatus = TossConnectionStatus.notChecked
    var onConnectionChange: ((TossConnectionStatus) -> Void)?
    var onCaptureSlow: ((String) -> Void)?
    var onCaptureProgress: ((String, Double, Double) -> Void)?

    private func refreshConnection() {
        let usb = workers[.usbPrimary]?.connectionStatus
        let status: TossConnectionStatus
        if let pending, let current = workers[pending.role]?.connectionStatus {
            status = current
        } else if usbPresent, let reason = usbFatalReason {
            status = .init(state: .failed, reason: reason, transport: "usb")
        } else if usbPresent, let usb, usb.state == .ready {
            status = usb
        } else {
            let primary = workers[.wifiPrimary]?.connectionStatus
            let standby = workers[.wifiStandby]?.connectionStatus
            status = primary?.state == .ready ? primary! :
                (standby?.state == .ready ? standby! : primary ?? usb ?? .notChecked)
        }
        guard status != connectionStatus else { return }
        connectionStatus = status
        onConnectionChange?(status)
    }

    private func worker(_ role: CaptureWorkerRole) -> CaptureWorkerProcess {
        if let current = workers[role] { return current }
        // The second capture lane reuses the standby role: separate DVT/PyTCP process,
        // separate timeline, and no duplicate USB presence observer.
        let process = CaptureWorkerProcess(role: wifiOnly && role == .wifiPrimary ? .wifiStandby : role)
        workers[role] = process
        process.onConnectionChange = { [weak self, weak process] status in
            guard let self, let process, self.workers[role] === process else { return }
            if role == .usbPrimary {
                if Self.fatalUSBFailures.contains(status.reason) { self.usbFatalReason = status.reason }
                if status.state == .ready { self.usbFatalReason = nil }
                if status.state == .failed { self.scheduleUSBRecovery() }
            } else if role == .wifiPrimary, status.state == .failed {
                // This process also owns USB presence monitoring. Restore it
                // after EOF/crash even when the next capture would use USB.
                self.scheduleWiFiRecovery()
            } else if role == .wifiPrimary, status.state == .ready {
                self.wifiRetryDelay = 0.5
            }
            self.refreshConnection()
        }
        process.onUSBPresence = { [weak self, weak process] present in
            guard let self, let process, self.workers[.wifiPrimary] === process else { return }
            self.usbPresence(present)
        }
        process.onAttemptFailure = { [weak self, weak process] id, attempt, reason, receipt in
            guard let self, let process, self.workers[role] === process,
                  let transaction = self.pending, transaction.id == id,
                  let active = transaction.active[attempt], active.role == role else { return }
            self.fallback(transaction, attempt: active, reason: reason, receipt: receipt)
        }
        process.onProgress = { [weak self, weak process] id, attempt, reason, source, value in
            guard let self, let process, self.workers[role] === process,
                  let transaction = self.pending, transaction.id == id else { return }
            if transaction.routed {
                guard let attempt, transaction.active[attempt]?.role == role else { return }
            }
            let key = attempt ?? role.rawValue
            let received = value["received_bytes"] as? Double ?? 0
            if source != "unknown", received > (transaction.receivedByAttempt[key] ?? 0) {
                transaction.receivedByAttempt[key] = received
                let lastByte = ProcessInfo.processInfo.systemUptime - (value["idle_ms"] as? Double ?? 0) / 1000
                transaction.lastByteAt = max(transaction.lastByteAt ?? 0, lastByte)
                transaction.lastByteByAttempt[key] = lastByte
                if !self.wifiHedgingEnabled { self.watchStall(transaction, key: key, role: role, lastByte: lastByte) }
            }
            self.onCaptureProgress?(id, value["rpc_received_bytes"] as? Double ?? 0,
                                    value["expected_bytes"] as? Double ?? 0)
            guard let attempt, let active = transaction.active[attempt], active.role == role else { return }
            transaction.progressed.insert(attempt)
            guard source != "unknown", ["first_byte_timeout", "stall_timeout"].contains(reason) else { return }
            self.hedge(transaction, from: active)
        }
        process.onScreenshotStarted = { [weak self, weak process] id, attempt, value in
            guard let self, let process, self.workers[role] === process,
                  let transaction = self.pending, transaction.id == id else { return }
            self.screenshotStarted(transaction, role: role, attemptID: attempt, value: value)
        }
        process.onScreenshotCompleted = { [weak self, weak process] id, attempt, completed in
            guard let self, let process, self.workers[role] === process,
                  let transaction = self.pending, transaction.id == id else { return }
            let key = attempt ?? role.rawValue
            guard var phase = transaction.screenshotPhases[key] else { return }
            guard completed >= phase.started, completed <= ProcessInfo.processInfo.systemUptime + 0.05 else {
                self.finishFailure(transaction, reason: "capture_integrity_failed"); return
            }
            guard phase.exempt || completed <= phase.deadline else {
                self.screenshotExpired(transaction, role: role, attemptID: attempt)
                return
            }
            phase.completed = true
            transaction.screenshotPhases[key] = phase
        }
        return process
    }

    // Python announces the actual screenshot RPC, after connection / DDI preparation.
    // The native timer also bounds a child whose RPC ignores cancellation. A Wi-Fi hedge
    // inherits the first Wi-Fi RPC's deadline, so starting another request never buys time.
    private func screenshotStarted(_ transaction: Transaction, role: CaptureWorkerRole,
                                   attemptID: String?, value: [String: Any]) {
        if transaction.routed {
            guard let attemptID, transaction.active[attemptID]?.role == role else { return }
        }
        let key = attemptID ?? role.rawValue
        guard transaction.screenshotPhases[key] == nil,
              let started = value["capture_started_monotonic"] as? Double,
              let end = value["screenshot_deadline_monotonic"] as? Double,
              let threshold = value["slow_threshold_ms"] as? Double,
              let count = value["slow_sample_count"] as? Double,
              let exempt = value["slow_threshold_exempt"] as? Bool,
              started >= transaction.started - 0.05,
              started <= ProcessInfo.processInfo.systemUptime + 0.05,
              end >= started, end <= started + 8.05 else {
            finishFailure(transaction, reason: "capture_integrity_failed"); return
        }
        let ownEnd = transaction.hardDeadline
        let phaseEnd = role.transport == "wifi" ? min(ownEnd, transaction.wifiDeadline ?? ownEnd) : ownEnd
        let phase = Transaction.ScreenshotPhase(started: started, deadline: phaseEnd,
                                                threshold: threshold, count: count, exempt: exempt)
        transaction.screenshotPhases[key] = phase
        if let attemptID { transaction.progressed.insert(attemptID) }
        if role.transport == "wifi", !exempt { transaction.wifiDeadline = phaseEnd }
        guard !exempt, phaseEnd < transaction.hardDeadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, phaseEnd - ProcessInfo.processInfo.systemUptime)) {
            [weak self, weak transaction] in
            guard let self, let transaction, self.pending === transaction else { return }
            self.screenshotExpired(transaction, role: role, attemptID: attemptID)
        }
    }

    private func screenshotExpired(_ transaction: Transaction, role: CaptureWorkerRole, attemptID: String?) {
        let key = attemptID ?? role.rawValue
        guard let phase = transaction.screenshotPhases[key], !phase.exempt else { return }
        if role == .usbPrimary, let attemptID, let active = transaction.active[attemptID] {
            guard !phase.completed else { return }
            // Stop the abandoned transfer before handing its remaining press budget to Wi-Fi.
            workers.removeValue(forKey: role)?.stop()
            cleanStoppedFiles(role: role)
            fallback(transaction, attempt: active, reason: "slow_threshold", receipt: ["timings_ms": phase.timings])
            scheduleUSBRecovery()
        } else if role.transport == "wifi" {
            if !transaction.routed, phase.completed { return }
            // Complete bytes already waiting for validation are no longer a slow transfer.
            let completed = transaction.active.values.contains {
                $0.role.transport == "wifi" && transaction.screenshotPhases[$0.id]?.completed == true
            }
            if completed {
                // Validation may still reject the complete candidate. Stop this incomplete
                // sibling at T anyway; otherwise that rejection could leave a hung hedge
                // holding the result open until the press cap.
                let incomplete = transaction.active.values.filter {
                    $0.role.transport == "wifi" && transaction.screenshotPhases[$0.id]?.completed != true
                }
                for active in incomplete {
                    transaction.active.removeValue(forKey: active.id)
                    recordAttempt(transaction, attempt: active, reason: "slow_threshold")
                    workers.removeValue(forKey: active.role)?.stop()
                    cleanStoppedFiles(role: active.role)
                    replenish(active.role)
                }
                if let candidate = transaction.active.values.first { transaction.role = candidate.role }
                refreshConnection()
                return
            }
            finishFailure(transaction, reason: "slow_threshold", timings: phase.timings)
        }
    }

    private func usbPresence(_ present: Bool) {
        guard !wifiOnly else { return }
        usbPresent = present
        if present, let configuration {
            let usb = worker(.usbPrimary)
            if !usb.isBusy {
                do { try usb.prepare(configuration: configuration) }
                catch { /* Its connection status, or the Wi-Fi route, remains visible. */ }
            }
        } else {
            usbFatalReason = nil; usbRetry?.cancel(); usbRetry = nil
            // Invalidate the attempt before closing its process. A queued USB
            // receipt must never beat the new Wi-Fi attempt after an unplug.
            if let transaction = pending,
               let active = transaction.active.values.first(where: { $0.role == .usbPrimary }) {
                fallback(transaction, attempt: active, reason: "disconnected")
            }
            let usb = workers.removeValue(forKey: .usbPrimary)
            usb?.stop()
            cleanStoppedFiles(role: .usbPrimary)
        }
        refreshConnection()
    }

    private func scheduleUSBRecovery() {
        guard usbPresent, usbFatalReason == nil else { return }
        usbRetry?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.usbPresent, self.usbFatalReason == nil,
                  let configuration = self.configuration else { return }
            let usb = self.worker(.usbPrimary)
            if usb.isBusy { self.scheduleUSBRecovery(); return }
            try? usb.prepare(configuration: configuration)
        }
        usbRetry = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    private func scheduleWiFiRecovery() {
        guard configuration != nil else { return }
        wifiRetry?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, let configuration = self.configuration else { return }
            let wifi = self.worker(.wifiPrimary)
            if wifi.isBusy { self.scheduleWiFiRecovery(); return }
            do { try wifi.prepare(configuration: configuration) }
            catch { self.scheduleWiFiRecovery() }
        }
        wifiRetry = task
        // A child that dies at start-up (bad state folder, missing runtime) must not respawn
        // every 0.5 s forever.
        let delay = wifiRetryDelay
        wifiRetryDelay = min(30, wifiRetryDelay * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    func prepare(configuration: Configuration) throws {
        guard pending == nil else { throw CaptureWorkerError.busy }
        if let previous = self.configuration, previous != configuration { stop() }
        self.configuration = configuration
        try worker(.wifiPrimary).prepare(configuration: configuration)
        if wifiHedgingEnabled { try? worker(.wifiStandby).prepare(configuration: configuration) }
    }

    // Network path changes have no authority over an authenticated wired link.
    func invalidateWiFi() {
        for role in [CaptureWorkerRole.wifiPrimary, .wifiStandby] {
            workers.removeValue(forKey: role)?.stop()
            cleanStoppedFiles(role: role)
        }
        if let transaction = pending, transaction.role.transport == "wifi" {
            finishFailure(transaction, reason: "worker_failed")
        }
        if let configuration {
            try? worker(.wifiPrimary).prepare(configuration: configuration)
            if wifiHedgingEnabled { try? worker(.wifiStandby).prepare(configuration: configuration) }
        }
        refreshConnection()
    }

    func capture(configuration: Configuration, requestID: String, file: URL,
                 timeout: Double = 40, completion: @escaping (Data, Int32) -> Void) throws {
        guard pending == nil else { throw CaptureWorkerError.busy }
        guard UUID(uuidString: requestID)?.uuidString.lowercased() == requestID,
              timeout.isFinite, (4...45).contains(timeout) else { throw CaptureWorkerError.unavailable }
        if let previous = self.configuration, previous != configuration { stop() }
        self.configuration = configuration
        let transaction = Transaction(id: requestID, file: file, configuration: configuration,
            timeout: timeout, limits: configuredLimits ?? Self.progressLimits(), completion: completion)
        // A present cable remains the preferred route while its session reconnects.
        // Readiness is not cable availability; the USB attempt can authenticate.
        let preferUSB = usbPresent && usbFatalReason == nil && !wifiOnly
        transaction.routed = preferUSB || wifiHedgingEnabled
        if transaction.routed {
            guard file.deletingLastPathComponent().standardizedFileURL.path ==
                URL(fileURLWithPath: configuration.outputDirectory).standardizedFileURL.path else {
                throw CaptureWorkerError.unavailable
            }
        }
        pending = transaction
        // Slow is a request-level advisory, including authentication before any RPC progress exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + CaptureProgressPolicy.noticeDelay) { [weak self, weak transaction] in
            guard let self, let transaction, self.pending === transaction else { return }
            self.onCaptureSlow?(transaction.id)
        }
        if transaction.routed {
            watchDeadline(transaction)
            if preferUSB { startUSBWhenIdle(transaction) }
            else { startAttempt(transaction, role: wifiRole()) }
            if wifiHedgingEnabled {
                // Prepare only: a second process owns its own PyTCP stack and requests no image.
                for role in [CaptureWorkerRole.wifiPrimary, .wifiStandby] where workers[role]?.isBusy != true {
                    try? worker(role).prepare(configuration: configuration)
                }
            }
        } else {
            transaction.files.insert(file) // Also clean a cancellation-ignoring direct child.
            refreshConnection()
            do {
                try worker(.wifiPrimary).capture(configuration: configuration, requestID: requestID,
                    file: file, timeout: timeout, limits: transaction.limits, pressStarted: transaction.started) { [weak self] data, exit in
                    guard let self, self.pending === transaction else { return }
                    guard ProcessInfo.processInfo.systemUptime < transaction.deadline else {
                        self.finishFailure(transaction, reason: "timeout"); return
                    }
                    if exit == 0, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       !self.acceptScreenshotReceipt(transaction, role: .wifiPrimary, attemptID: nil, value: value) {
                        return
                    }
                    guard var value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        self.finishFailure(transaction, reason: "capture_integrity_failed"); return
                    }
                    self.addDirectRoute(to: &value, transaction: transaction, exit: exit)
                    self.pending = nil
                    self.refreshConnection()
                    completion((try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? data, exit)
                }
            } catch { pending = nil; throw error }
            // Keep the same hard cap with hedging disabled, including a blocked child.
            watchDeadline(transaction)
        }
    }

    // An old USB attempt can still be cleaning up after its Wi-Fi fallback won.
    // Wait for that owner instead of starting a second USB session or bypassing
    // the cable. The existing press deadline still bounds an unresponsive child.
    private func startUSBWhenIdle(_ transaction: Transaction) {
        guard pending === transaction else { return }
        transaction.role = .usbPrimary
        refreshConnection()
        if workers[.usbPrimary]?.isBusy == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self, weak transaction] in
                guard let transaction else { return }
                self?.startUSBWhenIdle(transaction)
            }
        } else { startAttempt(transaction, role: .usbPrimary) }
    }

    // A real byte counter advancing arms the stall watchdog. Duplicate progress
    // messages cannot renew it, and a completed RPC needs no further bytes while
    // PNG validation runs. The normal/hard budgets retain their original origin.
    private func watchStall(_ transaction: Transaction, key: String, role: CaptureWorkerRole, lastByte: Double) {
        let end = lastByte + (transaction.limits["stall"] ?? 1200) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, end - ProcessInfo.processInfo.systemUptime)) { [weak self, weak transaction] in
            guard let self, let transaction, self.pending === transaction,
                  transaction.lastByteByAttempt[key] == lastByte,
                  transaction.screenshotPhases[key]?.completed != true else { return }
            if transaction.routed {
                guard let attempt = transaction.active[key] else { return }
                if role == .usbPrimary { self.fallback(transaction, attempt: attempt, reason: "stall_timeout"); return }
            }
            self.finishFailure(transaction, reason: "stall_timeout")
        }
    }

    private func watchDeadline(_ transaction: Transaction) {
        let delay = max(0, transaction.deadline - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak transaction] in
            guard let self, let transaction, self.pending === transaction else { return }
            if ProcessInfo.processInfo.systemUptime >= transaction.deadline {
                self.finishFailure(transaction, reason: "timeout")
            } else { self.watchDeadline(transaction) }
        }
    }

    // The Wi-Fi role for a new attempt: a ready, idle one first (the standby only with hedging on).
    // A role still draining an expired press (see finish) is skipped; if every Wi-Fi role is still
    // draining, the primary is retired at once so this press is not refused as busy.
    private func wifiRole() -> CaptureWorkerRole {
        let roles: [CaptureWorkerRole] = wifiHedgingEnabled ? [.wifiPrimary, .wifiStandby] : [.wifiPrimary]
        let idle = roles.filter { workers[$0]?.isBusy != true }
        if let ready = idle.first(where: { workers[$0]?.connectionStatus.state == .ready }) { return ready }
        if let free = idle.first { return free }
        workers.removeValue(forKey: .wifiPrimary)?.stop()
        cleanStoppedFiles(role: .wifiPrimary)
        return .wifiPrimary
    }

    private func startAttempt(_ transaction: Transaction, role: CaptureWorkerRole) {
        guard pending === transaction, !transaction.usedRoles.contains(role) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard transaction.deadline - now >= 0.05 else { finishFailure(transaction, reason: "timeout"); return }
        let id = UUID().uuidString.lowercased()
        let path = transaction.file.deletingLastPathComponent()
            .appendingPathComponent(".capture-attempt-\(transaction.id)-\(id).png")
        let attempt = Transaction.Attempt(id: id, role: role, file: path, started: now)
        if transaction.active.isEmpty { transaction.role = role }
        transaction.active[id] = attempt; transaction.usedRoles.insert(role); transaction.files.insert(path)
        attemptFiles[path] = role
        refreshConnection()
        do {
            try worker(role).capture(configuration: transaction.configuration, requestID: transaction.id,
                file: path, timeout: transaction.timeout, attemptID: id, deadline: transaction.hardDeadline,
                limits: transaction.limits,
                screenshotDeadline: role.transport == "wifi" ? transaction.wifiDeadline : nil,
                pressStarted: transaction.started) { [weak self] data, exit in
                guard let self, self.pending === transaction, transaction.active[id] != nil else {
                    Self.discard(path); self?.attemptFiles.removeValue(forKey: path); return
                }
                self.attemptFiles.removeValue(forKey: path)
                self.received(data, exit: exit, transaction: transaction, attempt: attempt)
            }
            if role == .usbPrimary {
                // USB falls back early only from inside the screenshot RPC. A child stuck before
                // the RPC (re-authenticating, waiting for its lock) reports no progress at all:
                // move to Wi-Fi while there is still time inside the press cap.
                let wait = max(2.5, (transaction.limits["first_byte"] ?? 800) / 1000) + 0.3
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak transaction] in
                    guard let self, let transaction, self.pending === transaction,
                          let active = transaction.active[id], !transaction.progressed.contains(id) else { return }
                    self.fallback(transaction, attempt: active, reason: "first_byte_timeout")
                }
            }
        } catch {
            if role == .usbPrimary { fallback(transaction, attempt: attempt, reason: "worker_failed") }
            else {
                transaction.active.removeValue(forKey: id)
                recordAttempt(transaction, attempt: attempt, reason: "worker_failed")
                if transaction.active.isEmpty { finishFailure(transaction, reason: "worker_failed") }
            }
        }
    }

    private func recordAttempt(_ transaction: Transaction, attempt: Transaction.Attempt,
                               reason: String, receipt: [String: Any] = [:]) {
        var entry: [String: Any] = ["transport": attempt.role.transport, "worker_role": attempt.role.rawValue,
            "reason": reason, "elapsed_ms": max(0, (ProcessInfo.processInfo.systemUptime - attempt.started) * 1000)]
        var timings = receipt["timings_ms"] as? [String: Any] ?? [:]
        if let phase = transaction.screenshotPhases[attempt.id] {
            for (key, value) in phase.timings { timings[key] = value }
        }
        if !timings.isEmpty { entry["timings_ms"] = timings }
        transaction.attempts.append(entry)
    }

    private func hedge(_ transaction: Transaction, from attempt: Transaction.Attempt) {
        guard pending === transaction, wifiHedgingEnabled, attempt.role.transport == "wifi",
              transaction.active.count == 1,
              transaction.screenshotPhases[attempt.id]?.exempt != true,
              (transaction.wifiDeadline ?? transaction.deadline) - ProcessInfo.processInfo.systemUptime > 0,
              transaction.deadline - ProcessInfo.processInfo.systemUptime >= 0.5 else { return }
        let other: CaptureWorkerRole = attempt.role == .wifiPrimary ? .wifiStandby : .wifiPrimary
        guard !transaction.usedRoles.contains(other), let ready = workers[other],
              ready.connectionStatus.state == .ready, !ready.isBusy else { return }
        // Only missing first bytes or stopped data triggers this. A slow but advancing
        // transfer (too_slow) keeps the available Wi-Fi bandwidth to itself.
        startAttempt(transaction, role: other)
    }

    private func fallback(_ transaction: Transaction, attempt: Transaction.Attempt,
                          reason: String, receipt: [String: Any] = [:]) {
        guard pending === transaction, attempt.role == .usbPrimary,
              transaction.active.removeValue(forKey: attempt.id) != nil else { return }
        recordAttempt(transaction, attempt: attempt, reason: reason, receipt: receipt)
        if Self.fatalUSBFailures.contains(reason) { usbFatalReason = reason }
        startAttempt(transaction, role: wifiRole())
    }

    private func received(_ data: Data, exit: Int32, transaction: Transaction, attempt: Transaction.Attempt) {
        guard var value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            finishFailure(transaction, reason: "capture_integrity_failed"); return
        }
        if ProcessInfo.processInfo.systemUptime >= transaction.deadline {
            finishFailure(transaction, reason: "timeout"); return
        }
        if exit != 0 || value["ok"] as? Bool != true {
            let reason = value["reason"] as? String ?? "worker_failed"
            if attempt.role == .usbPrimary {
                fallback(transaction, attempt: attempt, reason: reason, receipt: value)
            } else {
                transaction.active.removeValue(forKey: attempt.id)
                recordAttempt(transaction, attempt: attempt, reason: reason, receipt: value)
                if Self.linkSafeFailures.contains(reason) { finish(transaction, value: value, exit: 1); return }
                if transaction.active.isEmpty { finish(transaction, value: value, exit: 1) }
                else { transaction.role = transaction.active.values.first!.role; refreshConnection() }
            }
            return
        }
        guard acceptScreenshotReceipt(transaction, role: attempt.role, attemptID: attempt.id, value: value) else { return }
        let path = attempt.file
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              link(path.path, transaction.file.path) == 0 else {
            finishFailure(transaction, reason: "capture_integrity_failed"); return
        }
        // CaptureReceipt verifies freshness, PNG and hash before TossApp focuses or pastes.
        transaction.active.removeValue(forKey: attempt.id)
        recordAttempt(transaction, attempt: attempt, reason: "ok", receipt: value)
        transaction.role = attempt.role
        value["transport"] = "authenticated_" + attempt.role.transport
        finish(transaction, value: value, exit: 0)
    }

    private func acceptScreenshotReceipt(_ transaction: Transaction, role: CaptureWorkerRole,
                                         attemptID: String?, value: [String: Any]) -> Bool {
        guard let phase = transaction.screenshotPhases[attemptID ?? role.rawValue] else { return true }
        guard let captured = value["capture_completed_monotonic"] as? Double, captured.isFinite,
              captured >= phase.started, captured <= ProcessInfo.processInfo.systemUptime + 0.05 else {
            finishFailure(transaction, reason: "capture_integrity_failed"); return false
        }
        guard !phase.exempt, captured > phase.deadline else { return true }
        if role == .usbPrimary, let attemptID, let active = transaction.active[attemptID] {
            fallback(transaction, attempt: active, reason: "slow_threshold", receipt: ["timings_ms": phase.timings])
        } else { finishFailure(transaction, reason: "slow_threshold", timings: phase.timings) }
        return false
    }

    // Direct Wi-Fi is still a route attempt. Keep the same bounded diagnostic
    // shape as USB/hedged receipts, including failures and a standby-only caller.
    private func addDirectRoute(to value: inout [String: Any], transaction: Transaction, exit: Int32) {
        let role: CaptureWorkerRole = wifiOnly ? .wifiStandby : .wifiPrimary
        let elapsed = max(0, (ProcessInfo.processInfo.systemUptime - transaction.started) * 1000)
        value["route_attempts"] = [["transport": "wifi", "worker_role": role.rawValue,
            "reason": exit == 0 ? "ok" : value["reason"] as? String ?? "worker_failed",
            "elapsed_ms": elapsed, "timings_ms": value["timings_ms"] as? [String: Any] ?? [:]]]
        value["route_total_ms"] = elapsed
    }

    private func finishFailure(_ transaction: Transaction, reason: String, timings: [String: Double]? = nil) {
        guard pending === transaction else { return }
        var value: [String: Any] = ["schema_version": 1, "request_id": transaction.id,
            "ok": false, "reason": reason, "transport": "authenticated_" + transaction.role.transport]
        if let timings { value["timings_ms"] = timings }
        finish(transaction, value: value, exit: 1)
    }

    private func finish(_ transaction: Transaction, value: [String: Any], exit: Int32) {
        guard pending === transaction else { return }
        pending = nil // Claim the single completion before process callbacks or target paste.
        let unfinished = Array(transaction.active.values)
        transaction.active.removeAll()
        // Retire every still-running attempt now, otherwise the next keypress sees a busy
        // child for up to 40 s and late writers can outlive the transaction.
        // On failure this includes an abandoned USB attempt still tearing down after its
        // fallback; after a success that one finishes on its own, as in v20.
        for active in unfinished {
            recordAttempt(transaction, attempt: active, reason: exit == 0 ? "hedge_lost" : value["reason"] as? String ?? "cancelled")
        }
        let retired = exit == 0 ? unfinished.map(\.role) : workers.compactMap { role, process in
            process.pendingRequestID == transaction.id ? role : nil
        }
        // At the press cap (or a slow_threshold) the Python child answers itself a moment later and keeps its
        // half-built Wi-Fi session reconnecting for the next press; killing it here made every
        // weak-link press start cold. A Wi-Fi role gets that moment (its late receipt is ignored);
        // only one still busy afterwards is retired. USB reconnects quickly and is retired at once.
        // (The direct path's backstop fires only after Python missed its own cap: retire it at once.)
        let draining = transaction.routed && exit != 0 && ["timeout", "slow_threshold"].contains(value["reason"] as? String ?? "")
            ? retired.filter { $0.transport == "wifi" } : []
        for role in retired where !draining.contains(role) {
            workers.removeValue(forKey: role)?.stop()
            cleanStoppedFiles(role: role)
        }
        for role in draining {
            guard let process = workers[role] else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.drainSeconds) { [weak self, weak process] in
                guard let self, let process, self.workers[role] === process,
                      process.pendingRequestID == transaction.id else { return }
                self.workers.removeValue(forKey: role)?.stop()
                self.cleanStoppedFiles(role: role)
                self.replenish(role)
            }
        }
        var result = value
        if transaction.routed {
            result["route_attempts"] = transaction.attempts
            result["route_total_ms"] = (ProcessInfo.processInfo.systemUptime - transaction.started) * 1000
        } else { addDirectRoute(to: &result, transaction: transaction, exit: exit) }
        for file in transaction.files { Self.discard(file) }
        if !transaction.routed {
            let files = transaction.files
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { files.forEach(Self.discard) }
        }
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
        refreshConnection()
        transaction.completion(data, exit)
        // Replenish retired roles for the next keypress without taking any screenshot. The
        // Wi-Fi primary also watches USB presence, so it comes back even with hedging off.
        for role in retired where !draining.contains(role) { replenish(role) }
    }

    private static let drainSeconds = 1.0

    private func replenish(_ role: CaptureWorkerRole) {
        guard let configuration = self.configuration else { return }
        switch role {
        case .usbPrimary: scheduleUSBRecovery()
        case .wifiPrimary:
            do { try worker(role).prepare(configuration: configuration) } catch { scheduleWiFiRecovery() }
        case .wifiStandby:
            if wifiHedgingEnabled { try? worker(role).prepare(configuration: configuration) }
        }
    }

    private static func discard(_ file: URL) {
        // Uninstall uses its descriptor-based allowlist remover after children
        // exit. Delayed capture cleanup must not follow replaced ancestors.
        guard !CaptureWorkerProcess.uninstalling else { return }
        _ = unlink(file.path)
    }

    func beginUninstall() {
        CaptureWorkerProcess.beginUninstall()
        onConnectionChange = nil; onCaptureSlow = nil; onCaptureProgress = nil
        stop()
    }

    func stopForUninstall() async throws {
        beginUninstall()
        try await CaptureWorkerProcess.drainForUninstall()
    }

    private func cleanStoppedFiles(role: CaptureWorkerRole? = nil) {
        let files = attemptFiles.filter { role == nil || $0.value == role }.map(\.key)
        for file in files { attemptFiles.removeValue(forKey: file); Self.discard(file) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { files.forEach(Self.discard) }
    }

    func stop() {
        let abandoned = pending
        pending = nil; configuration = nil; usbPresent = false; usbFatalReason = nil
        usbRetry?.cancel(); usbRetry = nil
        wifiRetry?.cancel(); wifiRetry = nil
        let previous = Array(workers.values); workers.removeAll()
        previous.forEach { $0.stop() }
        cleanStoppedFiles()
        if let abandoned {
            let files = abandoned.files
            files.forEach(Self.discard)
            // A cancellation-ignoring child is forcibly killed after 1 second.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { files.forEach(Self.discard) }
        }
        refreshConnection()
    }
}
