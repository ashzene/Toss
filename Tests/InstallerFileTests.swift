import AppKit
import Foundation

@main enum InstallerFileTests {
    static func main() throws {
        let fm = FileManager.default
        let payload = URL(fileURLWithPath: CommandLine.arguments[1])
        let hash = CommandLine.arguments[2]
        let identifier = "local.toss.installerpayloadtest"
        let root = fm.temporaryDirectory.appendingPathComponent("toss-installer-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ value: Bool, _ text: String) { precondition(value, text); count += 1 }
        func rejects(_ text: String, _ action: () throws -> Void) {
            do { try action(); preconditionFailure(text) } catch { count += 1 }
        }
        try InstallFiles.verify(payload, identifier: identifier, hash: hash); count += 1
        rejects("wrong identifier accepted") { try InstallFiles.verify(payload, identifier: "wrong.bundle", hash: hash) }
        rejects("wrong pinned code accepted") { try InstallFiles.verify(payload, identifier: identifier, hash: String(repeating: "0", count: 40)) }
        let tampered = root.appendingPathComponent("Tampered.app")
        try fm.copyItem(at: payload, to: tampered)
        let binary = tampered.appendingPathComponent("Contents/MacOS/MockToss")
        let handle = try FileHandle(forWritingTo: binary); try handle.seekToEnd(); try handle.write(contentsOf: Data("tamper".utf8)); try handle.close()
        rejects("modified code accepted") { try InstallFiles.verify(tampered, identifier: identifier, hash: hash) }

        let destination = root.appendingPathComponent("Toss.app")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("previous".utf8).write(to: destination.appendingPathComponent("marker"))
        rejects("missing stage accepted") { try InstallFiles.commit(stage: root.appendingPathComponent("missing"), destination: destination) }
        check(try String(contentsOf: destination.appendingPathComponent("marker"), encoding: .utf8) == "previous", "previous app was not restored")
        let stage = root.appendingPathComponent("stage.app")
        try fm.copyItem(at: payload, to: stage)
        try InstallFiles.commit(stage: stage, destination: destination)
        try InstallFiles.verify(destination, identifier: identifier, hash: hash); count += 1
        check(!fm.fileExists(atPath: stage.path), "staging copy left behind")
        let fresh = root.appendingPathComponent("Fresh.app")
        try fm.copyItem(at: payload, to: stage)
        try InstallFiles.commit(stage: stage, destination: fresh)
        try InstallFiles.verify(fresh, identifier: identifier, hash: hash); count += 1
        print("PASS: \(count) installer integrity/replacement/rollback checks")
    }
}
