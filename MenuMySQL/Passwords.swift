import CryptoKit
import Foundation

/// Database passwords, by account (user@host:port), kept by the app itself: encrypted with
/// AES-GCM in ~/Library/Application Support/MenuMySQL, under a random key beside them, both
/// readable only by this user. Unlike the keychain, it doesn't ask again after each new build
/// (an app without an Apple team ID is a new app to the keychain every time it's built).
/// Passwords the keychain held from earlier versions move here the first time they're needed.
enum Passwords {
    private struct Store: Codable {
        var passwords: [String: String] = [:]
        /// Accounts already looked for in the keychain, so it's asked about each at most once.
        var checkedKeychain: Set<String> = []
    }

    static var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MenuMySQL", isDirectory: true)
    private static var keyURL: URL { folder.appendingPathComponent("key") }
    private static var storeURL: URL { folder.appendingPathComponent("passwords") }

    static func password(for account: String) -> String? {
        var store = load()
        if let password = store.passwords[account] { return password }
        guard !store.checkedKeychain.contains(account) else { return nil }
        store.checkedKeychain.insert(account)
        if let old = Keychain.password(for: account) { store.passwords[account] = old }
        save(store)
        return store.passwords[account]
    }

    static func save(_ password: String, for account: String) {
        var store = load()
        store.passwords[account] = password
        store.checkedKeychain.insert(account)
        save(store)
    }

    static func delete(for account: String) {
        var store = load()
        store.passwords[account] = nil
        store.checkedKeychain.insert(account)   // and not brought back from the keychain
        save(store)
    }

    // MARK: Files

    private static func load() -> Store {
        guard let sealed = try? Data(contentsOf: storeURL), let key = key(),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return Store() }
        return store
    }

    private static func save(_ store: Store) {
        guard let key = key(), let data = try? JSONEncoder().encode(store),
              let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        write(sealed, to: storeURL)
    }

    /// The key, made the first time.
    private static func key() -> SymmetricKey? {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        guard write(key.withUnsafeBytes { Data($0) }, to: keyURL) else { return nil }
        return key
    }

    /// Writes a file only this user can read, in a folder only this user can open.
    @discardableResult
    private static func write(_ data: Data, to url: URL) -> Bool {
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try data.write(to: url, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
