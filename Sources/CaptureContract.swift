import Foundation
import CryptoKit
import Darwin

enum CaptureContractError: Error { case invalid }

struct CaptureReceipt {
    let capturedAt: Double
    let expiresAt: Double
    let byteCount: Int

    static func validate(json: Data, exitCode: Int32, requestID: String, triggeredAt: Double,
                         now: Double, file: URL) throws -> CaptureReceipt {
        guard exitCode == 0, json.count < 16_384,
              let value = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              value["ok"] as? Bool == true, value["schema_version"] as? Int == 1,
              value["request_id"] as? String == requestID,
              let transport = value["transport"] as? String,
              ["authenticated_wifi", "authenticated_usb"].contains(transport),
              value["source"] as? String == "DVT_takeScreenshot",
              let width = value["width"] as? Int, let height = value["height"] as? Int,
              Self.screenDimensionsOK(width: width, height: height),
              let bytes = value["bytes"] as? Int, bytes > 0, bytes <= 40 * 1024 * 1024,
              let hash = value["sha256"] as? String,
              let started = value["request_started_monotonic"] as? Double,
              let completed = value["request_completed_monotonic"] as? Double,
              let captureStarted = value["capture_started_monotonic"] as? Double,
              let captured = value["capture_completed_monotonic"] as? Double,
              [triggeredAt, now, started, completed, captureStarted, captured].allSatisfy({ $0.isFinite }),
              started >= triggeredAt - 0.05, started <= captureStarted,
              captureStarted <= captured, captured <= completed, completed <= now + 0.05,
              // A flowing transfer may take 30 s; a completed result must still be fresh.
              captured - captureStarted <= 30, now - captured >= -0.05, now - captured <= 5,
              now - triggeredAt < 45 else { throw CaptureContractError.invalid }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CaptureContractError.invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o777 == 0o600, info.st_size == bytes,
              let data = try handle.readToEnd(), data.count == bytes,
              data.prefix(8) == Data([137,80,78,71,13,10,26,10]),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
            throw CaptureContractError.invalid
        }
        return CaptureReceipt(capturedAt: captured, expiresAt: captured + 10, byteCount: bytes)
    }

    // Same rule as Backend/capture_once.py screen_dimensions_ok: any iPad screen.
    static func screenDimensionsOK(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let short = min(width, height), long = max(width, height)
        let ratio = Double(long) / Double(short)
        return (1000...2400).contains(short) && (1400...3000).contains(long) && ratio >= 1.2 && ratio <= 1.6
    }
}
