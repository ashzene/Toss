import Foundation
import Darwin

// Wakes the iPad's Wi-Fi before a screenshot request reaches it. An idle iPad
// radio dozes between beacons: on 2026-10-22 the first ping after ~2 s of
// silence took 150-320 ms, against ~7 ms while traffic was flowing. From the
// first key of a possible chord, a short burst of 1-byte UDP datagrams to the
// iPad's discard port keeps the radio awake until the request is on its way.
// The address is the worker's last authenticated endpoint hint, checked like
// remote_pairing_transport.load_endpoint_hint; on any doubt nothing is sent.

// Burst bookkeeping in monotonic seconds; no I/O.
struct WakeBurst {
    static let duration = 0.6
    static let interval = 0.04
    private(set) var deadline: Double?

    // True when a new burst should start now; a running burst is only extended.
    mutating func poke(at now: Double) -> Bool {
        let running = deadline.map { now < $0 } ?? false
        deadline = now + Self.duration
        return !running
    }

    // Called on every send tick; false, and idle again, once the deadline passed.
    mutating func shouldSend(at now: Double) -> Bool {
        guard let deadline, now < deadline else {
            self.deadline = nil
            return false
        }
        return true
    }
}

// Keepalive (2026-10-24, "Toss will be sent to other people"; robustness can't depend on
// sitting next to the router): while Toss is connected and the Mac is in use, one 1-byte
// datagram every 0.3 s keeps the iPad's radio out of power save between keypresses.
// Measured on a 2.4 GHz home link: ping after 2 s idle p50 35.6 / p95 299 ms without,
// 19.6 / 81 ms with. Cost: 12,000 datagrams (about 0.76 MB on air incl. headers) per active
// hour, none while idle, asleep or disconnected. Pure policy; the reason is logged.
enum KeepAlivePolicy {
    static let interval = 0.3
    static let defaultIdleMinutes = 10.0
    static let switchKey = "iPadKeepAlive"            // Bool, default on: the kill switch
    static let minutesKey = "iPadKeepAliveMinutes"    // Double, default 10

    static func state(switchOn: Bool, enabled: Bool, connected: Bool, secondsSinceInput: Double,
                      idleMinutes: Double, screensAsleep: Bool) -> String {
        if !switchOn { return "off-switch" }
        if !enabled { return "off-disabled" }
        if !connected { return "off-disconnected" }
        if screensAsleep { return "off-display-asleep" }
        let limit = idleMinutes.isFinite && idleMinutes > 0 ? idleMinutes : defaultIdleMinutes
        if !(secondsSinceInput.isFinite && secondsSinceInput >= 0 && secondsSinceInput < limit * 60) { return "off-idle" }
        return "on"
    }
}

struct WakeEndpoint: Equatable {
    let family: Int32 // AF_INET or AF_INET6
    let address: [UInt8] // 4 or 16 bytes, network order
    let scope: UInt32 // IPv6 link-local only
    let interfaceIndex: UInt32

    // endpoint-hint.json: {"ip", "port", "interface"} from save_endpoint_hint.
    // Private IPv4 (10/8, 172.16/12, 192.168/16) or IPv6 link-local/ULA, on an
    // existing en* interface. Anything else is not an iPad on this LAN.
    static func parse(hint data: Data,
                      interfaceIndex: (String) -> UInt32 = { if_nametoindex($0) }) -> WakeEndpoint? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = value["ip"] as? String, let port = value["port"] as? Int, (1...65535).contains(port),
              let interface = value["interface"] as? String,
              interface.range(of: "^en[0-9]{1,3}$", options: .regularExpression) != nil else { return nil }
        let index = interfaceIndex(interface)
        guard index != 0 else { return nil }
        let host = String(ip.split(separator: "%", maxSplits: 1).first ?? "")
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            let isPrivate = bytes[0] == 10 || (bytes[0] == 172 && bytes[1] & 0xF0 == 16)
                || (bytes[0] == 192 && bytes[1] == 168)
            return isPrivate ? WakeEndpoint(family: AF_INET, address: bytes, scope: 0, interfaceIndex: index) : nil
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 {
            return WakeEndpoint(family: AF_INET6, address: bytes, scope: index, interfaceIndex: index)
        }
        if bytes[0] & 0xFE == 0xFC {
            return WakeEndpoint(family: AF_INET6, address: bytes, scope: 0, interfaceIndex: index)
        }
        return nil
    }
}

// Same file rules as load_endpoint_hint: a regular file owned by this user,
// mode 600, at most 512 bytes. The modification date says when to re-read it.
struct WakeHintFile {
    struct Stamp: Equatable {
        let device: dev_t, inode: ino_t, size: off_t, seconds: Int, nanoseconds: Int
    }

    static func read(_ path: String) -> (stamp: Stamp, data: Data)? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 512 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(descriptor, &buffer, buffer.count) == buffer.count else { return nil }
        let stamp = Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                          seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
        return (stamp, Data(buffer))
    }

    static func stamp(_ path: String) -> Stamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                     seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
}

