import Foundation

enum TossError: LocalizedError {
    case configuration, backendUnavailable, captureFailed, invalidCapture
    case accessibilityPermission, inputPermission, monitorUnavailable
    case clipboardUnavailable, clipboardChanged, keysStillPressed
    case foregroundChanged, eventUnavailable, cancelled, unconfirmed, interactionInterrupted
    case targetLaunched, activationFailed
    var errorDescription: String? {
        switch self {
        case .configuration: return "iPad is not paired. Open Settings, connect it via USB, and unlock it to begin."
        case .backendUnavailable: return L("Part of Toss is missing. Reopen Toss.", "Toss 缺了一部分，请重新打开。")
        case .captureFailed: return L("Couldn't capture. Unlock the iPad, check the link.", "截图失败。解锁 iPad，检查连接。")
        case .invalidCapture: return L("The screenshot didn't pass checks. Nothing pasted.", "截图没通过检查，什么都没贴。")
        case .accessibilityPermission: return L("Allow Accessibility, then turn shortcuts on.", "打开辅助功能，再打开快捷键。")
        case .inputPermission: return L("Toss needs Accessibility access.", "Toss 需要辅助功能权限。")
        case .monitorUnavailable: return L("Can't hear shortcuts. Check Accessibility.", "听不到快捷键，请检查辅助功能。")
        case .clipboardUnavailable: return L("Couldn't keep the clipboard. Nothing pasted.", "没能保住剪贴板，什么都没贴。")
        case .clipboardChanged: return L("Another app changed the clipboard. Stopped.", "别的 App 改了剪贴板，已停止。")
        case .keysStillPressed: return L("Keys still held. Nothing pasted.", "还有键没松开，什么都没贴。")
        case .foregroundChanged: return L("The app changed. Nothing pasted.", "当前 App 变了，什么都没贴。")
        case .eventUnavailable: return L("Couldn't press Cmd+V. Nothing pasted.", "没能按下 Cmd+V，什么都没贴。")
        case .cancelled: return L("This capture was cancelled.", "这次截图已取消。")
        case .unconfirmed: return L("Pasted but not confirmed. Check your draft.", "粘贴了但没确认，请看看草稿。")
        case .interactionInterrupted: return L("The draft changed. Release the keys, try again.", "草稿变了。松开按键再试。")
        case .targetLaunched: return L("The app just opened. Wait, then press again.", "App 刚打开，等一下再按。")
        case .activationFailed: return L("Couldn't bring the chat forward. Open it, retry.", "没能切到聊天窗口，打开它再试。")
        }
    }
}

