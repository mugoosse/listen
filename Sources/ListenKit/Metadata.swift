import Foundation

/// A recording's `metadata.json`, in exactly the shape Listen writes.
///
/// Every field but `id` is optional here even where the Mac always writes it,
/// because this type has to decode files written by four years of Listen
/// versions and a missing key must not lose a recording. `Recording.load` on
/// the Mac skips a folder whose metadata will not decode, silently, so a
/// stricter type here would make meetings disappear rather than complain.
///
/// The phone **creates** metadata for recordings it made and otherwise treats
/// this as read-only. Edits made on the phone travel as a `MetadataPatch`, so
/// a field this struct has never heard of cannot be erased by a round trip
/// through a device that is a version behind. That is not hypothetical: the
/// library already carries `calendar_event_id`, `calendar_people` and
/// `app_name`, none of which the phone has any use for.
public struct Metadata: Codable, Sendable, Equatable {
    public var id: String
    public var recorded_at: String?
    public var duration: Double?
    public var title: String?
    public var state: String?
    public var source: String?
    public var room: Bool?
    public var room_auto: Bool?
    public var asr_model: String?
    public var tags: [String]?
    public var auto_named: [String]?
    public var app_bundle_id: String?
    public var app_name: String?
    public var calendar_event_id: String?

    /// Which device made the transcript, and how long it took.
    ///
    /// Provenance rather than state. `state` says what stage the recording has
    /// reached; these say who did the work and when, which is the question a
    /// library spread over three devices actually raises. On a single Mac they
    /// are noise, so nothing shows them until there is more than one device.
    ///
    /// In the sealed payload, so they cost no CloudKit schema at all. That is
    /// the whole reason a new field goes in `metadata.json`: see `CloudNaming`.
    ///
    /// The **name** as well as the id, because a device record can be forgotten
    /// from the roster and a Mac can be renamed, and "transcribed on a device
    /// that is not in the list" is worse than a name that has since changed.
    /// The id is what code compares; the name is what a person reads.
    public var transcribed_by: String?
    public var transcribed_on: String?
    public var transcribe_started: String?
    public var transcribe_finished: String?
    // `calendar_people` is deliberately absent. On disk it is a list of objects
    // with `email`, `name`, `is_me` and `is_organizer`, nothing here reads it,
    // and declaring it as `[String]` is what taught this file the lesson below.

    // MARK: - Decoding

