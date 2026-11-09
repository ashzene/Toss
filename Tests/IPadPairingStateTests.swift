import Foundation

@main enum IPadPairingStateTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("toss-pairing-layout-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = root.appendingPathComponent("devices")
        let state = parent.appendingPathComponent("iPad")
        let pin: [String: Any] = ["model": "iPad14,3", "device_hash": "synthetic-ipad"]
        var checks = 0
        func check(_ condition: Bool) { precondition(condition, "check \(checks + 1) failed"); checks += 1 }
        func write(_ value: [String: Any], to path: URL) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: path, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        let index = root.appendingPathComponent("target.json")
        let target = state.appendingPathComponent("target.json")
        let keys = state.appendingPathComponent("strict-remote-pairing.plist")
        let registered = pin.merging(["device_class": "iPad"]) { _, b in b }
        let valid: [String: Any] = ["schema_version": 2, "devices": ["iPad": registered]]
        check(IPadPairingState.existingDirectory(in: root) == nil) // Fresh setup keeps the root.
        try write(pin, to: index)
        check(IPadPairingState.existingDirectory(in: root) == nil) // Legacy pair also keeps the root.
        for dir in [parent, state] { try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try write(valid, to: index); try write(pin, to: target)
        try Data("synthetic-credentials".utf8).write(to: keys)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keys.path)
        let original = try Data(contentsOf: index)
        check(IPadPairingState.existingDirectory(in: root)?.path == state.path)
        check(try Data(contentsOf: index) == original)
        try write(["schema_version": 2, "devices": ["iPad": registered, "iPhone": ["model": "iPhone15,5", "device_hash": "synthetic-phone", "device_class": "iPhone"]]], to: index)
        check(IPadPairingState.existingDirectory(in: root)?.path == state.path)
        try write(["schema_version": 2, "devices": ["iPhone": registered]], to: index)
        check(IPadPairingState.existingDirectory(in: root) == nil)
        try write(["schema_version": true, "devices": ["iPad": registered]], to: index)
        check(IPadPairingState.existingDirectory(in: root) == nil)
        try write(valid, to: index)
        for bad in [pin.merging(["device_hash": "different"]) { _, b in b },
                    pin.merging(["model": "iPad14,4"]) { _, b in b },
                    pin.merging(["device_class": "iPhone"]) { _, b in b }] {
            try write(bad, to: target)
            check(IPadPairingState.existingDirectory(in: root) == nil)
        }
        try write(pin, to: target)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keys.path)
        check(IPadPairingState.existingDirectory(in: root) == nil)
        try fm.removeItem(at: keys)
        check(IPadPairingState.existingDirectory(in: root) == nil)
        try fm.createSymbolicLink(at: keys, withDestinationURL: target)
        check(IPadPairingState.existingDirectory(in: root) == nil)
        try fm.removeItem(at: keys)
        try Data("synthetic-credentials".utf8).write(to: keys)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keys.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        check(IPadPairingState.existingDirectory(in: root) == nil)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let moved = root.appendingPathComponent("real-devices")
        try fm.moveItem(at: parent, to: moved)
        try fm.createSymbolicLink(at: parent, withDestinationURL: moved)
        check(IPadPairingState.existingDirectory(in: root) == nil)
        print("iPad pairing layout: \(checks) synthetic checks passed; no real pairing read or changed.")
    }
}
