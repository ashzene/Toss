import Foundation
import Darwin

// Runs Backend/setup_device.py. In "auto" mode the script drives every pairing
// step itself and prints one fixed result code per state change, so the user
// only acts on the iPad (Trust, Developer Mode) and never clicks "check again".
// The script never takes a screenshot.
@MainActor
final class SetupWizard {
    struct Result: Equatable {
        let code: String
        let model: String?
        let ipados: String?
        var final = true
    }

    private var process: Process?
    private var retiring: [Process] = []
    private var uninstalling = false
    private var generation: UInt64 = 0
    var isRunning: Bool { process != nil }

    func run(python: String, script: String, action: String, stateDirectory: String,
             timeout: TimeInterval = 31 * 60, progress: @escaping (Result) -> Void = { _ in },
             completion: @escaping (Result) -> Void) {
        guard !uninstalling, process == nil else { return }
        generation &+= 1
        let token = generation
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = [script, action, "--state-dir", stateDirectory]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch {
            completion(Result(code: "setup_unavailable", model: nil, ipados: nil))
            return
        }
        process = child
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { try? reader.close() }
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            var last: Result?
            // POSIX short reads deliver each progress line as soon as it is written.
            while true {
                let count = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; break }
                buffer.append(contentsOf: bytes.prefix(count))
                if buffer.count > 65_536 { break }
                while let newline = buffer.firstIndex(of: 0x0a) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard let result = Self.parse(line) else { continue }
                    last = result
                    if !result.final {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == token else { return }
                            progress(result)
                        }
                    }
                }
            }
            child.waitUntilExit()
            var result = last ?? Result(code: "setup_failed", model: nil, ipados: nil)
            if !result.final { result = Result(code: "setup_failed", model: result.model, ipados: result.ipados) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.process = nil
                completion(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.generation == token, let running = self.process, running.isRunning else { return }
            running.terminate()
        }
    }

    nonisolated static func parse(_ line: Data) -> Result? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["schema_version"] as? Int == 1, let code = object["code"] as? String,
              code.range(of: "^[a-z_]{1,40}$", options: .regularExpression) != nil else { return nil }
        // Older scripts print a single line without "final".
        return Result(code: code, model: object["model"] as? String, ipados: object["ipados"] as? String,
                      final: object["final"] as? Bool ?? true)
    }

    func cancel() {
        generation &+= 1
        retiring.removeAll { !$0.isRunning }
        if let process, process.isRunning {
            retiring.append(process)
            process.terminate()
        }
        process = nil
    }

    func stopForUninstall() async throws {
        uninstalling = true
        cancel()
        let grace = ProcessInfo.processInfo.systemUptime + 1
        while retiring.contains(where: \.isRunning) && ProcessInfo.processInfo.systemUptime < grace {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        for child in retiring where child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while retiring.contains(where: \.isRunning) && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        retiring.removeAll { !$0.isRunning }
        if !retiring.isEmpty { throw POSIXError(.EBUSY) }
    }

    // Codes that need the user to do something on the iPad; the app shows them
    // as a prompt window instead of only a status line.
    static func needsIPadAction(_ code: String) -> Bool {
        ["trust_needed", "developer_mode_needed", "developer_mode_confirm", "unlock_needed"].contains(code)
    }

    static func title(for code: String) -> String {
        switch code {
        case "trust_needed": return L("Tap Trust on Your iPad", "在 iPad 上点「信任」")
        case "developer_mode_needed": return L("Enable Developer Mode on Your iPad", "在 iPad 上打开开发者模式")
        case "developer_mode_confirm": return L("Confirm Developer Mode on Your iPad", "在 iPad 上确认开发者模式")
        case "unlock_needed": return L("Unlock Your iPad", "解锁 iPad")
        default: return L("iPad Pairing", "配对 iPad")
        }
    }

    // Shown after about 30 s of waiting for Trust, in place of the usual line (2026-10-30).
    static var trustHint: String { L("No prompt? Unplug the cable, plug it back in.", "没看到提示？拔下数据线再插上。") }
    static let trustHintAfter = 30.0

    static func message(for result: Result) -> String {
        switch result.code {
        case "ready":
            return L("Paired. Works without the cable now.", "已配对，拔掉线也能用了。")
        case "no_usb_ipad":
            return L("Plug in your iPad and unlock it.", "插上 iPad 并解锁。")
        case "multiple_usb_ipads":
            return L("Keep only one iPad plugged in.", "只插要配对的那一台 iPad。")
        case "unlock_needed":
            return L("Unlock your iPad.", "请解锁 iPad。")
        case "unsupported_ipados":
            return L("Needs iPadOS 17 or later.", "需要 iPadOS 17 或更新。")
        case "trust_needed":
            return L("Tap Trust on your iPad, enter the passcode.", "在 iPad 上点「信任」，输入密码。")
        case "developer_mode_auto":
            return L("Turning on Developer Mode; iPad restarts.", "正在打开开发者模式，iPad 会重启。")
        case "developer_mode_needed":
            return L("Turn on Developer Mode on your iPad.", "在 iPad 上打开开发者模式。")
        case "ipad_restarting":
            return L("iPad is restarting. Keep the cable in.", "iPad 正在重启，数据线别拔。")
        case "developer_mode_confirm":
            return L("On your iPad, tap Turn On, enter passcode.", "在 iPad 上点「打开」，输入密码。")
        case "pairing_wireless":
            return L("Setting up wireless pairing…", "正在建立无线配对…")
        case "preparing_image":
            return L("Preparing the iPad… about a minute.", "正在准备 iPad…约 1 分钟。")
        case "wifi_waiting":
            return L("Looking for the iPad on your Wi-Fi…", "正在 Wi-Fi 上找 iPad…")
        case "pairing_failed":
            return L("Wireless pairing failed. Click Pair again.", "无线配对没成功，再点「配对」。")
        case "wifi_unreachable":
            return L("Paired, but not on your Wi-Fi yet.", "已配对，但 Wi-Fi 上还找不到。")
        case "developer_image_failed":
            return L("Not ready for screenshots. Toss will retry.", "还不能截图，Toss 会自动重试。")
        case "setup_timeout":
            return L("Took too long. Click Pair to try again.", "等太久了，再点「配对」。")
        case "not_paired":
            return L("No iPad paired yet. Plug one in.", "还没配对 iPad，插上线就开始。")
        case "setup_unavailable":
            return L("Part of Toss is missing. Reopen Toss.", "Toss 缺了一部分，请重新打开。")
        case "cancelled":
            return L("Pairing cancelled.", "配对已取消。")
        default:
            return L("Pairing failed. Click Pair to try again.", "配对没成功，再点「配对」。")
        }
    }
}