    /// Hand-written so a field of an unexpected shape is nil rather than fatal.
    ///
    /// The synthesised `Codable` throws on a type mismatch, and
    /// `Recording.load` turns any throw into nil, and `Library.all` is a
    /// `compactMap` over that. So one field of the wrong shape does not produce
    /// an error: it makes the whole recording **silently disappear**.
    ///
    /// Measured, and it was not hypothetical. `calendar_people` was declared
    /// `[String]?` and is a list of objects on disk, so every meeting matched
    /// to a calendar event, which is most real meetings, was missing from the
    /// phone with nothing reported anywhere.
    ///
    /// `try?` per field means a future version of Listen can add anything it
    /// likes and the worst case is that this app ignores it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The one field that must decode. Without an id there is no recording.
        id = try c.decode(String.self, forKey: .id)
        recorded_at = try? c.decodeIfPresent(String.self, forKey: .recorded_at)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        room = try? c.decodeIfPresent(Bool.self, forKey: .room)
        room_auto = try? c.decodeIfPresent(Bool.self, forKey: .room_auto)
        asr_model = try? c.decodeIfPresent(String.self, forKey: .asr_model)
        tags = try? c.decodeIfPresent([String].self, forKey: .tags)
        auto_named = try? c.decodeIfPresent([String].self, forKey: .auto_named)
        app_bundle_id = try? c.decodeIfPresent(String.self, forKey: .app_bundle_id)
        app_name = try? c.decodeIfPresent(String.self, forKey: .app_name)
        calendar_event_id = try? c.decodeIfPresent(String.self, forKey: .calendar_event_id)
        transcribed_by = try? c.decodeIfPresent(String.self, forKey: .transcribed_by)
        transcribed_on = try? c.decodeIfPresent(String.self, forKey: .transcribed_on)
        transcribe_started = try? c.decodeIfPresent(String.self, forKey: .transcribe_started)
        transcribe_finished = try? c.decodeIfPresent(String.self, forKey: .transcribe_finished)
    }

    public init(id: String, recordedAt: Date, duration: Double, title: String,
                room: Bool, source: String = "iphone") {
        self.id = id
        self.recorded_at = Metadata.stamp(recordedAt)
        self.duration = duration
        self.title = title
        self.state = State.pending.rawValue
        self.source = source
        self.room = room
        // The person holding the phone answered the question at capture time,
        // so `Pipeline.decideRoom` has nothing to guess. `asr.md` records that
        // a peak test cannot tell a chime from a conversation, which is the
        // uncertainty this removes rather than improves on.
        self.room_auto = false
    }

    public enum State: String, Sendable {
        case unconfirmed, pending, transcribing, needs_labelling, done, failed
    }

    /// The state, reconciled against what is actually on disk.
    ///
    /// Mirrors `Recording.effectiveState` on the Mac and for the same reason:
    /// the field is a cache and the files are the truth. A phone that was
    /// killed mid-upload leaves `pending` behind for ever otherwise.
    public func effectiveState(hasTranscript: Bool, hasTurns: Bool) -> State {
        let stored = State(rawValue: state ?? "") ?? .pending
        guard hasTranscript else { return stored == .unconfirmed ? .unconfirmed : .pending }
        switch stored {
        case .pending, .transcribing, .failed: return hasTurns ? .needs_labelling : .done
        case .unconfirmed, .needs_labelling, .done: return stored
        }
    }

    public var isRoom: Bool { room == true }

    public var date: Date? {
        guard let recorded_at else { return nil }
        return Metadata.parser.date(from: recorded_at)
    }

    // MARK: - Identifiers

    /// `2026-08-12-143005-A1B2`, the same shape and the same local-time basis
    /// the Mac uses. The library sorts on this string, so a phone that
    /// generated UTC-based ids would interleave its recordings wrongly in the
    /// sidebar without anything reporting an error.
    public static func newID(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let suffix = String(format: "%04X", UInt16.random(in: 0...UInt16.max))
        return f.string(from: date) + "-" + suffix
    }

    /// Whether a string is an id this library will turn into a folder name.
    ///
    /// An id arrives from somewhere else and becomes a path. `folder(for:)` is
    /// `recordings.appendingPathComponent(id)`, and `appendingPathComponent`
    /// resolves `..`, so an id of `../../../../tmp/x` addresses a directory
    /// outside the library and every read, write and delete keyed on that id
    /// lands there. Nothing checked, on any op.
    ///
    /// The check belongs on the write to disk rather than on the transport,
    /// because the transport is replaceable and the hole is not: when the id
    /// arrives decoded from a sealed CloudKit blob instead of a JSON header it
    /// is the same string doing the same thing, and the same guard has to hold.
    ///
    /// Exactly the shape `newID` makes, which every one of the 61 recordings in
    /// the real library matches. Hex is accepted in either case because
    /// `%04X` writes uppercase and nothing should turn on that.
    public static func isValidID(_ id: String) -> Bool {
        // yyyy-MM-dd-HHmmss-XXXX. The field lengths below are the whole rule;
        // a separate check on the total is a second place to get it wrong, and
        // the first draft of this got it wrong by one and refused every real id.
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return false }
        let lengths = [4, 2, 2, 6, 4]
        for (part, length) in zip(parts, lengths) {
            guard part.count == length else { return false }
        }
        guard parts[0...3].allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return false }
        return parts[4].allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    public static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    public static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

/// An edit made on the phone, applied by the Mac to the file it holds.
///
/// A patch rather than a whole document because the Mac's copy is canonical
/// and carries fields the phone does not model. Sending the whole struct back
/// would erase a calendar match every time somebody renamed a meeting on a
/// train.
public struct MetadataPatch: Codable, Sendable {
    public var id: String
    public var title: String?
    public var tags: [String]?

    public init(id: String, title: String? = nil, tags: [String]? = nil) {
        self.id = id; self.title = title; self.tags = tags
    }

    public func apply(to meta: inout Metadata) {
        if let title { meta.title = title }
        if let tags { meta.tags = tags }
    }
}
