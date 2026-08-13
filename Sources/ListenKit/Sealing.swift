import Foundation
import CryptoKit

/// The shared key, and everything sealed under it.
///
/// The Mac generated 32 random bytes once and copied them into
/// iCloud Keychain. Every payload is sealed on the device that sends it and
/// opened on the device that receives it, so CloudKit stores ciphertext. The
/// transport is allowed to be untrusted infrastructure, which is what lets the
/// claim in spec/01-product.md survive contact with one.
public struct PairingKey: Sendable, Equatable {
    public let raw: SymmetricKey

    public init(raw: SymmetricKey) { self.raw = raw }

    public static func generate() -> PairingKey {
        PairingKey(raw: SymmetricKey(size: .bits256))
    }

    /// The Base32 form retained by the legacy file fallback. Upper case and
    /// groups of four keep the migration source readable and deterministic.
    public var code: String {
        let bytes = raw.withUnsafeBytes { Array($0) }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, acc = 0, out = ""
        for b in bytes {
            acc = acc << 8 | Int(b); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(acc >> bits) & 31]) }
        }
        if bits > 0 { out.append(alphabet[(acc << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map {
            String(Array(out)[$0..<min($0 + 4, out.count)])
        }.joined(separator: "-")
    }

    public init?(code: String) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var index: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { index[c] = i }
        var bits = 0, acc = 0, bytes: [UInt8] = []
        for c in code.uppercased() where c != "-" && c != " " {
            guard let v = index[c] else { return nil }
            acc = acc << 5 | v; bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((acc >> bits) & 0xFF)) }
        }
        guard bytes.count == 32 else { return nil }
        self.raw = SymmetricKey(data: Data(bytes))
    }

    public func seal(_ data: Data) throws -> Data {
        try ChaChaPoly.seal(data, using: raw).combined
    }

    public func open(_ data: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: raw)
    }
}

/// Where the key lives on each device.
///
/// The Keychain on both, rather than a file or `UserDefaults`, because a
/// preferences plist is included in an unencrypted backup and readable by
/// anything running as the user. It is one small secret and it protects every
/// transcript the devices will ever exchange.
public struct KeyStore: Sendable {
    let service: String
    let account: String
    /// Whether this item rides iCloud Keychain to the user's other devices.
    ///
    /// **This is what makes setting up a second Mac "sign in and open
    /// Listen".** The key arrives by itself, Apple cannot read it, and there is
    /// nothing to scan and nothing to type.
    ///
    /// One fallback survives and it is the smallest possible one: iCloud
    /// Keychain is a separate toggle from iCloud Drive, so somebody can have
    /// CloudKit working and key sync switched off. For them the key has nowhere
    /// to arrive from, and without a path they would watch sync connect and
    /// then fail to decrypt anything, which is the worst way to fail. Hence the
    /// typed code, and nothing more than that.
    let synchronizable: Bool

    public init(service: String, account: String,
                synchronizable: Bool = false) {
        self.service = service; self.account = account
        self.synchronizable = synchronizable
    }

    /// The shared item both apps read.
    ///
    /// Named after the team rather than after either app, because
    /// `com.mgo.listen` and `eu.jacarandalabs.listen` have different bundle
    /// identifiers and only the team prefix is common to both. The access group
    /// in the entitlements is what permits it; this is what finds it.
    public static let shared = KeyStore(service: "eu.jacarandalabs.listen",
                                        account: "pairing-key",
                                        synchronizable: true)

    public func load() -> PairingKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
            // **macOS defaults to the legacy file-based keychain**, which has
            // no iCloud Keychain and no access groups. Without this the item is
            // written to a keychain that cannot sync, `SecItemAdd` reports
            // success, and the key simply never arrives on the second Mac: a
            // failure with no error anywhere, on the one path whose whole
            // purpose is that nothing has to be typed.
            query[kSecUseDataProtectionKeychain as String] = true
        }
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return PairingKey(raw: SymmetricKey(data: data))
    }

    @discardableResult
    public func save(_ key: PairingKey) -> Bool {
        let data = key.raw.withUnsafeBytes { Data($0) }
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if synchronizable {
            base[kSecAttrSynchronizable as String] = true
            base[kSecUseDataProtectionKeychain as String] = true
        }
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // `AfterFirstUnlock` rather than `WhenUnlocked`, because sync has to
        // work while the Mac is closed and the phone is in a pocket. A
        // synchronizable item cannot use a `ThisDeviceOnly` class at all,
        // which is the point of it.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func clear() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
            query[kSecUseDataProtectionKeychain as String] = true
        }
        SecItemDelete(query as CFDictionary)
    }
}
