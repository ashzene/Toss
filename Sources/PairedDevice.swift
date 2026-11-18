import Foundation
import CoreFoundation

// Shared setup/target.json contract. Product names are intentionally not localized.
enum DeviceClass: String, CaseIterable, Sendable {
    case iPad, iPhone

    var displayName: String { rawValue }
    var osName: String { self == .iPad ? "iPadOS" : "iOS" }

    // Only a MISSING device_class may use the legacy ProductType fallback.
    // An explicit unknown value (including null or a non-string) stays unsupported.
    static func resolve(_ metadata: [String: Any]) -> Self? {
        if let value = metadata["device_class"] {
            return (value as? String).flatMap(Self.init(rawValue:))
        }
        guard let model = metadata["model"] as? String else { return nil }
        return allCases.first { model.hasPrefix($0.rawValue) }
    }

    static func fromTargetJSON(_ data: Data) -> Self? {
        guard let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return resolve(metadata)
    }

    func captureFilename(uuid: String) -> String { "\(rawValue)-\(uuid).png" }
}

// Pure pairing state: progress alone cannot replace the persisted paired device.
struct PairedDeviceState: Equatable {
    private(set) var deviceClass: DeviceClass?

    mutating func restore(targetJSON: Data?, pairingRecordExists: Bool) {
        deviceClass = pairingRecordExists ? targetJSON.flatMap(DeviceClass.fromTargetJSON) : nil
    }

    mutating func forget() { deviceClass = nil }
}

// V2 index plus independent credentials. Legacy files remain readable without a write.
struct PairedDevicesState: Equatable {
    private(set) var directories: [DeviceClass: String] = [:]
    var classes: Set<DeviceClass> { Set(directories.keys) }
    var primary: DeviceClass? { classes.contains(.iPad) ? .iPad : classes.first }

    mutating func restore(root: String, read: (String) -> Data?, exists: (String) -> Bool) {
        directories = [:]
        guard let data = read(root + "/target.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if object["schema_version"] == nil {
            if let kind = DeviceClass.resolve(object), exists(root + "/strict-remote-pairing.plist") {
                directories[kind] = root
            }
            return
        }
        guard let version = object["schema_version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 2, version.doubleValue == 2,
              let devices = object["devices"] as? [String: Any],
              Set(devices.keys).isSubset(of: Set(DeviceClass.allCases.map(\.rawValue))) else { return }
        for (name, value) in devices {
            guard let kind = DeviceClass(rawValue: name), let pin = value as? [String: Any],
                  DeviceClass.resolve(pin) == kind,
                  let model = pin["model"] as? String, model.hasPrefix(name),
                  let hash = pin["device_hash"] as? String else { continue }
            let directory = root + "/devices/" + name
            guard exists(directory + "/strict-remote-pairing.plist"),
                  let childData = read(directory + "/target.json"),
                  let child = try? JSONSerialization.jsonObject(with: childData) as? [String: Any],
                  DeviceClass.resolve(child) == kind, child["model"] as? String == model,
                  child["device_hash"] as? String == hash else { continue }
            directories[kind] = directory
        }
    }

    mutating func forget(_ kind: DeviceClass? = nil) {
        if let kind { directories.removeValue(forKey: kind) } else { directories = [:] }
    }
}

enum CaptureCache {
    static func recognizes(_ file: URL) -> Bool {
        let name = file.lastPathComponent
        let png = file.pathExtension == "png" &&
            (DeviceClass.allCases.contains { name.hasPrefix($0.rawValue + "-") } || name.hasPrefix(".capture-service-"))
        return png || name.hasPrefix(".toss-")
    }

    static func shouldRemove(_ file: URL, modifiedAt: Date?, now: Date) -> Bool {
        guard recognizes(file), let modifiedAt else { return false }
        return now.timeIntervalSince(modifiedAt) > 86_400
    }
}
