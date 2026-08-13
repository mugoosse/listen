import Foundation
import ListenKit

/// Copies of the library, taken here rather than hoped for elsewhere.
///
/// **iCloud is a replica, not a backup.** It holds everything except the audio,
/// sealed, and it has no history: a deletion propagates to it within seconds
/// and from it to every other device within seconds more. That is the whole
/// point of sync and it is exactly why it cannot double as the safety net. On
/// 13 Aug 2026 a stale sync state convinced one device that 73 recordings had
/// been deleted; the container agreed, both Macs agreed, and what the library
/// came back from was a copy someone had happened to take that morning.
///
/// Three tiers, because the data has two shapes and they want different things.
///
/// **Audio is large and never changes once written.** Versioning it is
/// meaningless, so it needs one durable copy and protection from deletion. An
/// APFS clone gives both for nothing: `cp -c` copies the directory entries and
/// leaves the file contents shared, so an eleven gigabyte snapshot occupies the
/// space of its metadata until something diverges. Measured on this library:
/// three clones of eleven gigabytes each, and the volume reported the same free
/// space afterwards as before. What it does cost is deletion, because blocks
/// belonging to a deleted recording are held until the last clone naming them
/// ages out.
///
/// **Sidecars are small and change constantly**, and they are the part that
/// cannot be recovered by any other means: transcripts, titles, notes, and who
/// said what. Two megabytes for the whole library, so a month of daily copies
/// is sixty megabytes and worth having at a longer retention than the clones.
///
/// **Neither survives the disk.** Both live on the same volume as the library,
/// so they protect against mistakes, bugs and deletions, and against nothing
/// physical. Time Machine to another disk is the answer to that, and it is
/// deliberately not this app's job: the same split Obsidian makes, for the same
/// reason, which is that an app that tries to become a backup product is worse
/// at it than the thing built for it.
@MainActor
enum Backups {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Backups/Listen")
    }

    private static let clonesKept = 7
    private static let sidecarsKept = 30

    /// Once a day, on launch and on the sync host's timer.
    ///
    /// Keyed on the date rather than an interval, so a Mac opened twice a day
    /// takes one and a Mac left open for a week still takes one per day.
    static func runIfDue(now: Date = Date()) {
        let day = String(ListenKit.Metadata.stamp(now).prefix(10))
        let marker = root.appendingPathComponent(".last")
        let last = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard last != day else { return }
        run(day: day)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(day.utf8).write(to: marker, options: .atomic)
    }

    /// Take one now, whatever the marker says. For `listen backup --now`.
    static func runNow(at now: Date = Date()) {
        run(day: String(ListenKit.Metadata.stamp(now).prefix(10)))
    }

    static func run(day: String) {
        let library = ListenKit.Library.mac()
        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)

        // The clone. `-c` asks for a copy-on-write clone and fails rather than
        // falling back silently, so `-R` is the second attempt: on a volume
        // that is not APFS this is a real copy and the honest thing is for it
        // to be slow rather than absent.
        let clone = root.appendingPathComponent("library-\(day)")
        if !manager.fileExists(atPath: clone.path) {
            if !copy(library.root, to: clone, cloning: true) {
                _ = copy(library.root, to: clone, cloning: false)
            }
        }

        // The sidecars, which is the part no clone of this disk can replace if
        // the disk goes. Small enough to move somewhere else by hand.
        let tarball = root.appendingPathComponent("sidecars-\(day).tar.gz")
        if !manager.fileExists(atPath: tarball.path) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            task.currentDirectoryURL = library.root
            task.arguments = ["--exclude=*.wav", "--exclude=*.m4a", "--exclude=*.flac",
                              "--exclude=staging", "--exclude=" + Trash.directory,
                              "-czf", tarball.path, "recordings", "notes"]
            try? task.run()
            task.waitUntilExit()
        }

        prune(prefix: "library-", keeping: clonesKept)
        prune(prefix: "sidecars-", keeping: sidecarsKept)
        trace("backups: \(day)")
    }

    private static func copy(_ from: URL, to: URL, cloning: Bool) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/cp")
        task.arguments = cloning ? ["-Rc", from.path, to.path] : ["-R", from.path, to.path]
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// Newest kept, oldest dropped. Sorted by name, which is a date, so this
    /// does not depend on file dates that a copy or a restore rewrites.
    private static func prune(prefix: String, keeping: Int) {
        let manager = FileManager.default
        let all = ((try? manager.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(keeping) { try? manager.removeItem(at: old) }
    }

    /// One line for the settings pane, in the words somebody would use.
    ///
    /// A date, not a count. "7 copies" invites "of what, and how big",
    /// which is the question this is here to answer rather than raise.
    static var summary: String {
        let all = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
        let newest = all.filter { $0.hasPrefix("library-") }.max()
        guard let newest else { return "No copy yet. The first is made today." }
        let day = String(newest.dropFirst("library-".count))
        let today = String(ListenKit.Metadata.stamp(Date()).prefix(10))
        return day == today ? "Last copied today." : "Last copied \(day)."
    }

    /// What is held, for somebody deciding whether to trust it.
    static func describe() -> String {
        let manager = FileManager.default
        let all = ((try? manager.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent).sorted(by: >)
        let clones = all.filter { $0.hasPrefix("library-") }
        let sidecars = all.filter { $0.hasPrefix("sidecars-") }
        guard !clones.isEmpty || !sidecars.isEmpty else {
            return "no backups yet, at \(root.path)"
        }
        var lines = [root.path, ""]
        lines.append("  \(clones.count) full snapshot(s), newest \(clones.first ?? "none")")
        lines.append("  \(sidecars.count) sidecar copy(s), newest \(sidecars.first ?? "none")")
        lines.append("")
        lines.append("  Snapshots are APFS clones: they share their contents with")
        lines.append("  the library, so they cost almost no disk until it changes.")
        lines.append("  Neither survives this disk failing. Time Machine does.")
        return lines.joined(separator: "\n")
    }
}
