import Foundation

// Reuse an existing iPad pair when switching back from the dual-device edition.
// This is a read-only lookup: leave its shared index and both devices untouched.
enum IPadPairingState {
    static func existingDirectory(in root: URL) -> URL? {
        guard isPrivate(root, type: .typeDirectory),
              let index = object(at: root.appendingPathComponent("target.json")),
              let version = index["schema_version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 2,
              let devices = index["devices"] as? [String: Any],
              Set(devices.keys).isSubset(of: ["iPad", "iPhone"]),
              let registered = devices["iPad"] as? [String: Any], isIPad(registered) else { return nil }
        let parent = root.appendingPathComponent("devices", isDirectory: true)
        let state = parent.appendingPathComponent("iPad", isDirectory: true)
        guard isPrivate(parent, type: .typeDirectory), isPrivate(state, type: .typeDirectory),
              let pin = object(at: state.appendingPathComponent("target.json")), isIPad(pin),
              pin["device_hash"] as? String == registered["device_hash"] as? String,
              pin["model"] as? String == registered["model"] as? String,
              isPrivate(state.appendingPathComponent("strict-remote-pairing.plist"), type: .typeRegular) else { return nil }
        return state
    }

    private static func isIPad(_ pin: [String: Any]) -> Bool {
        guard let model = pin["model"] as? String, model.hasPrefix("iPad"),
              let hash = pin["device_hash"] as? String, !hash.isEmpty else { return false }
        return pin["device_class"] == nil || pin["device_class"] as? String == "iPad"
    }

    private static func object(at path: URL) -> [String: Any]? {
        guard isPrivate(path, type: .typeRegular),
              let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size]) as? NSNumber,
              size.intValue <= 65_536,
              let data = try? Data(contentsOf: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func isPrivate(_ path: URL, type: FileAttributeType) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              attrs[.type] as? FileAttributeType == type,
              let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
              let mode = attrs[.posixPermissions] as? NSNumber else { return false }
        return mode.intValue & 0o077 == 0
    }
}
