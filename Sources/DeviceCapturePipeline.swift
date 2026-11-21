import Foundation

// Each device owns a serial transfer lane and a four-image capacity. Only the
// final UI transaction is shared: macOS focus/clipboard cannot paste twice at once.
struct DeviceCapturePipeline {
    enum Source: String {
        case macKeyboard = "mac_keyboard"
        case iPhoneShortcut = "iphone_shortcut"
    }

    struct Press: Equatable {
        let id: UInt64
        let chord: HotkeyChord
        let at: Double
        let queued: Bool
        let deviceClass: DeviceClass
        let source: Source

        var allowsDeviceFallback: Bool { source == .macKeyboard }
    }
    private var nextID: UInt64 = 1
    private(set) var waiting: [Press] = []
    private(set) var running: [DeviceClass: Press] = [:]
    private(set) var ready: [Press] = []
    private(set) var delivering: Press?
    var waitingCount: Int { waiting.count }
    var isBusy: Bool { !waiting.isEmpty || !running.isEmpty || !ready.isEmpty || delivering != nil }

    func transferNoticePress(deliveryActive: Bool) -> Press? {
        if deliveryActive, let delivering { return delivering }
        return ready.first ?? running.values.min { $0.at < $1.at } ?? waiting.first
    }

    func press(at: Double) -> Press? {
        (waiting + Array(running.values) + ready + [delivering].compactMap { $0 }).first { $0.at == at }
    }
    mutating func admit(_ chord: HotkeyChord, at: Double, deviceClass: DeviceClass,
                        queued: Bool? = nil, source: Source = .macKeyboard) -> Press? {
        let pending = waiting.filter { $0.deviceClass == deviceClass }
        let count = pending.count + ready.filter { $0.deviceClass == deviceClass }.count + (running[deviceClass] == nil ? 0 : 1)
        guard at.isFinite, pending.count < 3, count < 4 else { return nil }
        let press = Press(id: nextID, chord: chord, at: at, queued: queued ?? isBusy, deviceClass: deviceClass, source: source)
        nextID += 1
        waiting.append(press)
        return press
    }
    mutating func startAvailable(excluding busy: Set<DeviceClass> = []) -> [(slot: DeviceClass, press: Press)] {
        var starts: [(DeviceClass, Press)] = []
        for kind in DeviceClass.allCases where running[kind] == nil && !busy.contains(kind) {
            if let index = waiting.firstIndex(where: { $0.deviceClass == kind }) {
                let press = waiting.remove(at: index)
                running[kind] = press
                starts.append((kind, press))
            }
        }
        return starts
    }
    @discardableResult mutating func completed(_ id: UInt64, slot: DeviceClass) -> Bool {
        guard let press = running[slot], press.id == id else { return false }
        running.removeValue(forKey: slot)
        if delivering?.id != id { ready.append(press) }
        return true
    }
    mutating func takeForTargeting() -> Press? {
        guard delivering == nil else { return nil }
        if !ready.isEmpty { delivering = ready.removeFirst() }
        else { delivering = running.values.min { $0.at < $1.at } }
        return delivering
    }
    // Keep the original targeting transaction across a fast double press, even
    // when its newly selected device is still finishing an earlier transfer.
    mutating func reserveForTargeting(_ id: UInt64) -> Bool {
        guard delivering == nil,
              let press = (waiting + Array(running.values) + ready).first(where: { $0.id == id }) else { return false }
        ready.removeAll { $0.id == id }
        delivering = press
        return true
    }
    mutating func deliveryFinished() { delivering = nil }
    // Retire one speculative iPad generation when a second tap selects iPhone.
    // The worker may still finish; completed(id, slot) will reject that old UUID.
    @discardableResult mutating func remove(at: Double) -> Press? {
        guard let old = press(at: at) else { return nil }
        waiting.removeAll { $0.id == old.id }
        ready.removeAll { $0.id == old.id }
        if running[old.deviceClass]?.id == old.id { running.removeValue(forKey: old.deviceClass) }
        if delivering?.id == old.id { delivering = nil }
        return old
    }
    mutating func disconnected(deviceClass: DeviceClass) -> [Press] {
        let discarded = waiting.filter { $0.deviceClass == deviceClass }
        waiting.removeAll { $0.deviceClass == deviceClass }
        return discarded
    }
    mutating func reset() {
        waiting.removeAll(); running.removeAll(); ready.removeAll(); delivering = nil
        // Keep monotonic IDs so callbacks from before reset can never own a new press.
    }
}

