import AppKit
import Security

struct InstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum InstallFiles {
    static func verify(_ app: URL, identifier: String, hash: String) throws {
        guard Bundle(url: app)?.bundleIdentifier == identifier else {
            throw InstallFailure(message: "这个文件不是安装包内的 Toss。 / This is not the bundled Toss app.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw InstallFailure(message: "Toss 安装包验证失败，请重新下载。 / The app signature could not be verified.")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let digest = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              digest.map({ String(format: "%02x", $0) }).joined() == hash else {
            throw InstallFailure(message: "Toss 与这个安装器的版本不一致。 / This app does not match the installer.")
        }
    }

    // Keep the previous copy until the verified replacement is in place. A failed
    // rename restores it; a successful replacement sends it to recoverable Trash.
    static func commit(stage: URL, destination: URL) throws {
        let fm = FileManager.default
        let backup = destination.deletingLastPathComponent().appendingPathComponent(".Toss-previous-" + UUID().uuidString + ".app")
        let exists = fm.fileExists(atPath: destination.path)
        if exists { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: stage, to: destination) }
        catch {
            if exists { try fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if exists {
            // If Trash is unavailable, retain the backup rather than deleting it.
            _ = try? fm.trashItem(at: backup, resultingItemURL: nil)
        }
    }
}

