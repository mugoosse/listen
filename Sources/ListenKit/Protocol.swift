import Foundation

/// The wire protocol between the phone and the Mac.
///
/// Length-prefixed frames carrying a JSON header and an optional binary body,
/// rather than HTTP. Both ends are ours, so HTTP would buy nothing but a
/// parser to get wrong, and the one thing that genuinely matters here is that
/// a truncated transfer is unambiguous. A frame is either complete or it is
/// not.
///
/// The body is always sealed (`Sealing.swift`), so the transport carries
/// ciphertext and could be replaced by CloudKit or anything else without
/// changing what a network observer can learn.
public enum Wire {
    /// `[4-byte big-endian header length][header JSON][4-byte body length][body]`
    public static func frame(_ header: Data, body: Data) -> Data {
        var out = Data()
        out.append(contentsOf: withUnsafeBytes(of: UInt32(header.count).bigEndian, Array.init))
        out.append(header)
        out.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init))
        out.append(body)
        return out
    }

    /// A single 64 MB ceiling on any one frame. An hour of 16 kHz Int16 audio
    /// is 115 MB, so audio is chunked rather than sent whole: a phone that
    /// loses wifi three quarters of the way through an upload must not have to
    /// start again, and a server must not be persuadable to allocate a
    /// gigabyte by a header claiming one.
    public static let maxFrame = 64 * 1024 * 1024
    public static let chunkSize = 4 * 1024 * 1024
}

public struct Request: Codable, Sendable {
    public var op: Op
    public var token: String
    public var id: String?
    public var file: String?
    public var offset: Int?
    public var last: Bool?
    public var metadata: Metadata?
    public var patch: MetadataPatch?
    public var note: Note?
    public var expecting: String?
    /// Who is asking. Stable for the life of an install, so the Mac can list
    /// what is connected and take a lost phone off the list.
    public var deviceID: String?
    public var deviceName: String?

    public enum Op: String, Codable, Sendable {
        case hello          // who are you, and do we share a key
        case manifest       // everything you have, and how fresh
        case get            // one sidecar file
        case put            // one chunk of one file the phone recorded
        case finish         // publish the folder: metadata.json written last
        case ack            // audio is safely here, the phone may delete it
        case patch          // title and tags, applied to the Mac's own copy
        case notes          // every note
        case putNote        // write one, with compare-and-swap
        case deleteNote     // remove one, on the Mac too
        case deleteRecording // and everything in its folder
    }

    public init(op: Op, token: String) { self.op = op; self.token = token }
}

public struct Response: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var name: String?
    public var manifest: Manifest?
    public var notes: [Note]?
    public var conflict: Note?

    public init(ok: Bool) { self.ok = ok }
    public static func failure(_ message: String) -> Response {
        var r = Response(ok: false); r.error = message; return r
    }
}

/// What the Mac holds, in the smallest form that lets the phone work out what
/// it is missing.
///
/// Sidecars carry a digest because they change: a transcript is rewritten when
/// somebody renames a speaker, and size alone would miss a rename from `A` to
/// `B`. Audio carries only a flag, because the phone never pulls audio and the
/// only question it ever asks is whether the Mac has it yet.
public struct Manifest: Codable, Sendable {
    public var recordings: [Entry]
    public var notes: [NoteStamp]

    public struct Entry: Codable, Sendable {
        public var id: String
        public var title: String?
        public var recorded_at: String?
        public var duration: Double?
        public var state: String
        public var room: Bool?
        public var hasAudio: Bool
        /// filename to SHA-256, sidecars only
        public var digests: [String: String]

        public init(id: String, title: String?, recorded_at: String?, duration: Double?,
                    state: String, room: Bool?, hasAudio: Bool, digests: [String: String]) {
            self.id = id; self.title = title; self.recorded_at = recorded_at
            self.duration = duration; self.state = state; self.room = room
            self.hasAudio = hasAudio; self.digests = digests
        }
    }

    public struct NoteStamp: Codable, Sendable {
        public var slug: String
        public var updated: String
        /// The content digest. What every decision is made on; `updated` is
        /// for display only. See `Note.version`.
        public var version: String
        public init(slug: String, updated: String, version: String) {
            self.slug = slug; self.updated = updated; self.version = version
        }
    }

    public init(recordings: [Entry], notes: [NoteStamp]) {
        self.recordings = recordings; self.notes = notes
    }
}

/// What the server will hand out, which is the phone's set and nothing else.
///
/// **Enforcement lives on the machine that owns the data**, and that is the
/// strong form of the guarantee: `embeddings.json` is not withheld because the
/// phone declines to ask for it, it is withheld because this Mac refuses to
/// send it. Worth naming, because that asymmetry does not survive a move to a
/// shared container, where the only thing keeping voiceprints off a phone is
/// the phone's own code run against a store it is fully authenticated to.
public let servedFiles = DevicePolicy.phone.sidecars
