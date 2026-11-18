import Foundation

@main
struct PairedDeviceTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ line: Int = #line) {
            precondition(value, "PairedDevice assertion at line \(line)"); count += 1
        }
        func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        for kind in DeviceClass.allCases {
            check(DeviceClass.resolve(["device_class": kind.rawValue]) == kind)
            check(try DeviceClass.fromTargetJSON(json(["device_class": kind.rawValue])) == kind)
            check(kind.displayName == kind.rawValue)
            check(kind.captureFilename(uuid: "fixture") == kind.rawValue + "-fixture.png")
        }
        check(DeviceClass.iPad.osName == "iPadOS" && DeviceClass.iPhone.osName == "iOS")
        for (model, expected) in [("iPad14,3", DeviceClass.iPad), ("iPhone14,6", .iPhone)] {
            check(DeviceClass.resolve(["model": model]) == expected)
            check(try DeviceClass.fromTargetJSON(json(["model": model])) == expected)
        }
        for bad: Any in ["", "iphone", "IPad", "iPod", "AppleTV", "Watch", "Vision", 1, true, NSNull(), ["iPhone"]] {
            check(DeviceClass.resolve(["device_class": bad, "model": "iPad14,3"]) == nil)
            check(try DeviceClass.fromTargetJSON(json(["device_class": bad, "model": "iPhone14,6"])) == nil)
        }
        for model in ["", "iPod9,1", "AppleTV14,1", "Watch7,1", "RealityDevice14,1", "iphone14,6", "unknown"] {
            check(DeviceClass.resolve(["model": model]) == nil)
        }
        check(DeviceClass.resolve([:]) == nil)
        check(DeviceClass.resolve(["model": 123]) == nil)
        for badJSON in ["", "{", "null", "[]", "\"iPhone\"", "{}"] {
            check(DeviceClass.fromTargetJSON(Data(badJSON.utf8)) == nil)
        }

        // Startup / committed replacement / USB-only pair / forget / malformed persistence.
        var state = PairedDeviceState()
        check(state.deviceClass == nil)
        let pad = try json(["model": "iPad14,3"])
        let phone = try json(["model": "iPhone14,6", "device_class": "iPhone"])
        state.restore(targetJSON: pad, pairingRecordExists: true)
        check(state.deviceClass == .iPad)
        state.restore(targetJSON: phone, pairingRecordExists: true)
        check(state.deviceClass == .iPhone)
        state.forget(); check(state.deviceClass == nil)
        state.restore(targetJSON: phone, pairingRecordExists: false)
        check(state.deviceClass == nil)
        state.restore(targetJSON: phone, pairingRecordExists: true)
        state.restore(targetJSON: nil, pairingRecordExists: true)
        check(state.deviceClass == nil)
        state.restore(targetJSON: pad, pairingRecordExists: true)
        state.restore(targetJSON: try json(["model": "iPod9,1"]), pairingRecordExists: true)
        check(state.deviceClass == nil)
        state.restore(targetJSON: Data("broken".utf8), pairingRecordExists: true)
        check(state.deviceClass == nil)
        state.restore(targetJSON: try json(["model": "iPad14,3", "device_class": "bad"]), pairingRecordExists: true)
        check(state.deviceClass == nil)

        // Both product prefixes and legacy service scratch files keep the existing 24-hour rule.
        let now = Date(timeIntervalSince1970: 200_000)
        for name in ["iPad-old.png", "iPhone-old.png", ".capture-service-old.png", ".toss-old.tmp"] {
            let file = URL(fileURLWithPath: "/synthetic/" + name)
            check(CaptureCache.recognizes(file))
            check(CaptureCache.shouldRemove(file, modifiedAt: now.addingTimeInterval(-86_401), now: now))
            check(!CaptureCache.shouldRemove(file, modifiedAt: now.addingTimeInterval(-86_400), now: now))
            check(!CaptureCache.shouldRemove(file, modifiedAt: now.addingTimeInterval(-60), now: now))
            check(!CaptureCache.shouldRemove(file, modifiedAt: now.addingTimeInterval(1), now: now))
            check(!CaptureCache.shouldRemove(file, modifiedAt: nil, now: now))
        }
        for name in ["notes.png", "iPhone-old.jpg", "iPad-old.txt", "iPhone-old.PNG", "iPhone.png", "iPod-old.png", ".capture-service-old.txt"] {
            let file = URL(fileURLWithPath: "/synthetic/" + name)
            check(!CaptureCache.recognizes(file))
            check(!CaptureCache.shouldRemove(file, modifiedAt: now.addingTimeInterval(-100_000), now: now))
        }
        // V2 independent slots, normalized legacy reads, and one bad/missing sibling.
        let padPin: [String: Any] = ["model": "iPad14,3", "device_hash": "pad", "device_class": "iPad"]
        let phonePin: [String: Any] = ["model": "iPhone14,6", "device_hash": "phone", "device_class": "iPhone"]
        let index = try json(["schema_version": 2, "devices": ["iPad": padPin, "iPhone": phonePin]])
        var files = ["/state/target.json": index,
                     "/state/devices/iPad/target.json": try json(padPin),
                     "/state/devices/iPhone/target.json": try json(phonePin)]
        var records: Set<String> = ["/state/devices/iPad/strict-remote-pairing.plist", "/state/devices/iPhone/strict-remote-pairing.plist"]
        var two = PairedDevicesState()
        two.restore(root: "/state", read: { files[$0] }, exists: { records.contains($0) })
        check(two.classes == [.iPad, .iPhone] && two.primary == .iPad)
        check(two.directories[.iPad] == "/state/devices/iPad")
        check(two.directories[.iPhone] == "/state/devices/iPhone")
        two.forget(.iPad); check(two.classes == [.iPhone] && two.primary == .iPhone)
        two.restore(root: "/state", read: { files[$0] }, exists: { records.contains($0) })
        two.forget(.iPhone); check(two.classes == [.iPad] && two.primary == .iPad)
        records.remove("/state/devices/iPhone/strict-remote-pairing.plist")
        two.restore(root: "/state", read: { files[$0] }, exists: { records.contains($0) })
        check(two.classes == [.iPad])
        records.insert("/state/devices/iPhone/strict-remote-pairing.plist")
        files["/state/devices/iPhone/target.json"] = try json(padPin)
        two.restore(root: "/state", read: { files[$0] }, exists: { records.contains($0) })
        check(two.classes == [.iPad])
        for bad: Any in [true, 1, 2.5, "2", NSNull()] {
            files["/state/target.json"] = try json(["schema_version": bad, "devices": ["iPad": padPin]])
            two.restore(root: "/state", read: { files[$0] }, exists: { records.contains($0) })
            check(two.classes.isEmpty)
        }
        for kind in DeviceClass.allCases {
            files = ["/state/target.json": try json(["model": kind.rawValue + "14,3", "device_hash": "legacy"])]
            two.restore(root: "/state", read: { files[$0] }, exists: { $0 == "/state/strict-remote-pairing.plist" })
            check(two.classes == [kind] && two.primary == kind)
            check(two.directories[kind] == "/state")
        }
        two.forget(); check(two.classes.isEmpty)
        print("PairedDevice and cache: \(count) pure assertions passed; no real state, file deletion or device access.")
    }
}