extension ModifierSnapshot {
    // One of the four chord keys went down while nothing else is held: the
    // first key of a possible both-Option or both-Shift chord.
    func startsChord(after previous: ModifierSnapshot) -> Bool {
        let now = [leftOption, rightOption, leftShift, rightShift]
        let before = [previous.leftOption, previous.rightOption, previous.leftShift, previous.rightShift]
        guard now.filter({ $0 }).count == 1, !control, !command, !function, !ordinaryKey else { return false }
        return zip(now, before).contains { $0 && !$1 }
    }
}

// All state lives on one serial queue; poke() and useStateDirectory() only
// enqueue work, so the caller (the main thread) never waits on file or socket I/O.
final class IPadWaker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Toss.ipad-waker", qos: .userInteractive)
    private var burst = WakeBurst()
    private var timer: DispatchSourceTimer?
    private var hintPath: String?
    private var cached: (stamp: WakeHintFile.Stamp, endpoint: WakeEndpoint?)?
    private var socketDescriptor: Int32 = -1
    private var socketEndpoint: (family: Int32, interfaceIndex: UInt32)?
    private var keepAliveTimer: DispatchSourceTimer?
    private var keepAliveSent = 0
    private var uninstalling = false

    func stopForUninstall() {
        queue.sync {
            uninstalling = true
            timer?.cancel(); timer = nil
            keepAliveTimer?.cancel(); keepAliveTimer = nil
            hintPath = nil; cached = nil
            if socketDescriptor >= 0 { close(socketDescriptor); socketDescriptor = -1 }
        }
    }

    deinit {
        timer?.cancel()
        keepAliveTimer?.cancel()
        if socketDescriptor >= 0 { close(socketDescriptor) }
    }

    func useStateDirectory(_ path: String) {
        queue.async { [self] in
            let hint = (path as NSString).appendingPathComponent("endpoint-hint.json")
            if hint != hintPath { hintPath = hint; cached = nil }
        }
    }

    func poke() {
        queue.async { [self] in
            guard !uninstalling else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard burst.poke(at: now) || timer == nil else { return } // Extended the running burst.
            guard let endpoint = currentEndpoint() else {
                burst = WakeBurst()
                return
            }
            send(to: endpoint)
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + WakeBurst.interval, repeating: WakeBurst.interval,
                            leeway: .milliseconds(5))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    // Starts or stops the steady keepalive (see KeepAlivePolicy). Never blocks the caller.
    func setKeepAlive(_ on: Bool) {
        queue.async { [self] in
            guard !uninstalling else { return }
            if !on {
                keepAliveTimer?.cancel()
                keepAliveTimer = nil
                return
            }
            guard keepAliveTimer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: KeepAlivePolicy.interval, leeway: .milliseconds(20))
            source.setEventHandler { [weak self] in
                guard let self, self.timer == nil, let endpoint = self.currentEndpoint() else { return } // a burst is already sending
                self.send(to: endpoint)
                self.keepAliveSent &+= 1
            }
            keepAliveTimer = source
            source.resume()
        }
    }

    // Datagrams sent by the keepalive since launch (diagnostics only).
    var keepAliveCount: Int { queue.sync { keepAliveSent } }

    private func tick() {
        guard burst.shouldSend(at: ProcessInfo.processInfo.systemUptime),
              let endpoint = cached?.endpoint else {
            timer?.cancel()
            timer = nil
            return
        }
        send(to: endpoint)
    }

    private func currentEndpoint() -> WakeEndpoint? {
        guard let hintPath, let stamp = WakeHintFile.stamp(hintPath) else { return nil }
        if let cached, cached.stamp == stamp { return cached.endpoint }
        guard let file = WakeHintFile.read(hintPath) else {
            cached = nil
            return nil
        }
        let endpoint = WakeEndpoint.parse(hint: file.data)
        cached = (file.stamp, endpoint)
        return endpoint
    }

    // Errors are ignored: a missed wake-up only costs the old latency.
    private func send(to endpoint: WakeEndpoint) {
        if socketEndpoint.map({ $0.family != endpoint.family || $0.interfaceIndex != endpoint.interfaceIndex }) ?? true {
            if socketDescriptor >= 0 { close(socketDescriptor) }
            socketDescriptor = openSocket(for: endpoint)
            socketEndpoint = socketDescriptor >= 0 ? (endpoint.family, endpoint.interfaceIndex) : nil
        }
        guard socketDescriptor >= 0 else { return }
        var byte: UInt8 = 0
        let discardPort = in_port_t(9).bigEndian
        if endpoint.family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = discardPort
            withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: endpoint.address) }
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketDescriptor, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = discardPort
            address.sin6_scope_id = endpoint.scope
            withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: endpoint.address) }
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketDescriptor, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }

    // Bound to the LAN interface the worker verified, so a VPN default route
    // never carries these datagrams.
    private func openSocket(for endpoint: WakeEndpoint) -> Int32 {
        let descriptor = socket(endpoint.family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return -1 }
        var index = Int32(bitPattern: endpoint.interfaceIndex)
        let bound = endpoint.family == AF_INET
            ? setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<Int32>.size))
            : setsockopt(descriptor, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<Int32>.size))
        guard bound == 0, fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            close(descriptor)
            return -1
        }
        return descriptor
    }
}
