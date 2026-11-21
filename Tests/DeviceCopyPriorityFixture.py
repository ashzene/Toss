"""Extract actual copy/ordering methods; replace only their UI/state dependencies."""
from pathlib import Path
import re
import sys

source_path, destination = map(Path, sys.argv[1:])
source = source_path.read_text()

def method(signature):
    # Nested blocks close at deeper indentation; the class method closes at four spaces.
    # Fail closed if the expected declaration disappears or becomes ambiguous.
    pattern = r"^    " + re.escape(signature) + r" \{\n.*?^    \}"
    matches = list(re.finditer(pattern, source, re.MULTILINE | re.DOTALL))
    if len(matches) != 1:
        raise SystemExit(f"Expected exactly one extractable {signature}")
    match = matches[0]
    print(f"Method extracted verbatim: {source_path}:{source.count(chr(10), 0, match.start()) + 1}: {signature}")
    return match.group()

priority = method('private func updateDeviceCopy()')
progress = method('private func setupProgress(_ result: SetupWizard.Result)')
destination.write_text(
    "// Generated from actual TossApp.swift methods; do not edit.\n"
    "import Foundation\n"
    "struct DeviceCopyPriorityFixture {\n"
    "    var setupDeviceClass: DeviceClass?\n"
    "    var pairedDeviceClass: DeviceClass?\n"
    "    var captureDeviceClass: DeviceClass? = nil\n"
    "    var pairedDeviceClasses: Set<DeviceClass> = []\n"
    "    var guideAwaitsDevice = false\n"
    + priority + "\n"
    "    func apply() { updateDeviceCopy() }\n"
    "}\n"
    + '''
@MainActor
final class SetupTextRecorder {
    private(set) var writes: [String] = []
    var stringValue = "" { didSet { writes.append(stringValue) } }
}

@MainActor
final class SetupOnboardingRecorder {
    private(set) var deviceClasses: [DeviceClass?] = []
    func setupCode(_ code: String, final: Bool, ipados: String?,
                   deviceClass: DeviceClass?, osVersion: String?, downloadPercent: Int?) {
        deviceClasses.append(deviceClass)
    }
}

@MainActor
final class DeviceCopyProgressFixture {
    var uninstalling = false
    var setupDeviceClass: DeviceClass?
    var pairedDeviceClass: DeviceClass?
    var pairedDeviceClasses: Set<DeviceClass> = []
    var captureDeviceClass: DeviceClass?
    var guideAwaitsDevice = false
    var lastSetupCode = ""
    var setupDownloadPercent: Int?
    var setupDeviceHash: String?
    var trustWaitStarted: TimeInterval?
    var setupRunning = false
    let setupStatus: SetupTextRecorder? = SetupTextRecorder()
    let onboarding: SetupOnboardingRecorder? = SetupOnboardingRecorder()
    private(set) var promptTitles: [String] = []
    private(set) var promptMessages: [String] = []
    private(set) var menuRefreshes = 0

    init(setup: DeviceClass?, paired: DeviceClass?) {
        setupDeviceClass = setup
        pairedDeviceClass = paired
    }
    private func updateSetupPrompt(_ result: SetupWizard.Result?) {
        guard let result else { return }
        promptTitles.append(SetupWizard.title(for: result.code))
        promptMessages.append(SetupWizard.message(for: result))
    }
    private func refreshMenuStatus() { menuRefreshes += 1 }
    func receive(_ result: SetupWizard.Result) { setupProgress(result) }
'''
    + priority + '\n' + progress + '\n}\n'
)
