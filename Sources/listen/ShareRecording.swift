import AppKit
import ListenKit
import UniformTypeIdentifiers

/// Handing a meeting or a note to another person, through the Mac's own share
/// sheet.
///
/// `Links.Sharing` is the neighbouring case and deliberately not this one: that
/// shares the *app*, one blurb and one URL, from Help and from About. This
/// shares what is on the page, and what is on the page is somebody's meeting.
///
/// **Text first, then a file URL, in one item.** Both are registered on one
/// `NSItemProvider` and the order is what decides who gets which. Messages,
/// Mail and Notes ask for text and take the markdown, which lands in the body
/// of the message where a transcript is read rather than as an attachment
/// nobody opens. AirDrop, Files and Save to Disk ask for a file and get
/// `Weekly sync.md`. A consumer takes the first representation it can use, so
/// registering the file first would turn a two-line note sent to a colleague
/// into a download, which is the thing this replaced.
///
/// **The second one has to be `public.file-url`, and a file *representation*
/// is not the same thing.** Measured against `NSSharingService.sharingServices
/// (forItems:)` over seven shapes of the same document: a bare file URL offers
/// AirDrop, and an `NSItemProvider` carrying `registerFileRepresentation(for:
/// .markdown)` offers Mail, Messages, Notes, Reminders, Freeform and Journal
/// and **no AirDrop at all**: no error and no empty row, just six services
/// where there should be seven. Registering a `.fileURL` representation
/// instead gives the full list, so that is what the file is offered as.
///
/// It is registered lazily, so the file is written when a service asks for it
/// rather than every time a menu opens over a meeting nobody shares. The full
/// table is in `.agents/notes/appkit.md`.
@MainActor
enum ShareRecording {
    /// Held for the life of the process, for `Sharing`'s reason: a picker
    /// released at the end of the function that showed it takes its own popover
    /// with it, and the sheet flickers instead of opening.
    private static var picker: NSSharingServicePicker?

    // MARK: - What is shared

    /// A meeting: what you wrote during it, what an agent wrote about it, then
    /// what was said.
    ///
    /// Notes above the transcript because that is the order of the page they
    /// were read on, and because they are the half a reader of a shared meeting
    /// wants first. An hour of dialogue with the summary at the bottom is an
    /// hour of dialogue.
    static func document(for recording: Recording) -> ShareDocument {
        let sections = Notes.list(about: recording).compactMap { note -> ShareDocument.Section? in
            let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            // The user's own note is titled `yoursTitle` on disk, which is the
            // word the sidebar row needs. As a heading in a document somebody
            // else will read, "Your notes" is about the wrong person.
            return .init(heading: Notes.isYours(note) ? "Notes" : note.title, body: body)
        }
        return ShareDocument(
            title: recording.metadata.title,
            subtitle: ShareDocument.subtitle(date: recording.date,
                                             duration: recording.metadata.duration,
                                             app: recording.appLabel),
            sections: sections,
            lines: recording.storedTurns.map {
                .init(speaker: SpeakerName.display($0.speaker), start: $0.start, text: $0.text)
            },
            stem: recording.exportName)
    }

    /// A note on its own, which is the page the sidebar opens for one.
    ///
    /// No subtitle. A note has a created date and nothing else worth a line,
    /// and the recordings it names are in its own body or not at all: this
    /// shares what somebody wrote, not a manifest of what it came from.
    static func document(for note: Note) -> ShareDocument {
        ShareDocument(title: note.title, sections: [.init(heading: "", body: note.body)])
    }

    // MARK: - The sheet

    /// The item the share sheet is given, with the title and the app's icon so
    /// the sheet's header says what is being sent.
    ///
    /// Without this it says "1 item", which is true and useless: the whole
    /// point of the header is the last look before something private leaves the
    /// machine, and it should name the meeting.
    static func item(_ document: ShareDocument) -> NSPreviewRepresentingActivityItem {
        let provider = NSItemProvider()
        provider.suggestedName = document.filename
        // Captured rather than read through the document each time: the load
        // handlers run later, off this call, and re-rendering an hour of
        // transcript per service the sheet lists is work nobody asked for.
        let markdown = document.markdown
        provider.registerDataRepresentation(for: .utf8PlainText, visibility: .all) { done in
            done(Data(markdown.utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(for: .fileURL, visibility: .all) { done in
            do { done(try document.writeTemporaryFile().dataRepresentation, nil) }
            catch { done(nil, error) }
            return nil
        }
        return NSPreviewRepresentingActivityItem(
            item: provider, title: document.title,
            image: nil, icon: NSApp.applicationIconImage)
    }

    /// The sheet, hanging off the control the person pressed.
    ///
    /// **This is presented by hand rather than through
    /// `NSSharingServicePicker.standardShareMenuItem`, and the anchor is the
    /// whole reason.** That item is the native one, it is what Finder's
    /// right-click Share is, and it was tried first: it builds its own popover
    /// and puts it near the top edge of the window, roughly half way across,
    /// which is nowhere near the ellipsis that was clicked. Reported on the
    /// running window as a sheet "in the middle of the screen" that does not
    /// look cast from anything. AppKit exposes no anchor, no rect and no
    /// delegate hook for it, and `show(relativeTo:of:preferredEdge:)` takes
    /// one, so the one line of code is what goes.
    static func present(_ document: ShareDocument, from view: NSView,
                        rect: NSRect? = nil, edge: NSRectEdge = .minY) {
        let picker = NSSharingServicePicker(items: [item(document)])
        Self.picker = picker
        picker.show(relativeTo: rect ?? view.bounds, of: view, preferredEdge: edge)
    }

    // MARK: - The clipboard

    /// The same markdown, straight to the pasteboard.
    ///
    /// The one action a person who keeps their meetings somewhere else performs
    /// every time, and the share sheet cannot offer it: Obsidian, a Linear
    /// ticket and a Slack message are all paste destinations and none of them
    /// is a sharing service.
    static func copy(_ document: ShareDocument) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.markdown, forType: .string)
    }
}
