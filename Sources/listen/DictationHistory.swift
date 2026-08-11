import Foundation

/// Append-only JSONL log of every dictation.
///
/// JSONL rather than a database so the file stays greppable and survives the
/// app entirely: `jq -r .text dictations.jsonl` gets you everything ever said.
///
/// Beside the library rather than inside a recording folder, next to
/// `dictionary.json` and `contacts.json`, and for the same reason those are
/// there: a dictation belongs to no meeting. It is also why this is not a
/// `Recording`. A dictation has no audio kept, no speakers, no transcript
/// sidecar and nothing to play back, so filing it as one would put a row in the
/// sidebar for every line somebody typed with their voice.
///
/// Ported from Speak's `History`, with Speak's file deliberately left alone:
/// this reads and writes Listen's own, and nothing migrates. See
/// `.agents/notes/dictation.md`.
enum DictationHistory {
    static var file: URL { Library.root.appendingPathComponent("dictations.jsonl") }

    struct Entry {
        let date: Date
        let duration: Double
        let text: String
        /// What the speech engine produced, when polishing or a correction
        /// changed it afterwards. nil when the text is untouched, so the file
        /// does not carry a duplicate of every line.
        ///
        /// This is the undo for a polish that went wrong: whatever the model
        /// made of it, the words that were actually said are still on disk.
        let raw: String?

        /// How often each dictionary rule fired, keyed by `Entry.countKey`.
        ///
        /// The same "count rather than assume" arrangement the meeting pipeline
        /// has: a rule nobody can measure is a rule nobody can argue about. Here
        /// it is also the only way to tell a term that is earning its place from
        /// one that has never matched anything.
        let fired: [String: Int]

        init(date: Date, duration: Double, text: String, raw: String? = nil,
             fired: [String: Int] = [:]) {
            self.date = date
            self.duration = duration
            self.text = text
            self.raw = raw
            self.fired = fired
        }
    }

    /// Seconds to one decimal place, as something `JSONSerialization` will
    /// actually print as one decimal place.
    ///
    /// Rounding the `Double` is not enough and this is worth knowing before
    /// "simplifying" it back. 6.6 has no exact binary representation, and
    /// Foundation prints a `Double` with enough digits to round-trip it, so
    /// `Double(String(format: "%.1f", x))` lands in the file as
    /// `6.5999999999999996`. Speak's version of this file did exactly that and
    /// shipped the noise into every line of its history.
    ///
    /// `NSDecimalNumber` carries the decimal value rather than the nearest
    /// binary one, and serialises from its own description. Measured, on the
    /// same value: `Double` gives 6.5999999999999996, `NSNumber(value: Float)`
    /// gives 6.5999999046325684, and this gives 6.6.
    ///
    /// It matters because the file is a documented artifact. `jq -r
    /// .duration_sec` is the point of writing JSONL rather than a database, and
    /// seventeen digits of nothing makes that output unreadable.
    static func tenths(_ seconds: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.1f", seconds))
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func append(_ e: Entry) {
        try? Library.prepare()

        var obj: [String: Any] = [
            "at": iso.string(from: e.date),
            "duration_sec": tenths(e.duration),
            "words": e.text.split(separator: " ").count,
            "text": e.text,
        ]
        // Absent rather than null when nothing changed the transcript. Old
        // readers ignore the key, and `jq -r .text` still gets what was pasted.
        if let raw = e.raw { obj["raw"] = raw }
        if !e.fired.isEmpty { obj["dictionary"] = e.fired }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }

        var line = data
        line.append(0x0a)

        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }

    /// Most recent entries, newest first. Reads the tail only.
    static func recent(_ n: Int) -> [Entry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(n).reversed().compactMap { line in
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = o["text"] as? String,
                  let at = o["at"] as? String else { return nil }
            return Entry(date: iso.date(from: at) ?? Date(timeIntervalSince1970: 0),
                         duration: o["duration_sec"] as? Double ?? 0,
                         text: t,
                         raw: o["raw"] as? String,
                         fired: o["dictionary"] as? [String: Int] ?? [:])
        }
    }
}
