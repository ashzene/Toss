import Foundation

// No TossDelegate instance, app launch, real pairing data, or UI.
@main
struct DeviceCopyTests {
    @MainActor static func main() {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAILED: \(message)\n", stderr); exit(1) }
            count += 1
        }
        let original = DeviceCopy.deviceClass, originalLanguage = AppLanguage.override
        defer { DeviceCopy.deviceClass = original; AppLanguage.override = originalLanguage }
        func withDevice(_ value: String?, _ body: () -> Void) {
            let previous = DeviceCopy.deviceClass
            DeviceCopy.deviceClass = value
            defer { DeviceCopy.deviceClass = previous }
            body()
        }
        // Literal expectations are independent of DeviceCopy's implementation.
        let cases: [(String?, String, String, String, String, String, String, String, String)] = [
            (nil, "iPad or iPhone", "iPad 或 iPhone", "iPadOS or iOS", "iPadOS 或 iOS", "iPad / iPhone", "device", "the device", "The device"),
            ("iPad", "iPad", "iPad", "iPadOS", "iPadOS", "iPad", "iPad", "iPad", "iPad"),
            ("iPhone", "iPhone", "iPhone", "iOS", "iOS", "iPhone", "iPhone", "iPhone", "iPhone"),
        ]
        for (device, english, chinese, englishOS, chineseOS, label, shortName, subject, capitalSubject) in cases {
            withDevice(device) {
                check(DeviceCopy.name(chinese: false) == english, "\(device ?? "nil") English name")
                check(DeviceCopy.name(chinese: true) == chinese, "\(device ?? "nil") Chinese name")
                check(DeviceCopy.os(chinese: false) == englishOS, "\(device ?? "nil") English OS")
                check(DeviceCopy.os(chinese: true) == chineseOS, "\(device ?? "nil") Chinese OS")
                check(DeviceCopy.label == label, "\(device ?? "nil") short label")
                check(deviceEN == english && deviceZH == chinese, "global name accessors stay live")
                check(osEN == englishOS && osZH == chineseOS, "global OS accessors stay live")
                check(deviceShortEN == shortName, "\(device ?? "nil") short English name")
                check(deviceSubjectEN == subject, "\(device ?? "nil") English subject")
                check(deviceSubjectCapEN == capitalSubject, "\(device ?? "nil") capitalized English subject")
                let previousLanguage = AppLanguage.override
                defer { AppLanguage.override = previousLanguage }
                AppLanguage.override = false
                check(TossError.captureFailed.errorDescription == "Couldn't capture. Unlock the \(shortName), check the link.",
                      "\(device ?? "nil") English capture failure")
                AppLanguage.override = true
                check(TossError.captureFailed.errorDescription == "截图失败。解锁 \(chinese)，检查连接。",
                      "\(device ?? "nil") Chinese capture failure")
            }
            check(DeviceCopy.deviceClass == original, "device state restored after each case")
        }
        let copyChecks = count

