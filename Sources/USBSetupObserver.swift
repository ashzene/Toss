import Foundation
import Darwin
import CryptoKit
import IOKit

struct USBSetupDevice: Equatable {
    let insertion: Int
    let deviceClass: String
    let deviceHash: String
    var trusted = true
    // usbmuxd may reassign its integer IDs after reconnecting. Only an observed
    // absence ends an insertion; metadata/daemon recovery must not re-prompt.
    var key: String { deviceHash }
}

protocol USBSetupPreferences: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}
extension UserDefaults: USBSetupPreferences {}

// Oldest first. Reject the whole malformed value; never persist raw device identifiers.
final class USBSetupDismissals {
    static let key = "Toss.onboardingDismissedDeviceHashes"
    private let preferences: USBSetupPreferences
    init(preferences: USBSetupPreferences) { self.preferences = preferences }
    private static func valid(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    var hashes: [String] {
        guard let values = preferences.object(forKey: Self.key) as? [String],
              values.allSatisfy(Self.valid), Set(values).count == values.count else { return [] }
        return Array(values.suffix(32))
    }
    func remember(_ hashes: [String]) {
        var values = self.hashes
        for hash in hashes where Self.valid(hash) && !values.contains(hash) { values.append(hash) }
        preferences.set(Array(values.suffix(32)), forKey: Self.key)
    }
    func forget(_ hash: String) {
        preferences.set(hashes.filter { $0 != hash }, forKey: Self.key)
    }
}

// A blocked request stays pending. Only an actually presented automatic guide owns a snapshot.
struct USBSetupPolicy {
    private(set) var devices: [USBSetupDevice] = []
    private(set) var prompted: Set<String> = []
    private var automaticDevices: [USBSetupDevice] = []
    private let dismissals: USBSetupDismissals?

    init(dismissals: USBSetupDismissals? = nil) { self.dismissals = dismissals }

    mutating func update(_ value: [USBSetupDevice]) {
        devices = value
        prompted.formIntersection(Set(value.map(\.key)))
    }
    func pending(paired: [String: String], iPadOnly: Bool, hasPairing: Bool) -> [USBSetupDevice] {
        if iPadOnly && hasPairing { return [] }
        let dismissed = Set(dismissals?.hashes ?? [])
        return devices.filter {
            $0.trusted && (!iPadOnly || $0.deviceClass == "iPad") &&
            ["iPad", "iPhone"].contains($0.deviceClass) &&
            paired[$0.deviceClass] != $0.deviceHash && !prompted.contains($0.key) && !dismissed.contains($0.deviceHash)
        }.sorted { $0.key < $1.key }
    }
    mutating func take(paired: [String: String], iPadOnly: Bool, hasPairing: Bool,
                       blocked: Bool) -> USBSetupDevice? {
        guard !blocked else { return nil }
        let candidates = pending(paired: paired, iPadOnly: iPadOnly, hasPairing: hasPairing)
        guard let first = candidates.first else { return nil }
        // The existing guide handles the whole attached set, including its mixed-device instruction.
        prompted.formUnion(candidates.map(\.key))
        return first
    }
    mutating func markPresented() {
        automaticDevices = [] // A manual opening never records an automatic dismissal.
        prompted.formUnion(devices.map(\.key))
    }
    mutating func automaticPresented(_ candidates: [USBSetupDevice], visible: Bool) {
        automaticDevices = visible ? candidates : []
    }
    @discardableResult
    mutating func closed(terminating: Bool, completed: Bool, paired: [String: String]) -> Bool {
        defer { automaticDevices = [] }
        guard !terminating, !completed else { return false }
        let dismissed = automaticDevices.filter { paired[$0.deviceClass] != $0.deviceHash }
        guard !dismissed.isEmpty else { return false }
        dismissals?.remember(dismissed.map(\.deviceHash))
        return true
    }
    mutating func forget(_ hash: String) {
        dismissals?.forget(hash)
        prompted.remove(hash)
        automaticDevices.removeAll { $0.deviceHash == hash }
    }
}

protocol USBMuxChannel: AnyObject {
    func request(_ message: [String: Any]) throws -> [String: Any]
    func receive() throws -> [String: Any]
    func waitIndefinitely()
    func interrupt()
    func close()
}

// usbmuxd metadata and local IORegistry only. No Connect, Pair, lockdown, AMFI,
// device service, subprocess, or disk write. The listener sleeps in read() when idle.
final class USBSetupObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Toss.usb-setup", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var generation = 0
    private var listener: USBMuxChannel?
    private let changed: ([USBSetupDevice]) -> Void
    private let productSnapshot: () -> [String: String]
    private let makeSocket: () throws -> USBMuxChannel

