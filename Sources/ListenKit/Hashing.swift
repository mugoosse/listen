import Foundation
import CryptoKit

/// A content digest shared by CloudKit records, sidecars and merge decisions.
/// It lived in the LAN engine only by accident, so the transport can disappear
/// without taking the content identity rule with it.
public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