        // The fixture compiles the exact updateDeviceCopy() method extracted from
        // TossApp.swift. Only its input properties are replaced by test data.
        let priorityCases: [(DeviceClass?, DeviceClass?, String?)] = [
            (nil, nil, nil), (nil, .iPad, "iPad"), (nil, .iPhone, "iPhone"),
            (.iPad, nil, "iPad"), (.iPad, .iPad, "iPad"), (.iPad, .iPhone, "iPad"),
            (.iPhone, nil, "iPhone"), (.iPhone, .iPad, "iPhone"), (.iPhone, .iPhone, "iPhone"),
        ]
        for (setup, paired, expected) in priorityCases {
            withDevice("previous-device") {
                let fixture = DeviceCopyPriorityFixture(setupDeviceClass: setup, pairedDeviceClass: paired)
                fixture.apply()
                check(DeviceCopy.deviceClass == expected, "setup \(String(describing: setup)), paired \(String(describing: paired))")
            }
            check(DeviceCopy.deviceClass == original, "priority case restores global state")
        }
        withDevice(nil) {
            var fixture = DeviceCopyPriorityFixture(setupDeviceClass: .iPhone, pairedDeviceClass: .iPad)
            fixture.apply()
            check(DeviceCopy.deviceClass == "iPhone", "setup device overrides paired device")
            fixture.setupDeviceClass = nil
            fixture.apply()
            check(DeviceCopy.deviceClass == "iPad", "clearing setup falls back to paired device")
            fixture.pairedDeviceClass = nil
            fixture.apply()
            check(DeviceCopy.deviceClass == nil, "clearing both removes the previous name")
        }
        check(DeviceCopy.deviceClass == original, "transition case restores global state")
        withDevice(nil) {
            var fixture = DeviceCopyPriorityFixture(setupDeviceClass: nil, pairedDeviceClass: .iPad,
                                                    captureDeviceClass: .iPhone)
            fixture.apply()
            check(DeviceCopy.deviceClass == "iPhone", "active screenshot names iPhone even when primary is iPad")
            fixture.setupDeviceClass = .iPad
            fixture.apply()
            check(DeviceCopy.deviceClass == "iPad", "setup metadata still takes priority")
            fixture.setupDeviceClass = nil; fixture.captureDeviceClass = nil
            fixture.apply()
            check(DeviceCopy.deviceClass == "iPad", "idle returns to primary pairing")
            fixture.guideAwaitsDevice = true
            fixture.apply()
            check(DeviceCopy.deviceClass == nil, "the guide names no device until one is plugged in")
            fixture.setupDeviceClass = .iPhone
            fixture.apply()
            check(DeviceCopy.deviceClass == "iPhone", "the plugged-in device names the guide")
        }
        let priorityChecks = count - copyChecks

        // The full production setupProgress body runs unchanged. UI collaborators
        // record every write, so a wrong first message followed by a correction fails.
        for chinese in [false, true] {
            withDevice("iPad") {
                let previousLanguage = AppLanguage.override
                defer { AppLanguage.override = previousLanguage }
                AppLanguage.override = chinese
                let fixture = DeviceCopyProgressFixture(setup: .iPad, paired: .iPad)
                fixture.receive(.init(code: "trust_needed", model: "iPhone14,6", ipados: "18.1", final: false,
                                      deviceClass: .iPhone, osVersion: "18.1", setupDeviceHash: "phone-target"))
                let expectedMessage = chinese ? "在 iPhone 上点「信任」，输入密码。" : "Tap Trust on your iPhone, enter the passcode."
                let expectedTitle = chinese ? "在 iPhone 上点「信任」" : "Tap Trust on Your iPhone"
                check(fixture.setupStatus?.writes == [expectedMessage],
                      "FIRST_PROGRESS Chinese=\(chinese): expected \(expectedMessage); got \(String(describing: fixture.setupStatus?.writes))")
                check(fixture.promptMessages == [expectedMessage], "first prompt message names the new iPhone")
                check(fixture.promptTitles == [expectedTitle], "first prompt title names the new iPhone")
                check(DeviceCopy.deviceClass == "iPhone", "progress commits the new device class")
                check(fixture.setupDeviceHash == "phone-target", "progress retains exact target for USB guide attachment")
                check(fixture.onboarding?.deviceClasses == [.iPhone], "onboarding receives the same device class")
                check(fixture.lastSetupCode == "trust_needed" && fixture.menuRefreshes == 1, "progress reaches its original final steps")
            }
            check(DeviceCopy.deviceClass == original && AppLanguage.override == originalLanguage,
                  "progress case restores device and language")
        }
        let stopped = DeviceCopyProgressFixture(setup: .iPad, paired: .iPad)
        stopped.uninstalling = true
        stopped.receive(.init(code: "ready", model: nil, ipados: nil))
        check(stopped.setupStatus?.writes.isEmpty == true && stopped.menuRefreshes == 0,
              "Setup progress cannot update settings during uninstall")
        print("DeviceCopy: \(count) assertions passed (\(copyChecks) copy/state, \(priorityChecks) priority/state, \(count - copyChecks - priorityChecks) first-progress/state); no app or device.")
    }
}
