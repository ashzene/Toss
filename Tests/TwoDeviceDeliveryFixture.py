"""Use actual App delivery/retarget methods; replace only external effects with recorders."""
from pathlib import Path
import re
import sys

source_path, destination = map(Path, sys.argv[1:])
source = source_path.read_text()
methods = []
for name in ("retargetCapture", "deliverCaptureResult", "discardEarlyCapture"):
    pattern = r"^    private func " + name + r"\(.*?^    \}"
    matches = list(re.finditer(pattern, source, re.M | re.S))
    if len(matches) != 1:
        raise SystemExit("Expected one actual method: " + name)
    methods.append(matches[0].group().replace("private func", "func", 1))
    print("Extracted actual TossApp method:", name)

destination.write_text('''import Foundation
@MainActor
final class TwoDeviceDeliveryFixture {
    struct Transaction {
        let id: UInt64
        let uuid: String
        let image: URL
        let deviceClass: DeviceClass
        let kind: String
        let lease: String
        var receipt: Int?
        var pastePosted = false
        var clipboard: Int?
        var destinationChanged = false
    }
    struct EarlyCapture {
        let id: UInt64
        let uuid: String
        let image: URL
        let deviceClass: DeviceClass
        var result: (data: Data, exitCode: Int32)?
    }
    final class Removals {
        var paths: [URL] = []
        func removeItem(at path: URL) throws { paths.append(path) }
    }
    let fm = Removals()
    var core = DualHotkeyCore(tapSelectionEnabled: true)
    var uninstalling = false
    var transaction: Transaction?
    var earlyCapture: EarlyCapture?
    var abandonedCaptureIDs: [DeviceClass: String] = [:]
    var earlyTargetFailure: Int?
    func finishTargetlessCapture() {}
    func selectionDeadline(pressedAt: Double) -> Double { core.selectionDeadline(pressedAt: pressedAt) }
    var slowCaptureID: String?
    var backendTimings: [String: Double] = [:]
    var connectionReused: Bool?
    var delivered: [(String, String, Int32)] = []
    var captures: [String] = []
    var errors = 0
    func configuration() throws -> String { "synthetic" }
    func startEarlyCapture(_ request: HotkeyRequest, config: String) {
        captures.append("iPhone")
        earlyCapture = EarlyCapture(id: request.id, uuid: "phone", image: URL(fileURLWithPath: "/synthetic/phone.png"), deviceClass: .iPhone)
    }
    func beginCapture(_ request: HotkeyRequest, kind: String, config: String, lease: String) throws {
        guard let early = earlyCapture else { preconditionFailure("No new capture") }
        earlyCapture = nil
        transaction = Transaction(id: request.id, uuid: early.uuid, image: early.image, deviceClass: early.deviceClass, kind: kind, lease: lease)
    }
    func captureSetupFailed(_ request: HotkeyRequest, _ error: Error) { errors += 1 }
    func captureReturned(_ request: HotkeyRequest, data: Data, exitCode: Int32) {
        guard let tx = transaction else { preconditionFailure("No transaction") }
        transaction?.receipt = 1
        delivered.append((tx.uuid, tx.lease, exitCode))
    }
    func finishEarlyCaptureFailure(_ request: HotkeyRequest, data: Data, exitCode: Int32) -> Bool {
        if exitCode != 0 { errors += 1; return true }
        return false
    }
    func begin(dual: Bool = true, hasLease: Bool = true) -> HotkeyRequest {
        let now = ProcessInfo.processInfo.systemUptime
        core.hasSecondaryDevice = dual
        _ = core.observe(ModifierSnapshot(), at: now - 1)
        let actions = core.observe(ModifierSnapshot(leftOption: true, rightOption: true), at: now)
        guard case .capture(let request) = actions.first else { preconditionFailure("No capture") }
        _ = core.observe(ModifierSnapshot(), at: now)
        let image = URL(fileURLWithPath: "/synthetic/pad.png")
        if hasLease {
            transaction = Transaction(id: request.id, uuid: "pad", image: image, deviceClass: .iPad, kind: "Codex", lease: "original-conversation")
        } else {
            earlyCapture = EarlyCapture(id: request.id, uuid: "pad", image: image, deviceClass: .iPad)
        }
        return request
    }
    func second() -> HotkeyRequest {
        let actions = core.observe(ModifierSnapshot(leftOption: true, rightOption: true), at: ProcessInfo.processInfo.systemUptime)
        guard case .retarget(let request) = actions.last else { preconditionFailure("No retarget") }
        retargetCapture(request)
        _ = core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime)
        return request
    }
''' + '\n'.join(methods) + '\n}\n')
