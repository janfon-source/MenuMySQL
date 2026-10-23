import Foundation
import Security

/// Passwords earlier versions kept in the login keychain, by account (user@host:port). Only read
/// now, once per account, to move them to the app's own store (Passwords).
enum Keychain {
    private static let service = "com.jeff.menumysql"

    static func password(for account: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
