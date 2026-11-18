import Foundation

@main
@MainActor
enum TwoDeviceDeliveryTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); count += 1
    }
    static func main() async throws {
        let pad = URL(fileURLWithPath: "/synthetic/pad.png")
        let phone = URL(fileURLWithPath: "/synthetic/phone.png")
        let frame = Data("synthetic-frame".utf8)
        // Fast success and fast failure are both provisional; only the phone reaches delivery.
        for exitCode: Int32 in [0, 1] {
            let fixture = TwoDeviceDeliveryFixture()
            let first = fixture.begin()
            fixture.transaction?.destinationChanged = true
            fixture.deliverCaptureResult(first, uuid: "pad", image: pad, data: frame, exitCode: exitCode)
            check(fixture.delivered.isEmpty && fixture.errors == 0, "Fast iPad result must wait")
            let second = fixture.second()
            check(second.id == first.id && second.startedAt == first.startedAt, "Retarget preserves operation identity")
            check(fixture.transaction?.lease == "original-conversation", "Retarget must never relocalize into another chat")
            check(fixture.transaction?.kind == "Codex", "Retarget cannot switch apps")
            check(fixture.transaction?.destinationChanged == true, "Preserve previous manual-paste decision")
            check(fixture.transaction?.deviceClass == .iPhone && fixture.captures == ["iPhone"], "Exactly one new phone capture")
            check(fixture.fm.paths.contains(pad), "Old private file removed")
            fixture.deliverCaptureResult(second, uuid: "phone", image: phone, data: frame, exitCode: 0)
            check(fixture.delivered.count == 1 && fixture.delivered[0].0 == "phone", "Phone does not wait out original window")
            fixture.deliverCaptureResult(first, uuid: "pad", image: pad, data: frame, exitCode: exitCode)
            check(fixture.delivered.count == 1, "Late original response cannot deliver")
            try await Task.sleep(nanoseconds: 520_000_000)
            check(fixture.delivered.count == 1 && fixture.errors == 0, "Scheduled old callback also cannot deliver/fail")
            check(fixture.transaction?.uuid == "phone", "Old callback cannot clean up new transaction")
        }
        do {
            let fixture = TwoDeviceDeliveryFixture()
            let first = fixture.begin()
            fixture.deliverCaptureResult(first, uuid: "pad", image: pad, data: frame, exitCode: 0)
            check(fixture.delivered.isEmpty, "Single fast iPad remains provisional")
            try await Task.sleep(nanoseconds: 520_000_000)
            check(fixture.delivered.count == 1 && fixture.delivered[0].0 == "pad", "Window expiry commits single result")
            fixture.deliverCaptureResult(first, uuid: "pad", image: pad, data: frame, exitCode: 0)
            check(fixture.delivered.count == 1, "Duplicate callback cannot deliver twice")
        }
        do {
            let fixture = TwoDeviceDeliveryFixture()
            let first = fixture.begin(dual: false)
            fixture.deliverCaptureResult(first, uuid: "pad", image: pad, data: frame, exitCode: 0)
            check(fixture.delivered.count == 1, "Only device has no selection delay")
        }
        do {
            let fixture = TwoDeviceDeliveryFixture()
            let first = fixture.begin(hasLease: false)
            fixture.deliverCaptureResult(first, uuid: "pad", image: pad, data: frame, exitCode: 1)
            let second = fixture.second()
            check(fixture.earlyCapture?.deviceClass == .iPhone && fixture.transaction == nil, "Activation in progress is retained while screenshot switches")
            fixture.deliverCaptureResult(second, uuid: "phone", image: phone, data: frame, exitCode: 0)
            try await Task.sleep(nanoseconds: 520_000_000)
            check(fixture.errors == 0 && fixture.earlyCapture?.uuid == "phone", "Early stale failure cannot abort phone activation")
            check(fixture.earlyCapture?.result?.data == frame, "Phone result waits for original activation")
        }
        do {
            let fixture = TwoDeviceDeliveryFixture()
            let first = fixture.begin()
            fixture.deliverCaptureResult(first, uuid: "pad", image: pad, data: frame, exitCode: 0)
            _ = fixture.core.reset()
            fixture.transaction = nil
            try await Task.sleep(nanoseconds: 520_000_000)
            check(fixture.delivered.isEmpty && fixture.fm.paths.contains(pad), "Cancel before commit drops result")
        }
        do {
            let fixture = TwoDeviceDeliveryFixture()
            let first = fixture.begin()
            let image = fixture.transaction!.image
            fixture.uninstalling = true
            fixture.transaction = nil
            fixture.deliverCaptureResult(first, uuid: "pad", image: image, data: Data(), exitCode: 0)
            check(fixture.delivered.isEmpty && fixture.fm.paths.isEmpty,
                  "Late delivery during uninstall neither delivers nor removes files")
        }
        print("Actual two-device App delivery methods: \(count) checks passed; effects recorded, no App launched.")
    }
}
