import Foundation
import Darwin

// Pure checks plus private temporary files. No socket is opened, nothing is sent.
@main
struct IPadWakerTests {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ line: UInt = #line) {
            if !condition { fatalError("IPadWaker check failed at line \(line)") }
            count += 1
        }

        // Burst: start, extend while running, stop at the deadline, start again.
        var burst = WakeBurst()
        check(burst.deadline == nil)
        check(burst.poke(at: 10.0))
        check(abs((burst.deadline ?? 0) - 10.6) < 1e-9)
        check(burst.shouldSend(at: 10.04))
        check(!burst.poke(at: 10.3)) // Running: extended, not restarted.
        check(abs((burst.deadline ?? 0) - 10.9) < 1e-9)
        check(burst.shouldSend(at: 10.85))
        check(!burst.shouldSend(at: 10.9))
        check(burst.deadline == nil)
        check(burst.poke(at: 11.0))
        check(!burst.shouldSend(at: 11.6))
        check(burst.poke(at: 11.6)) // A deadline that passed unseen starts a new burst.

        // Endpoint hint validation, with a fake interface table.
        func hint(_ ip: Any, port: Any = 49152, interface: Any = "en0") -> Data {
            try! JSONSerialization.data(withJSONObject: ["ip": ip, "port": port, "interface": interface])
        }
        let table: (String) -> UInt32 = { ["en0": 15, "en12": 7][$0] ?? 0 }
        func parse(_ data: Data) -> WakeEndpoint? { WakeEndpoint.parse(hint: data, interfaceIndex: table) }

        check(parse(hint("172.20.10.2")) == WakeEndpoint(family: AF_INET, address: [172, 20, 10, 2], scope: 0, interfaceIndex: 15))
        check(parse(hint("10.0.0.5"))?.address == [10, 0, 0, 5])
        check(parse(hint("192.168.1.20", interface: "en12"))?.interfaceIndex == 7)
        check(parse(hint("172.16.0.1")) != nil)
        check(parse(hint("172.31.255.254")) != nil)
        for rejected in ["172.15.0.1", "172.32.0.1", "8.8.8.8", "127.0.0.1", "169.254.1.1", "0.0.0.0",
                         "192.169.0.1", "100.64.0.1", "2001:4860::8888", "::1", "ff02::1", "not an ip", ""] {
            check(parse(hint(rejected)) == nil)
        }
        let linkLocal = parse(hint("fe80::1c2a:3bff:fe4d:5e6f%en0"))
        check(linkLocal?.family == AF_INET6 && linkLocal?.scope == 15 && linkLocal?.address.first == 0xFE)
        check(parse(hint("fe80::1"))?.scope == 15)
        let ula = parse(hint("fd12:3456:789a::2"))
        check(ula?.family == AF_INET6 && ula?.scope == 0)
        check(parse(hint("172.20.10.2", interface: "utun14")) == nil) // A VPN tunnel is not the LAN.
        check(parse(hint("172.20.10.2", interface: "en9")) == nil) // Interface not present.
        check(parse(hint("172.20.10.2", interface: "en0; rm")) == nil)
        check(parse(hint("172.20.10.2", port: 0)) == nil)
        check(parse(hint("172.20.10.2", port: 70000)) == nil)
        check(parse(hint("172.20.10.2", port: "49152")) == nil)
        check(parse(hint(17220102)) == nil)
        check(parse(Data("[]".utf8)) == nil)
        check(parse(Data("{".utf8)) == nil)

        // Hint file rules: regular, owned, mode 600, at most 512 bytes; mtime stamp.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipad-waker-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("endpoint-hint.json").path
        let good = hint("172.20.10.2")
        check(FileManager.default.createFile(atPath: path, contents: good, attributes: [.posixPermissions: 0o600]))
        let first = WakeHintFile.read(path)
        check(first?.data == good)
        check(first?.stamp == WakeHintFile.stamp(path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        check(WakeHintFile.read(path) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: path)
        check(WakeHintFile.stamp(path) != first?.stamp) // A rewrite is noticed.
        try Data(repeating: 0x20, count: 513).write(to: URL(fileURLWithPath: path))
        check(WakeHintFile.read(path) == nil)
        let link = directory.appendingPathComponent("link.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        check(WakeHintFile.read(link) == nil)
        check(WakeHintFile.read(directory.path) == nil)
        check(WakeHintFile.read(directory.appendingPathComponent("missing.json").path) == nil)
        check(WakeHintFile.stamp(directory.appendingPathComponent("missing.json").path) == nil)

        // First key of a chord: one Option or Shift down, nothing else held.
        let none = ModifierSnapshot()
        check(ModifierSnapshot(leftOption: true).startsChord(after: none))
        check(ModifierSnapshot(rightOption: true).startsChord(after: none))
        check(ModifierSnapshot(leftShift: true).startsChord(after: none))
        check(ModifierSnapshot(rightShift: true).startsChord(after: none))
        check(!ModifierSnapshot(leftOption: true, rightOption: true).startsChord(after: ModifierSnapshot(leftOption: true)))
        check(!ModifierSnapshot(leftOption: true).startsChord(after: ModifierSnapshot(leftOption: true)))
        check(!ModifierSnapshot(leftOption: true).startsChord(after: ModifierSnapshot(leftOption: true, rightOption: true)))
        check(!ModifierSnapshot(leftOption: true, command: true).startsChord(after: ModifierSnapshot(command: true)))
        check(!ModifierSnapshot(leftShift: true, ordinaryKey: true).startsChord(after: ModifierSnapshot(ordinaryKey: true)))
        check(!ModifierSnapshot(leftOption: true, control: true).startsChord(after: none))
        check(!ModifierSnapshot(rightShift: true, function: true).startsChord(after: none))
        check(!ModifierSnapshot(leftOption: true, leftShift: true).startsChord(after: ModifierSnapshot(leftShift: true)))
        check(!none.startsChord(after: ModifierSnapshot(leftOption: true)))

        // Keepalive: only while switched on, enabled, connected, display awake and the Mac
        // was used within the idle limit (default 10 min); every other case says why it is off.
        func keep(switchOn: Bool = true, enabled: Bool = true, connected: Bool = true,
                  idle: Double = 5, minutes: Double = 10, asleep: Bool = false) -> String {
            KeepAlivePolicy.state(switchOn: switchOn, enabled: enabled, connected: connected,
                                  secondsSinceInput: idle, idleMinutes: minutes, screensAsleep: asleep)
        }
        check(keep() == "on")
        check(keep(switchOn: false) == "off-switch")
        check(keep(enabled: false) == "off-disabled")
        check(keep(connected: false) == "off-disconnected")
        check(keep(asleep: true) == "off-display-asleep")
        check(keep(idle: 599) == "on" && keep(idle: 600) == "off-idle")
        check(keep(idle: 119, minutes: 2) == "on" && keep(idle: 121, minutes: 2) == "off-idle")
        check(keep(idle: 500, minutes: .nan) == "on" && keep(idle: 700, minutes: -1) == "off-idle")   // bad setting: default 10
        check(keep(idle: .infinity) == "off-idle" && keep(idle: -1) == "off-idle")
        check(KeepAlivePolicy.interval == 0.3 && KeepAlivePolicy.switchKey == "iPadKeepAlive")
        check(Int(3600 / KeepAlivePolicy.interval) == 12_000)   // datagrams per active hour

        print("IPadWaker: \(count) assertions passed; no socket opened, nothing sent.")
    }
}
