import AppKit

// In-memory store only: no general pasteboard, target application or event tap.
@MainActor
final class FakeClipboard: ClipboardStore {
    var changeCount = 0
    var items: [[NSPasteboard.PasteboardType: Data]]
    var failPublish = false
    var failRestore = false
    var changeDuringSnapshot = false
    var writes = 0
    init(_ items: [[NSPasteboard.PasteboardType: Data]] = []) { self.items = items }
    func snapshot() throws -> [[NSPasteboard.PasteboardType: Data]] {
        if changeDuringSnapshot { changeCount += 1 }
        return items
    }
    func clear() { items = []; changeCount += 1 }
    func write(file: URL) -> Bool {
        writes += 1
        guard !failPublish else { return false }
        items = [[.fileURL: Data(file.absoluteString.utf8)]]
        changeCount += 1
        return true
    }
    func write(items: [[NSPasteboard.PasteboardType: Data]]) -> Bool {
        writes += 1
        guard !failRestore else { return false }
        self.items = items
        changeCount += 1
        return true
    }
    func userCopy(_ text: String) { items = [[.string: Data(text.utf8)]]; changeCount += 1 }
}

@main
enum ClipboardTransactionTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        func rejects(_ body: () throws -> Void) {
            do { try body(); preconditionFailure("expected rejection") } catch { checks += 1 }
        }
        let original: [[NSPasteboard.PasteboardType: Data]] = [
            [.string: Data("用户文字".utf8), .rtf: Data([0, 1, 255])],
            [.png: Data([137, 80, 78, 71])]
        ]
        let file = URL(fileURLWithPath: "/synthetic/iPad-unique.png")
        func start(_ store: FakeClipboard) throws -> ClipboardTransaction {
            let tx = try ClipboardTransaction(store: store); try tx.publish(file: file); return tx
        }
        let board = FakeClipboard(original), tx = try start(board)
        check(board.items.first?[.fileURL] != nil, "publishes a file URL")
        check(tx.finish(pastePosted: false, consumptionConfirmed: false, targetTerminated: false), "pre-post failure restores")
        check(board.items == original, "all items and all formats restored")
        let writes = board.writes
        check(tx.finish(pastePosted: false, consumptionConfirmed: false, targetTerminated: false), "cleanup is idempotent")
        check(board.writes == writes, "does not restore twice")

        let waiting = FakeClipboard(original), pending = try start(waiting)
        check(!pending.finish(pastePosted: true, consumptionConfirmed: false, targetTerminated: false), "unconsumed event retains snapshot")
        check(waiting.items.first?[.fileURL] != nil, "unknown queued Cmd-V still sees image")
        check(!pending.finish(pastePosted: true, consumptionConfirmed: false, targetTerminated: false), "timeout/retry alone cannot restore")
        check(pending.finish(pastePosted: true, consumptionConfirmed: true, targetTerminated: false), "late exact receipt releases clipboard")
        check(waiting.items == original, "late receipt restores original instead of intermediate image")

        let terminated = FakeClipboard(original), dead = try start(terminated)
        check(dead.finish(pastePosted: true, consumptionConfirmed: false, targetTerminated: true), "terminated target cannot consume old event")
        check(terminated.items == original, "termination restores all formats")

        let changed = FakeClipboard(original), replaced = try start(changed)
        changed.userCopy("new user copy")
        rejects { try replaced.validate() }
        check(replaced.finish(pastePosted: true, consumptionConfirmed: true, targetTerminated: false), "ownership loss finishes recovery")
        check(changed.items == [[.string: Data("new user copy".utf8)]], "new user copy is never clobbered")

        let unreadable = FakeClipboard(original); unreadable.changeDuringSnapshot = true
        rejects { _ = try ClipboardTransaction(store: unreadable) }
        let beforePublish = FakeClipboard(original), stale = try ClipboardTransaction(store: beforePublish)
        beforePublish.userCopy("changed before publish")
        rejects { try stale.publish(file: file) }
        check(beforePublish.writes == 0, "no write after snapshot ownership changed")
        let failed = FakeClipboard(original); failed.failPublish = true
        let failedTx = try ClipboardTransaction(store: failed)
        rejects { try failedTx.publish(file: file) }
        check(failed.items == original, "failed URL publication restores clipboard")
        let empty = FakeClipboard(), emptyTx = try start(empty)
        check(emptyTx.finish(pastePosted: true, consumptionConfirmed: true, targetTerminated: false), "empty original restored")
        check(empty.items.isEmpty, "no phantom clipboard item")
        let retry = FakeClipboard(original), retryTx = try start(retry)
        retry.failRestore = true
        check(!retryTx.finish(pastePosted: true, consumptionConfirmed: true, targetTerminated: false), "failed restore preserves recovery state")
        retry.failRestore = false
        check(retryTx.finish(pastePosted: true, consumptionConfirmed: true, targetTerminated: false), "restore can be retried after receipt")
        check(retry.items == original, "retry uses original snapshot")

        check(PasteInputPolicy.canPost(tracked: .init(), live: .init()), "idle keyboard allowed")
        check(!PasteInputPolicy.canPost(tracked: .init(), live: .init(ordinaryKey: true)), "fresh physical typing overrides stale tap")
        check(!PasteInputPolicy.canPost(tracked: .init(), live: .init(leftShift: true)), "held Shift detected without waiting for main queue")
        check(!PasteInputPolicy.canPost(tracked: .init(command: true), live: .init()), "tracked held modifier still blocks")
        check(TossError.activationFailed.errorDescription?.contains("No screenshot was taken") == false, "activation can overlap capture")
        // An unconfirmed paste never blocks the next keypress: it hands over the original clipboard.
        let chain = FakeClipboard(original), first = try start(chain)
        check(!first.finish(pastePosted: true, consumptionConfirmed: false, targetTerminated: false), "unconfirmed paste is kept")
        let second = try ClipboardTransaction.continuing(first, store: chain)
        try second.publish(file: URL(fileURLWithPath: "/synthetic/iPad-next.png"))
        check(chain.items.first?[.fileURL] != nil, "next screenshot is published over the unconfirmed one")
        check(second.finish(pastePosted: true, consumptionConfirmed: true, targetTerminated: false), "next paste restores")
        check(chain.items == original, "the user's original clipboard comes back, not the old screenshot")
        let copied = FakeClipboard(original), earlier = try start(copied)
        _ = earlier.finish(pastePosted: true, consumptionConfirmed: false, targetTerminated: false)
        copied.userCopy("新复制的")
        let fresh = try ClipboardTransaction.continuing(earlier, store: copied)
        try fresh.publish(file: file)
        check(fresh.finish(pastePosted: false, consumptionConfirmed: false, targetTerminated: false), "fresh copy restores")
        check(copied.items == [[.string: Data("新复制的".utf8)]], "a copy made in between wins over the old original")
        let none = FakeClipboard(original)
        let plain = try ClipboardTransaction.continuing(nil, store: none)
        try plain.publish(file: file)
        check(plain.finish(pastePosted: false, consumptionConfirmed: false, targetTerminated: false) && none.items == original,
              "without an earlier paste it is an ordinary transaction")
        print("Clipboard transaction: \(checks) checks passed (in-memory store; no UI/events).")
    }
}
