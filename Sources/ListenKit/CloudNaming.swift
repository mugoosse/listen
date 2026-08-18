import Foundation
import CryptoKit

/// What things are called in the container, which is a privacy question rather
/// than a naming one.
///
/// **Sealing a payload does nothing for the label on the envelope.** Record
/// names, zone names, record type names and change timestamps are metadata, and
/// Apple holds all of them in the clear whatever the payload is encrypted with.
/// Left as the obvious implementation would leave it, a note's record name
/// would be its slug and a slug is its title, so a note called *"Therapy
/// session with Rita, medication review"* would sit on Apple's servers under
/// that name. A recording's would be its id, which is `yyyy-MM-dd-HHmmss`, and
/// hands over the exact minute of every meeting and the total count.
///
/// So names are derived rather than used:
///
///     recordName = HMAC-SHA256(pairingKey, "<type>:" + naturalKey)   hex
///
/// Deterministic, so compare-and-swap and `lastKnownRecord` still work and
/// every device derives the same name from the same key without being told it.
/// Opaque, so a subpoena to Apple returns a count and some change timestamps.
/// The real id or slug lives inside the sealed blob, where it was going anyway.
///
/// The type prefix is load-bearing rather than tidy. A chat id and a recording
/// id are the same shape on disk, so without it the same natural key could name
/// two different things, and with it they cannot collide even in principle.
///
/// **Rotating the key changes every derived name**, so a re-key is a full
/// re-upload. That is already true for other reasons, so it adds nothing new.
public enum CloudNaming {
    /// The container both apps read. Shared here rather than declared twice,
    /// because two copies of a permanent identifier is one copy that can be
    /// wrong.
    public static let containerID = "iCloud.eu.jacarandalabs.listen"

    /// Zones, named for what they are rather than what they hold.
    ///
    /// A zone name is metadata too, and `Voiceprints` would tell a reader that
    /// voiceprints are kept at all. Neutral names cost readability in the
    /// CloudKit Console, which is a genuine and accepted loss, and they are
    /// permanent because Production schema is append-only for ever.
    public enum Zone: String, Sendable, CaseIterable {
        /// Recordings, notes, and the library-level files.
        case library = "z1"
        /// `embeddings.json`, one per recording. Macs only.
        case voiceprints = "z2"
        /// One record per device.
        case devices = "z3"
        /// Audio in flight, deleted after ingest. Separate so that purging a
        /// 25 MB blob does not churn the library's change feed, and so device
        /// heartbeats and audio uploads cannot wake every device for each
        /// other's traffic.
        case transfer = "z4"
        /// The durable audio masters, one per recording, kept for ever.
        ///
        /// **Why not `z4`, which is where the plan said to put them.** `z4` is
        /// a pipe and `ingest` lists it whole on every pass, with no change
        /// token, deliberately: a transfer whose ingest failed has to be seen
        /// again, and a token would hide it for ever. A listing fetches each
        /// record with its assets attached, so one master per recording in
        /// `z4` would have every Mac downloading the entire audio library
        /// every two minutes. On this library that is 1.7 GB a pass.
        ///
        /// A zone costs nothing to add. Zones are created per account at
        /// runtime by `CloudKitStore.prepare`, so unlike a record type or a
        /// field they are **not** part of the schema that deploys to
        /// Production and never comes back. The record type is still `r5` and
        /// the bytes still ride `asset_mic_wav`, which is the half of that
        /// constraint that is permanent.
        ///
        /// Nothing subscribes to it either, and nothing ever lists it. A
        /// master is fetched by name, by a device that has already decided it
        /// wants those bytes, which is the one shape of traffic worth 25 MB.
        case masters = "z5"
    }

    /// Record types, opaque for the same reason as zones and permanent for the
    /// same reason again.
    public enum RecordType: String, Sendable, CaseIterable {
        case recording = "r1"
        case note = "r2"
        /// `contacts.json`, `dictionary.json`: one copy for the whole library.
        case blob = "r3"
        case device = "r4"
        case audioTransfer = "r5"
        case voiceprint = "r6"

        public var zone: Zone {
            switch self {
            case .recording, .note, .blob: return .library
            case .voiceprint: return .voiceprints
            case .device: return .devices
            case .audioTransfer: return .transfer
            }
        }
    }

    /// The opaque name for one record.
    ///
    /// `naturalKey` is the real id or slug, and it never leaves this function:
    /// what comes out is 64 hex characters that say nothing about what went in
    /// to anybody without the key.
    public static func recordName(_ type: RecordType, _ naturalKey: String,
                                  key: PairingKey) -> String {
        let message = Data((type.rawValue + ":" + naturalKey).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key.raw)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}
