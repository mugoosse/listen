import Foundation

/// What leaves the app when somebody hands a meeting or a note to another
/// person: one document, rendered once, wherever it is asked for.
///
/// There were two copies of this markdown before there were three. The window's
/// Export wrote one and `listen export --format md` wrote another, both
/// `# title`, a date line and `**Speaker** · 00:00`, and neither knew about the
/// other. The phone would have been the third, in a different language, on a
/// device the Mac cannot see. So the rendering lives here, in the half both
/// apps compile, and the CLI reads it too: a transcript shared from an iPhone
/// and the same transcript exported on the Mac are the same bytes.
///
/// **This struct holds no dates and no speaker labels.** Both are already
/// worded differently on the two platforms and neither wording is this file's
/// to own: the Mac says "Today at 14:31" through `Recording.when` and resolves
/// `A` to "Speaker A" through `SpeakerName`, the phone has its own answers, and
/// a third opinion here would silently disagree with the screen the reader just
/// came from. Callers hand over finished strings. What is shared is the shape.
public struct ShareDocument: Sendable {
    /// A block of prose above the transcript: the note somebody typed during
    /// the meeting, and whatever an agent wrote about it afterwards.
    public struct Section: Sendable {
        public var heading: String
        public var body: String

        public init(heading: String, body: String) {
            self.heading = heading
            self.body = body
        }
    }

    /// One turn, with its speaker already resolved to the name on screen.
    public struct Line: Sendable {
        public var speaker: String
        public var start: Double
        public var text: String

        public init(speaker: String, start: Double, text: String) {
            self.speaker = speaker
            self.start = start
            self.text = text
        }
    }

    public var title: String
    /// The line under the title: the date, the length, the app it was in.
    /// Empty is ordinary, and then the line is not drawn rather than drawn
    /// blank.
    public var subtitle: String
    public var sections: [Section]
    public var lines: [Line]
    /// The filename stem, before sanitising. Usually the title, and for an
    /// untitled recording the caller's dated stand-in: a folder of
    /// `Untitled.md`, `Untitled 2.md` is a folder nobody can read.
    public var stem: String

    public init(title: String, subtitle: String = "", sections: [Section] = [],
                lines: [Line] = [], stem: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.sections = sections
        self.lines = lines
        self.stem = stem ?? title
    }

    /// Nothing to hand over. A recording that has not been transcribed and that
    /// nobody has written about is the case, and the share control is hidden
    /// rather than offering an empty file.
    public var isEmpty: Bool {
        lines.isEmpty && sections.allSatisfy {
            $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The document, as markdown.
    ///
    /// **The transcript half is byte-for-byte what Export wrote before this
    /// existed**, and that is deliberate rather than nostalgic: `listen export
    /// --format md` renders through here now, and a script that has been diffing
    /// its output for six months should not discover a reformatting on the day
    /// sharing shipped.
    ///
    /// `## Transcript` appears only when there is something above it to be
    /// distinguished from. On a plain transcript the heading would be a label on
    /// the only thing in the file.
    public var markdown: String {
        var out = "# \(title)\n\n"
        if !subtitle.isEmpty { out += "\(subtitle)\n\n" }
        for section in sections {
            let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            // An empty heading is prose that is the whole document rather than
            // a part of one, which is what a note shared on its own is. Its
            // title is already the `#` at the top, and a second heading under
            // it would be the same words twice.
            if !section.heading.isEmpty { out += "## \(section.heading)\n\n" }
            out += "\(body)\n\n"
        }
        if !lines.isEmpty {
            if sections.contains(where: {
                !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                out += "## Transcript\n\n"
            }
            for line in lines {
                out += "**\(line.speaker)** · \(Self.stamp(line.start))\n\n\(line.text)\n\n"
            }
        }
        return out
    }

    /// What the file is called when the share sheet writes one, and what
    /// AirDrop, Files and Save to Disk put on the other end.
    ///
    /// `/` and `:` are the two characters a Mac filename may not hold, and a
    /// meeting called "Q3: budget / headcount" is an ordinary meeting. Newlines
    /// cannot reach a title through the window but can reach one through the
    /// CLI and through a note written by hand.
    public var filename: String {
        var name = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\n", "\r"] {
            name = name.replacingOccurrences(of: bad, with: "-")
        }
        if name.isEmpty { name = "Recording" }
        // 120 rather than the filesystem's 255: the extension, a `-2` from a
        // colliding save and a receiving system with a shorter limit all have
        // to fit after it.
        return String(name.prefix(120)) + ".md"
    }

    /// The line under the title: when it was recorded, how long it ran, and
    /// what it was recorded in.
    ///
    /// **Here rather than in either app**, unlike the title and the speaker
    /// names, and for the opposite reason. Those are already on screen in each
    /// platform's own wording and a third opinion would contradict what the
    /// reader just saw. This line is on no screen: the Mac's row says `42:10`
    /// because a list column has no room for more, the phone's says `42 min`,
    /// and a document that is read once by somebody who was not at the meeting
    /// wants the second. Left to the two callers it would have come out as two
    /// different sentences about the same meeting depending on which device
    /// pressed Share.
    public static func subtitle(date: Date?, duration: Double?,
                                app: String? = nil) -> String {
        var parts: [String] = []
        if let date {
            let f = DateFormatter()
            // Relative, the same as the Mac's detail pane: "Today at 14:31"
            // rather than a date somebody has to work out is today.
            f.doesRelativeDateFormatting = true
            f.dateStyle = .medium
            f.timeStyle = .short
            parts.append(f.string(from: date))
        }
        if let duration, duration > 0 { parts.append(spoken(duration)) }
        if let app, !app.isEmpty { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    /// How long it ran, in the units somebody would say out loud. The phone's
    /// `spoken`, which is the right wording for a document: nobody reading a
    /// transcript cares that the meeting was 41:33 rather than 42 minutes.
    public static func spoken(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) sec" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// `mm:ss`, and `h:mm:ss` once there is an hour to say.
    ///
    /// The Mac has `TranscriptFormat.stamp` and the phone has `clock`, both of
    /// which are for the screen. This one is for the document, so that the same
    /// meeting shared from either device stamps its turns identically.
    public static func stamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}

extension ShareDocument {
    /// The document on disk, ready to be handed to AirDrop, Files, Mail or
    /// anything else that wants a file rather than a string.
    ///
    /// Written into a directory of its own, and that is the whole reason this
    /// is not one call to `NSTemporaryDirectory()`. The file has to be called
    /// exactly `Weekly sync.md` when it lands on the other machine, and two
    /// meetings called the same thing shared a minute apart would otherwise
    /// collide, with the second silently arriving as the first. A fresh UUID
    /// directory per share makes the name free.
    ///
    /// Deliberately not cleaned up here. The share sheet reads the file after
    /// this function has returned, on a schedule nothing in this process can
    /// see, and a `defer` that removed it produced an AirDrop of nothing.
    /// `Recordings` is what the temporary directory is for and the system
    /// empties it.
    public func writeTemporaryFile() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("share-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(filename)
        try Data(markdown.utf8).write(to: url, options: .atomic)
        return url
    }
}