    // Injected boundaries let tests exercise the real listener without opening a socket or IOKit.
    init(products: (() -> [String: String])? = nil,
         makeSocket: (() throws -> USBMuxChannel)? = nil,
         changed: @escaping ([USBSetupDevice]) -> Void) {
        self.changed = changed
        self.productSnapshot = products ?? Self.products
        self.makeSocket = makeSocket ?? { try MuxSocket() }
    }
    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true; generation += 1
        let token = generation
        lock.unlock()
        queue.async { [weak self] in self?.listen(token) }
    }
    func stop() {
        lock.lock(); running = false; generation += 1
        listener?.interrupt(); listener = nil
        lock.unlock()
    }
    private func active(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running && generation == token
    }
    static func fingerprint(_ serial: String) -> String {
        SHA256.hash(data: Data(serial.replacingOccurrences(of: "-", with: "").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    static func classify(product: String?) -> String? {
        guard let product else { return nil }
        return ["iPad", "iPhone"].first { product == $0 || product.hasPrefix($0 + " ") }
    }
    // Device class comes from the USB product descriptor already cached by macOS.
    // USB serial formatting differs from usbmuxd on newer devices; compare without dashes.
    private static func products() -> [String: String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [String: String] = [:]
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> String? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            }
            if let serial = property("USB Serial Number"), let kind = classify(product: property("USB Product Name")) {
                result[serial.replacingOccurrences(of: "-", with: "").lowercased()] = kind
            }
        }
        return result
    }
    private func publish(_ entries: [Int: [String: Any]], token: Int) {
        let products = productSnapshot()
        var devices: [USBSetupDevice] = []
        for (id, entry) in entries {
            guard let props = entry["Properties"] as? [String: Any], props["ConnectionType"] as? String == "USB",
                  let serial = props["SerialNumber"] as? String else { continue }
            let kind = products[serial.replacingOccurrences(of: "-", with: "").lowercased()] ?? "unknown"
            var device = USBSetupDevice(insertion: id, deviceClass: kind,
                                        deviceHash: Self.fingerprint(serial), trusted: false)
            // Preserve insertion keys even when metadata is unavailable. A transient
            // read failure must not make a dismissed device look newly inserted.
            if kind != "unknown", let socket = try? makeSocket() {
                defer { socket.close() }
                // ReadPairRecord only queries the Mac's daemon; never asks the device to trust.
                if let response = try? socket.request(["MessageType": "ReadPairRecord", "PairRecordID": serial]),
                   let record = response["PairRecordData"] as? Data,
                   let pair = try? PropertyListSerialization.propertyList(from: record, format: nil) as? [String: Any] {
                    device.trusted = pair["HostID"] is String && pair["SystemBUID"] is String && pair["DeviceCertificate"] is Data
                }
            }
            devices.append(device)
        }
        guard active(token) else { return }
        let snapshot = devices
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active(token) else { return }
            self.changed(snapshot)
        }
    }
    private func listen(_ token: Int) {
        guard active(token) else { return }
        var socket: USBMuxChannel?
        do {
            let connected = try makeSocket(); socket = connected
            lock.lock()
            if running && generation == token { listener = connected }
            lock.unlock()
            guard active(token) else { connected.close(); return }
            let response = try connected.request(["MessageType": "Listen"])
            guard (response["Number"] as? Int) == 0 else { throw MuxSocket.Failure.protocolError }
            // Subscribe first, then snapshot. Attach/detach messages queued during the
            // snapshot are applied in order; duplicate Attached events keep the same key.
            let listing = try makeSocket()
            let initial: [String: Any]
            do { initial = try listing.request(["MessageType": "ListDevices"]) }
            catch { listing.close(); throw error }
            listing.close()
            var entries: [Int: [String: Any]] = [:]
            for entry in initial["DeviceList"] as? [[String: Any]] ?? [] {
                if let id = entry["DeviceID"] as? Int { entries[id] = entry }
            }
            publish(entries, token: token)
            connected.waitIndefinitely()
            while active(token) {
                let event = try connected.receive()
                switch event["MessageType"] as? String {
                case "Attached": if let id = event["DeviceID"] as? Int { entries[id] = event }
                case "Detached": if let id = event["DeviceID"] as? Int { entries.removeValue(forKey: id) }
                case "Paired": break // a new trust record can make an existing insertion eligible
                default: continue
                }
                publish(entries, token: token)
            }
        } catch {
            // A daemon failure is not a USB detach. Preserve prompt suppression across
            // reconnects; the next successful snapshot reconciles actual removals.
        }
        lock.lock()
        if generation == token { listener = nil }
        socket?.close()
        lock.unlock()
        if active(token) { queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.listen(token) } }
    }
}

private final class MuxSocket: USBMuxChannel {
    enum Failure: Error { case transport, protocolError }
    private var descriptor: Int32
    init() throws {
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.transport }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = Array("/var/run/usbmuxd".utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let addressLength = socklen_t(address.sun_len)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, addressLength) }
        }
        if result != 0 { close(); throw Failure.transport }
    }
    deinit { close() }
    func interrupt() { if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR) } }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    func waitIndefinitely() {
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    func request(_ message: [String: Any]) throws -> [String: Any] {
        let body = try PropertyListSerialization.data(fromPropertyList: message.merging(
            ["ClientVersionString": "Toss", "ProgName": "Toss", "kLibUSBMuxVersion": 3], uniquingKeysWith: { a, _ in a }), format: .xml, options: 0)
        var packet = Data()
        for value in [UInt32(body.count + 16), 1, 8, 1] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { packet.append(contentsOf: $0) }
        }
        packet.append(body)
        try packet.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.transport }
                sent += count
            }
        }
        return try receive()
    }
    private func read(_ length: Int) throws -> Data {
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { raw in
            var received = 0
            while received < length {
                let count = Darwin.read(descriptor, raw.baseAddress!.advanced(by: received), length - received)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.transport }
                received += count
            }
        }
        return data
    }
    func receive() throws -> [String: Any] {
        let header = try read(16)
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(header[offset + $1]) << (8 * $1) }
        }
        let size = Int(word(0))
        guard size >= 16, size <= 1_048_576, word(4) == 1, word(8) == 8,
              let object = try PropertyListSerialization.propertyList(from: read(size - 16), format: nil) as? [String: Any] else { throw Failure.protocolError }
        return object
    }
}