extension DeviceClass {
    var other: DeviceClass { self == .iPad ? .iPhone : .iPad }
}

// USB data dropped while the device still has power: the cable is in, so say so. At most every ten minutes.
struct USBDropNotice {
    static let quietSeconds = 600.0
    private var lastShown: [DeviceClass: Double] = [:]
    mutating func shouldShow(_ device: DeviceClass, externalConnected: Bool?, usbBack: Bool, at now: Double) -> Bool {
        guard externalConnected == true, !usbBack else { return false }
        if let last = lastShown[device], now - last < Self.quietSeconds { return false }
        lastShown[device] = now
        return true
    }
}

struct DevicePressRouting {
    private static let reconnectGraceSeconds = 6.0
    private var unavailableSince: [DeviceClass: Double] = [:]

    mutating func observe(_ device: DeviceClass, unavailable: Bool, at now: Double) {
        if unavailable {
            // Another attempt in the same outage does not restart the grace period.
            unavailableSince[device] = unavailableSince[device] ?? now
        } else {
            unavailableSince.removeValue(forKey: device)
        }
    }

    func device(wanted: DeviceClass, paired: Set<DeviceClass>, closed: Set<DeviceClass>,
                ready: Set<DeviceClass>, at now: Double) -> DeviceClass {
        let other = wanted.other
        guard paired.contains(other), ready.contains(other),
              !closed.contains(other) else { return wanted }
        if closed.contains(wanted) { return other }
        return isOffline(wanted, ready: ready, at: now) ? other : wanted
    }

    // The alternate could have taken this press if it were unlocked.
    func lockedAlternate(for wanted: DeviceClass, paired: Set<DeviceClass>, closed: Set<DeviceClass>,
                         ready: Set<DeviceClass>, at now: Double) -> DeviceClass? {
        let other = wanted.other
        guard paired.contains(wanted), paired.contains(other), ready.contains(other), closed.contains(other),
              isOffline(wanted, ready: ready, at: now) else { return nil }
        return other
    }

    private func isOffline(_ device: DeviceClass, ready: Set<DeviceClass>, at now: Double) -> Bool {
        guard !ready.contains(device), let since = unavailableSince[device] else { return false }
        return now - since >= Self.reconnectGraceSeconds
    }
}

// Same 500 ms gesture as DualHotkeyCore, independent of delivery occupancy.
// A single chord starts the primary device immediately. Its fast second chord
// replaces that logical press with the other device, or is consumed for a single device.
struct DeviceCaptureGesture {
    enum Action: Equatable {
        case capture(HotkeyChord, at: Double, deviceClass: DeviceClass)
        case retarget(at: Double)
        case consumed
    }
    private var last: (chord: HotkeyChord, at: Double, dual: Bool, doubled: Bool)?
    private var deadlines: [Double: Double] = [:]
    mutating func observe(_ chord: HotkeyChord, at: Double, primary: DeviceClass, dual: Bool) -> Action {
        deadlines = deadlines.filter { $0.value > at }
        if let previous = last, previous.chord == chord, !previous.doubled,
           at >= previous.at, at < previous.at + DualHotkeyCore.doublePressWindow {
            last?.doubled = true
            deadlines.removeValue(forKey: previous.at)
            return previous.dual ? .retarget(at: previous.at) : .consumed
        }
        last = (chord, at, dual, false)
        if dual { deadlines[at] = at + DualHotkeyCore.doublePressWindow }
        return .capture(chord, at: at, deviceClass: primary)
    }
    func selectionDeadline(pressedAt: Double) -> Double { deadlines[pressedAt] ?? 0 }
    mutating func reset() { last = nil; deadlines.removeAll() }
}
