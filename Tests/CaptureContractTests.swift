import Foundation
import CryptoKit
import Darwin

// Contract-only tests: the byte fixture has a PNG signature but is deliberately
// not a decodable PNG. This suite checks declarations, freshness, file metadata
// and SHA256. Actual PNG decoding is tested in Backend/tests/test_capture_once.py.
// No app, Accessibility, clipboard, keyboard event, device or network is used.
@main
struct CaptureContractTests {
    static var assertions = 0

    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("ipad-capture-contract-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fresh.png")
        let bytes = Data([137,80,78,71,13,10,26,10]) + Data("synthetic-contract-fixture-not-a-real-png".utf8)
        try bytes.write(to: file)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let request = "00000000-0000-4000-8000-000000000001"
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let base: [String: Any] = [
            "ok": true, "schema_version": 1, "request_id": request,
            "transport": "authenticated_wifi", "source": "DVT_takeScreenshot",
            "width": 1668, "height": 2388, "bytes": bytes.count, "sha256": hash,
            "request_started_monotonic": 198.2,
            "capture_started_monotonic": 198.5,
            "capture_completed_monotonic": 199.0,
            "request_completed_monotonic": 199.1,
        ]
        func validate(_ value: [String: Any] = base, exit: Int32 = 0,
                      id: String = request, triggered: Double = 198.0,
                      now: Double = 200.0, at: URL = file) throws -> CaptureReceipt {
            try CaptureReceipt.validate(json: JSONSerialization.data(withJSONObject: value),
                                        exitCode: exit, requestID: id, triggeredAt: triggered,
                                        now: now, file: at)
        }
        func changed(_ fields: [String: Any]) -> [String: Any] {
            base.merging(fields) { _, new in new }
        }
        let receipt = try validate()
        expect(receipt.capturedAt == 199.0 && receipt.expiresAt == 209.0)
        let landscape = try validate(changed(["width": 2388, "height": 1668]))
        expect(landscape.capturedAt == 199.0)
        expect(try validate(changed(["transport": "authenticated_usb"])).capturedAt == 199.0)
        expectThrows { try validate(changed(["transport": "authenticated_usb", "sha256": "wrong"])) }

        expectThrows { try validate(id: "00000000-0000-4000-8000-000000000002") }
        expectThrows { try validate(changed(["request_id": request.uppercased() + "different"])) }
        expectThrows { try validate(exit: 1) }
        expectThrows { try validate(changed(["ok": false])) }
        expectThrows { try validate(changed(["schema_version": 2])) }
        expectThrows { try validate(changed(["transport": "USB"])) }
        expectThrows { try validate(changed(["source": "cached_png"])) }
        expectThrows { try validate(changed(["width": 1000])) }
        expectThrows { try validate(changed(["height": 1668])) }
        _ = try validate(changed(["width": 2064, "height": 2752]))   // iPad Pro 13"
        _ = try validate(changed(["width": 2266, "height": 1488]))   // iPad mini, landscape
        expectThrows { try validate(changed(["width": 1179, "height": 2556])) }   // iPhone-shaped
        expectThrows { try validate(changed(["bytes": bytes.count + 1])) }
        expectThrows { try validate(changed(["bytes": 40 * 1024 * 1024 + 1])) }
        expectThrows { try validate(changed(["sha256": String(repeating: "0", count: 64)])) }
        expectThrows { try validate(changed(["sha256": hash.uppercased()])) }
        expectThrows { try validate(changed(["sha256": "short"])) }

        // A backend that completed earlier cannot renew freshness on UI delivery.
        expectThrows { try validate(now: 205.01) }
        expectThrows { try validate(now: 197.0) }
        expectThrows { try validate(changed(["request_started_monotonic": 197.0])) }
        expectThrows { try validate(changed(["capture_started_monotonic": 197.5])) }
        expectThrows { try validate(changed(["capture_completed_monotonic": 198.4])) }
        expectThrows { try validate(changed(["request_completed_monotonic": 198.9])) }
        expectThrows { try validate(changed(["request_completed_monotonic": 201.0])) }
        expectThrows { try validate(changed(["capture_started_monotonic": 198.3,
                                           "capture_completed_monotonic": 207.0,
                                           "request_completed_monotonic": 207.1]), now: 207.2) }
        expectThrows { try validate(triggered: 150.0) }
        expectThrows { try validate(now: .infinity) }
        expectThrows { try validate(triggered: .nan) }

        let symlink = directory.appendingPathComponent("symlink.png")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: file)
        expectThrows { try validate(at: symlink) }
        expectThrows { try validate(at: directory.appendingPathComponent("missing.png")) }
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        expectThrows { try validate() }
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        expectThrows { try validate() }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        expect(try validate().capturedAt == 199.0)

        // A changed file is rejected even if backend JSON/hash is unchanged.
        try (bytes + Data([0])).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        expectThrows { try validate() }
        print("Capture contract: \(assertions) pure assertions passed; no UI/device access. PNG decoding is not tested by this Swift fixture.")
    }

    static func expect(_ condition: Bool) {
        assertions += 1
        precondition(condition, "Contract assertion failed")
    }

    static func expectThrows(_ body: () throws -> CaptureReceipt) {
        assertions += 1
        do {
            _ = try body()
            preconditionFailure("Expected contract rejection")
        } catch CaptureContractError.invalid {
            // Expected fail-closed response.
        } catch {
            preconditionFailure("Unexpected test error: \(error)")
        }
    }
}
