import Foundation
import ListenKit

/// Tells sync that something in the library changed, whoever changed it.
///
/// This replaces a hook called from each writer, which was wrong twice before
/// it was replaced. First titles: `RecordingEvents.changed` fired from
/// `Recording.save` only, so a recording titled after transcription reached the
/// phone still called "Untitled". Then speakers: naming one rewrites
/// `transcript.json` and `turns.json` and never touches the metadata, so the
/// hook did not fire at all and the phone kept the old names until the poll.
/// Editing one sentence would have been the third, tags the fourth, and
/// whatever the app learns to do next the fifth.
///
/// The list was never going to be complete, because it is a list of every place
/// that will ever write to the library, maintained by hand, and nothing fails
/// when somebody forgets an entry. What fails is sync, quietly, minutes later,
/// on another device.
///
/// So the question changes from "did the author remember to say so" to "did
/// anything change", which the file system already knows. Any write under the
/// library root asks for a pass. That covers the CLI, the MCP server, an agent
/// writing a note, a file dropped in by hand, and every future writer nobody
/// has thought of yet.
///
/// **Cheap because the push is cheap.** A pass over an unchanged library costs
/// one incremental pull and a stamp comparison per recording, no sealing and no
/// round trips: see `CloudRecords.recordingStamp`. So a spurious wake costs
/// almost nothing, which is what makes it safe to be this indiscriminate.
///
/// **The pull writes to the library too**, so an arrival wakes this as well.
/// That is a pass that finds its own stamps already current and sends nothing,
/// which is one wasted comparison rather than a loop: `pull` records the stamp
/// of everything it writes for exactly this reason.
@MainActor
final class LibraryWatch {
    static let shared = LibraryWatch()

    private var stream: FSEventStreamRef?

    func start(root: URL) {
        guard stream == nil else { return }

        // Recursive, because the interesting files are two levels down in
        // `recordings/<id>/`. A `DispatchSource` on a directory descriptor
        // watches one directory and would miss every one of them.
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            Task { @MainActor in CloudSyncHost.shared.syncSoon() }
        }
        var context = FSEventStreamContext()
        guard let created = FSEventStreamCreate(
            nil, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // One second of coalescing inside the framework, on top of the five
            // second debounce in `syncSoon`. Saving a transcript writes several
            // files in a row and this is the cheapest place to fold them into
            // one event.
            1.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        ) else {
            trace("library watch: could not start")
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        trace("library watch: on")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
