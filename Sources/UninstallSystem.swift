import AppKit
import Darwin

// Only the confirmed app action calls these adapters. Offline tests supply
// their own Actions and never invoke TCC, Finder, SMAppService or recycling.
enum UninstallSystem {
    enum SystemError: Error { case permissionResetFailed, recycleFailed, notAnApp }

    @MainActor static func clearDomain(_ domain: String) throws {
        try UninstallPreferences.clearDomain(domain, in: UserDefaults.standard)
    }

    static func resetPermission(_ service: String, domain: String) async throws {
        precondition(UninstallPolicy.permissionServices.contains(service) && domain == UninstallPolicy.domain)
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, domain]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
            let killDeadline = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { usleep(10_000) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            let exitDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < exitDeadline { usleep(20_000) }
            guard !process.isRunning, process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw SystemError.permissionResetFailed
            }
        }.value
    }

    @MainActor static func recycle(_ app: URL) async throws {
        guard app.isFileURL, app.pathExtension == "app", app == Bundle.main.bundleURL else { throw SystemError.notAnApp }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([app]) { moved, error in
                if let error { continuation.resume(throwing: error) }
                else if moved[app] != nil { continuation.resume() }
                else { continuation.resume(throwing: SystemError.recycleFailed) }
            }
        }
    }
}
