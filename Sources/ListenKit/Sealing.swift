import Foundation
import CryptoKit

/// The paired key, and everything sealed under it.
///
/// Pairing happens once: the Mac generates 32 random bytes, shows them as a
/// code, the phone reads it. After that every payload is sealed on the device
/// that sends it and opened on the device that receives it, so the bytes on
/// the wire are ciphertext even on a network nobody trusts, and they would
/// still be ciphertext if the transport were later moved to CloudKit. That is
/// the point: the transport is allowed to be untrusted infrastructure, which
/// is what lets the claim in spec/01-product.md survive contact with one.
public struct PairingKey: Sendable, Equatable {
    public let raw: SymmetricKey

    public init(raw: SymmetricKey) { self.raw = raw }

    public static func generate() -> PairingKey {
        PairingKey(raw: SymmetricKey(size: .bits256))
    }

    /// The form a human retypes or a camera reads. Base32 without padding,
    /// upper case, in groups of four: it survives being read aloud over a
    /// phone call, which base64 does not because of case and `+/`.
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

    /// A stable token proving the holder has the key, sent on every request.
    ///
    /// Not a challenge-response, deliberately. The payloads are already sealed,
    /// so this token only decides whether the server will spend disk on a
    /// stranger, and a replay of it by somebody on the same wifi buys them a
    /// list of recording ids and nothing readable.
    public var token: String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("listen-sync-v1".utf8), using: raw)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    public func seal(_ data: Data) throws -> Data {
        try ChaChaPoly.seal(data, using: raw).combined
    }

    public func open(_ data: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: raw)
    }
}

public enum SealingError: Error, Sendable {
    case notPaired
    case badCode
}

/// Where the key lives on each device.
///
/// The Keychain on both, rather than a file or `UserDefaults`, because a
/// preferences plist is included in an unencrypted backup and readable by
/// anything running as the user. It is one small secret and it protects every
/// transcript the pair will ever exchange.
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

    public init(service: String = "com.mgo.listen-sync", account: String = "pairing-key",
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

#if os(macOS)
/// Where the pairing key lives on the Mac.
///
/// A file beside the library rather than the keychain, and that is a deliberate
/// step down in protection with a reason. Two processes need it: `listen-sync`,
/// which is a bare binary with no team identity, and Listen itself, which is a
/// signed app. A keychain item created by the first raises an authorisation
/// prompt when the second reads it, so the Devices pane would ask for a
/// password every time it drew.
///
/// What is given up is small. The key protects the network, not the disk: it
/// sits in the same directory as every transcript it could ever decrypt, so
/// anyone who can read the key can already read the library without it. On iOS
/// the keychain is still used, because there the threat is a backup rather than
/// a second local process.
public struct FileKeyStore: Sendable {
    public let library: Library
    public init(library: Library) { self.library = library }

    public var url: URL { library.root.appendingPathComponent(".pairing-key") }

    public func load() -> PairingKey? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return PairingKey(code: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    public func save(_ key: PairingKey) -> Bool {
        do {
            try FileManager.default.createDirectory(at: library.root,
                                                    withIntermediateDirectories: true)
            try key.code.write(to: url, atomically: true, encoding: .utf8)
            // 0600 before anything else can open it.
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}
#endif

/// Getting the pairing key from where it is to where it should be.
///
/// It lives in a file beside the library, because `listen-sync` was a bare
/// binary and a keychain item made by one process prompts for authorisation
/// when a differently-signed one reads it. That constraint died when sync moved
/// inside the app, so the key is free to go to the iCloud Keychain, which is
/// what makes a second Mac need nothing typed.
///
/// **It moves by being copied, not by being moved.** The LAN transport is still
/// running and still reads the file, and every device already paired is paired
/// against it. Deleting it would take a working setup away to tidy something
/// up, which is a bad trade at any time and a worse one mid-migration. The file
/// goes at Phase 6, with the transport that needs it.
public enum KeyMigration {
    /// Copy the file key into the shared iCloud Keychain item, once, if the
    /// keychain has none. Returns true if it did something.
    ///
    /// Never the other way round, and never overwriting: a key already in the
    /// keychain came either from this Mac or from another of the user's devices
    /// through iCloud, and in both cases it is at least as authoritative as a
    /// file on one disk. Overwriting it with a local file is how a second Mac
    /// would silently unpair the first.
    @discardableResult
    public static func adoptFileKey(from library: Library) -> Bool {
        #if os(macOS)
        guard KeyStore.shared.load() == nil else { return false }
        guard let existing = FileKeyStore(library: library).load() else { return false }
        return KeyStore.shared.save(existing)
        #else
        return false
        #endif
    }
}
