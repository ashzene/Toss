import Foundation
import Darwin

private enum SyntheticError: Error { case stopped }
private final class FakeChannel: USBMuxChannel {
    let reply: ([String: Any]) throws -> [String: Any]
    let event: () throws -> [String: Any]
    let stop: () -> Void
    init(reply: @escaping ([String: Any]) throws -> [String: Any],
         event: @escaping () throws -> [String: Any] = { throw SyntheticError.stopped },
         stop: @escaping () -> Void = {}) {
        self.reply = reply; self.event = event; self.stop = stop
    }
    func request(_ message: [String: Any]) throws -> [String: Any] { try reply(message) }
    func receive() throws -> [String: Any] { try event() }
    func waitIndefinitely() {}
    func interrupt() { stop() }
    func close() {}
}

@main struct USBSetupObserverTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String = "", line: Int = #line) {
        checks += 1
        if !value() { fputs("USB setup failed line \(line): \(message)\n", stderr); exit(1) }
    }
    static func main() {
        let pad = USBSetupDevice(insertion: 1, deviceClass: "iPad", deviceHash: "pad")
        let phone = USBSetupDevice(insertion: 2, deviceClass: "iPhone", deviceHash: "phone")
        var policy = USBSetupPolicy()
        policy.update([pad])
        check(policy.take(paired: ["iPad": "pad"], iPadOnly: false, hasPairing: true, blocked: false) == nil, "paired stays closed")
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: true) == nil, "busy defers")
        check(policy.prompted.isEmpty)
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: false) == pad, "idle opens pending")
        policy.markPresented(); policy.update([pad])
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: false) == nil, "same insertion never reopens")
        var unavailable = pad; unavailable.trusted = false
        policy.update([unavailable]); policy.update([pad])
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: false) == nil, "temporary metadata failure is not detach")
        let reassigned = USBSetupDevice(insertion: 99, deviceClass: "iPad", deviceHash: "pad")
        policy.update([reassigned])
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: false) == nil, "daemon ID reassignment is not replug")
        policy.update([]); policy.update([pad])
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: false) == pad, "replug opens again even if daemon reuses ID")
        policy = USBSetupPolicy(); policy.update([pad, phone])
        check(policy.take(paired: ["iPad": "pad"], iPadOnly: false, hasPairing: true, blocked: false) == phone, "mixed pair only offers unpaired phone")
        policy.update([pad, phone])
        check(policy.take(paired: ["iPad": "pad"], iPadOnly: false, hasPairing: true, blocked: false) == nil)
        policy = USBSetupPolicy(); policy.update([pad, phone])
        check(policy.take(paired: ["iPad": "other"], iPadOnly: true, hasPairing: true, blocked: false) == nil, "iPad edition ignores every device once paired")
        policy.update([phone])
        check(policy.take(paired: [:], iPadOnly: true, hasPairing: false, blocked: false) == nil, "iPad edition ignores iPhone")
        policy.update([pad])
        check(policy.take(paired: [:], iPadOnly: true, hasPairing: false, blocked: false) == pad)
        policy = USBSetupPolicy(); policy.update([unavailable])
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: false) == nil, "untrusted silent")
        policy.update([pad])
        check(policy.take(paired: ["iPad": "different"], iPadOnly: false, hasPairing: true, blocked: false) == pad, "class alone is insufficient")
        policy = USBSetupPolicy(); policy.update([pad, phone])
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: false) != nil)
        policy.markPresented()
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: false) == nil, "mixed guide dismissed for this insertion")
        policy = USBSetupPolicy(); policy.update([phone])
        _ = policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: true)
        policy.update([])
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: false) == nil, "pending unplugged before idle")
        // A second insertion while a guide is open must remain pending when it closes.
        policy = USBSetupPolicy(); policy.update([pad]); policy.markPresented()
        policy.update([pad, phone])
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: true) == nil)
        check(policy.take(paired: [:], iPadOnly: false, hasPairing: false, blocked: false) == phone)
        check(USBSetupObserver.classify(product: "iPad") == "iPad")
        check(USBSetupObserver.classify(product: "iPhone") == "iPhone")
        check(USBSetupObserver.classify(product: "iPod") == nil)
        check(USBSetupObserver.fingerprint("00008110-001234567890ABCD") == USBSetupObserver.fingerprint("00008110001234567890ABCD"))
        dismissalTests()
        listenerTest()
        print("USB setup: \(checks) checks passed; fake daemon and registry only.")
    }

    private final class MemoryPreferences: USBSetupPreferences {
        var values: [String: Any] = [:]
        var writes = 0
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value; writes += 1 }
    }
    static func dismissalTests() {
        let preferences = MemoryPreferences()
        let store = USBSetupDismissals(preferences: preferences)
        let pad = USBSetupDevice(insertion: 1, deviceClass: "iPad", deviceHash: USBSetupObserver.fingerprint("synthetic-pad"))
        let phone = USBSetupDevice(insertion: 2, deviceClass: "iPhone", deviceHash: USBSetupObserver.fingerprint("synthetic-phone"))
        let other = USBSetupDevice(insertion: 3, deviceClass: "iPad", deviceHash: USBSetupObserver.fingerprint("synthetic-other"))
        func open(_ policy: inout USBSetupPolicy, devices: [USBSetupDevice], paired: [String: String] = [:], iPadOnly: Bool = false, visible: Bool = true) {
            policy.update(devices)
            let candidates = policy.pending(paired: paired, iPadOnly: iPadOnly, hasPairing: !paired.isEmpty)
            check(policy.take(paired: paired, iPadOnly: iPadOnly, hasPairing: !paired.isEmpty, blocked: false) != nil)
            policy.markPresented() // The shared UI opener also serves manual setup.
            policy.automaticPresented(candidates, visible: visible)
        }
        var policy = USBSetupPolicy(dismissals: store)
        open(&policy, devices: [pad], iPadOnly: true)
        check(preferences.writes == 0, "opening does not persist")
        check(policy.closed(terminating: false, completed: false, paired: [:]))
        check(store.hashes == [pad.deviceHash])
        policy.update([]); policy.update([pad])
        check(policy.pending(paired: [:], iPadOnly: true, hasPairing: false).isEmpty, "dismissed replug")
        policy = USBSetupPolicy(dismissals: USBSetupDismissals(preferences: preferences))
        policy.update([pad, other])
        check(policy.pending(paired: [:], iPadOnly: true, hasPairing: false) == [other], "restart suppresses only the dismissed device")
        policy.markPresented()
        check(!policy.closed(terminating: false, completed: false, paired: [:]), "manual close is not dismissal")
        check(store.hashes == [pad.deviceHash], "manual entry works even for suppressed devices without changing storage")
        policy.forget(pad.deviceHash)
        check(store.hashes.isEmpty)
        check(policy.pending(paired: [:], iPadOnly: true, hasPairing: false) == [pad], "forget removes persistent and insertion suppression")

        for reason in ["restart", "quit", "completed", "paired", "hidden", "manual", "blocked"] {
            let memory = MemoryPreferences()
            let storage = USBSetupDismissals(preferences: memory)
            var original = USBSetupPolicy(dismissals: storage)
            if reason == "blocked" {
                original.update([pad])
                check(original.take(paired: [:], iPadOnly: true, hasPairing: false, blocked: true) == nil)
            } else {
                open(&original, devices: [pad], iPadOnly: true, visible: reason != "hidden")
            }
            if reason == "manual" { original.markPresented() }
            if reason != "restart" {
                check(!original.closed(terminating: reason == "quit", completed: reason == "completed",
                                       paired: reason == "paired" ? ["iPad": pad.deviceHash] : [:]), reason)
            }
            check(memory.writes == 0, "no persisted dismissal: \(reason)")
            var restarted = USBSetupPolicy(dismissals: USBSetupDismissals(preferences: memory))
            restarted.update([pad])
            check(restarted.take(paired: [:], iPadOnly: true, hasPairing: false, blocked: false) == pad, "still offers after \(reason)")
        }
        let mixedPreferences = MemoryPreferences()
        let mixedStore = USBSetupDismissals(preferences: mixedPreferences)
        policy = USBSetupPolicy(dismissals: mixedStore)
        open(&policy, devices: [pad, phone], paired: ["iPad": pad.deviceHash])
        policy.update([pad, phone, other])
        check(policy.closed(terminating: false, completed: false, paired: ["iPad": pad.deviceHash]))
        check(mixedStore.hashes == [phone.deviceHash], "paired iPad plus unpaired iPhone; later insertion excluded")
        check(policy.pending(paired: ["iPad": pad.deviceHash], iPadOnly: false, hasPairing: true) == [other])
        policy.forget(phone.deviceHash)
        policy = USBSetupPolicy(dismissals: mixedStore)
        open(&policy, devices: [pad, phone])
        policy.update([]) // Detached devices still belong to the original guide.
        check(policy.closed(terminating: false, completed: false, paired: [:]))
        check(Set(mixedStore.hashes) == Set([pad.deviceHash, phone.deviceHash]), "whole original candidate set")
        policy.forget(pad.deviceHash)
        check(mixedStore.hashes == [phone.deviceHash], "forget one preserves the other")
        policy.forget(phone.deviceHash)
        open(&policy, devices: [pad, phone])
        check(policy.closed(terminating: false, completed: false, paired: ["iPhone": phone.deviceHash]))
        check(mixedStore.hashes == [pad.deviceHash], "successful device excluded from mixed dismissal")

        let hashes = (0..<35).map { USBSetupObserver.fingerprint("fixture-\($0)") }
        let bounded = USBSetupDismissals(preferences: preferences)
        preferences.values = [:]
        bounded.remember(Array(hashes.prefix(32)))
        bounded.remember([hashes[0]]) // Duplicate does not change its age.
        bounded.remember([hashes[32]])
        check(bounded.hashes == Array(hashes[1...32]), "oldest evicted at 33")
        bounded.remember(["raw-udid", "", String(repeating: "g", count: 64)])
        check(bounded.hashes == Array(hashes[1...32]), "only SHA-256 hex stored")
        for bad: Any in [42, "broken", ["raw-udid"], [hashes[0], 7], [hashes[0], hashes[0]], ["bad": "shape"]] {
            preferences.values[USBSetupDismissals.key] = bad
            check(bounded.hashes.isEmpty, "malformed data is empty")
            bounded.remember([hashes[0]])
            check(bounded.hashes == [hashes[0]], "bad data recovers")
        }
        preferences.values[USBSetupDismissals.key] = hashes
        check(bounded.hashes == Array(hashes.suffix(32)), "oversized valid data bounded on read")
    }

    static func listenerTest() {
        let lock = NSLock()
        let stopped = DispatchSemaphore(value: 0)
        var calls: [String] = [], events = 0
        let attached: [String: Any] = ["MessageType": "Attached", "DeviceID": 1,
            "Properties": ["SerialNumber": "FAKE-PAD", "ConnectionType": "USB"]]
        let network: [String: Any] = ["DeviceID": 2,
            "Properties": ["SerialNumber": "FAKE-NETWORK", "ConnectionType": "Network"]]
        let untrusted: [String: Any] = ["DeviceID": 3,
            "Properties": ["SerialNumber": "FAKE-PHONE", "ConnectionType": "USB"]]
        let record = try! PropertyListSerialization.data(fromPropertyList: ["HostID": "fake", "SystemBUID": "fake", "DeviceCertificate": Data([0])], format: .binary, options: 0)
        let listener = FakeChannel(reply: { message in
            lock.lock(); calls.append(message["MessageType"] as! String); lock.unlock()
            return ["Number": 0]
        }, event: {
            events += 1
            if events == 1 { return attached } // duplicate initial attach
            if events == 2 { return ["MessageType": "Detached", "DeviceID": 1] }
            stopped.wait()
            throw SyntheticError.stopped
        }, stop: { stopped.signal() })
        var created = 0
        var snapshots: [[USBSetupDevice]] = []
        let observer = USBSetupObserver(products: { ["fakepad": "iPad", "fakephone": "iPhone"] }, makeSocket: {
            created += 1
            if created == 1 { return listener }
            return FakeChannel(reply: { message in
                let command = message["MessageType"] as! String
                lock.lock(); calls.append(command); lock.unlock()
                if command == "ListDevices" { return ["DeviceList": [attached, network, untrusted]] }
                if command == "ReadPairRecord", message["PairRecordID"] as? String == "FAKE-PAD" { return ["PairRecordData": record] }
                return ["Number": 2]
            })
        }, changed: { snapshots.append($0) })
        observer.start()
        let deadline = Date().addingTimeInterval(2)
        while snapshots.count < 3 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        observer.stop()
        check(snapshots.count == 3)
        check(snapshots[0].count == 2, "network entries ignored")
        check(snapshots[0].filter(\.trusted).map(\.deviceClass) == ["iPad"], "only stored pair records eligible")
        check(snapshots[0].sorted { $0.key < $1.key } == snapshots[1].sorted { $0.key < $1.key }, "duplicate event stable")
        check(snapshots[2].count == 1 && snapshots[2][0].deviceClass == "iPhone" && !snapshots[2][0].trusted)
        lock.lock(); let commands = calls; lock.unlock()
        check(Array(commands.prefix(2)) == ["Listen", "ListDevices"])
        check(Set(commands).isSubset(of: ["Listen", "ListDevices", "ReadPairRecord"]), "no Connect/Pair/SavePairRecord")
        let source = try! String(contentsOfFile: CommandLine.arguments[1])
        check(source.contains("runtimeQuarantined || onboarding != nil"))
        let offer = source.components(separatedBy: "private func offerUSBSetup() {")[1]
            .components(separatedBy: "func showInitialInterface()")[0]
        check(!offer.contains("|| setupWizard.isRunning"), "background setup does not block onboarding")
        let open = source.components(separatedBy: "@objc private func openOnboarding()")[1]
            .components(separatedBy: "// System Settings")[0]
        check(!open.contains("cancel("), "opening must not cancel pairing")

        check(offer.contains("automaticPresented(candidates, visible: onboarding?.isVisible == true)"), "snapshot only when shown")
        check(open.contains("usbSetupPolicy.markPresented()"), "manual entry has no suppression gate")
        check(source.contains("terminating: self.terminating || self.uninstalling"))
        check(source.contains("completed: controller?.flow.step == .done, paired: self.pairedUSBSetupHashes()"))
        check(source.contains("usbSetupPolicy.forget(forgottenHash)"))
        check(source.contains("dismissedAutomatic || OnboardingPolicy.closeMarksSeen"), "welcome dismissal also prevents launch prompt")
        check(source.contains("core.isBusy || hasActiveWork || transaction != nil"))
        check(source.contains("guard !uninstalling, !terminating else { return }"))
        check(source.contains("stopUSBSetupObserver(); stop(reason:"))
        check(source.contains("private func quiesceForUninstall() {\n        stopUSBSetupObserver()"))
    }
}
