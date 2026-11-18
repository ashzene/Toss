import Foundation

// Which device the visible text talks about (2026-11-01, iPhone support). "iPad" or "iPhone"
// once a device is paired, or plugged in during setup; nil before that, and the text then
// says "iPad or iPhone". Set from the paired-device state: at launch from target.json, from
// each setup result's device_class, and back to nil on Forget. Product names stay untranslated.
// Menu items that are built once use neutral words ("This Device") so they never go stale.
enum DeviceCopy {
    // iPad 和 iPhone 都配好了
    nonisolated(unsafe) static var bothPaired = false
    nonisolated(unsafe) static var deviceClass: String?

    static func name(chinese: Bool) -> String { deviceClass ?? (chinese ? "iPad 或 iPhone" : "iPad or iPhone") }
    static func os(chinese: Bool) -> String {
        switch deviceClass {
        case "iPad"?: return "iPadOS"
        case "iPhone"?: return "iOS"
        default: return chinese ? "iPadOS 或 iOS" : "iPadOS or iOS"
        }
    }
    // Row titles in Settings and the guide: too narrow for "or".
    static var label: String { deviceClass ?? "iPad / iPhone" }
}

var deviceEN: String { DeviceCopy.name(chinese: false) }
var deviceZH: String { DeviceCopy.name(chinese: true) }
var osEN: String { DeviceCopy.os(chinese: false) }
var osZH: String { DeviceCopy.os(chinese: true) }
// Tight English lines (one-line width checks, 2026-11-01): before pairing they say "device"
// instead of "iPad or iPhone". With a device known they read exactly like deviceEN.
var deviceShortEN: String { DeviceCopy.deviceClass ?? "device" }          // "your …", "the …"
var deviceSubjectEN: String { DeviceCopy.deviceClass ?? "the device" }    // mid-sentence subject
var deviceSubjectCapEN: String { DeviceCopy.deviceClass ?? "The device" } // sentence start
