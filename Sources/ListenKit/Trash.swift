import Foundation

/// Where deleted things go for a fortnight before they actually go.
///
/// **A deletion that arrives over sync is a deletion somebody made somewhere
/// else, and the receiving device has no way to know it was meant.** It looks
/// exactly like a mistake, a bug, or a library that briefly appeared empty. On
/// 13 Aug 2026 one of each happened at once: a stale sync state made a device
/// believe 73 recordings and 14 notes had been deleted, and both Macs obeyed
/// within the minute. Everything was recovered from a backup taken that
/// morning, except the one recording made after it.
///
/// `pushDeletions` now refuses to *send* a deletion that looks like a whole
/// library vanishing, which stops that particular cause. This is the other half
/// and it does not depend on guessing intent: whatever the cause, the files are
/// still here afterwards.
///
/// Fourteen days, because the question "where did that meeting go" is asked
/// within a day or two of it going, and because a fortnight of deleted audio is
/// the largest amount of disk this can quietly cost.
///
/// **Outside `recordings/` and in `neverSynced`**, so a trashed recording is
/// not a recording as far as `Library.all` is concerned and is never pushed
/// back to the container as a new one. Deleting it here does not undelete it
/// there: this is a local net, not a second opinion.
public enum Trash {
    public static let directory = ".trash"
    private static let days: TimeInterval = 14 * 86_400

    public static func root(in library: Library) -> URL {
        library.root.appendingPathComponent(directory)
    }

    /// Move rather than remove. Returns whether anything was there to move.
    ///
    /// Names the entry with the day it went, so `purge` can decide without
    /// trusting file dates, which a restore or a copy rewrites.
    @discardableResult
    public static func accept(_ item: URL, in library: Library, now: Date = Date()) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: item.path) else { return false }
        let day = Metadata.stamp(now).prefix(10)   // yyyy-MM-dd
        let folder = root(in: library).appendingPathComponent(String(day))
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)

        // A name that already exists means the same thing was deleted twice in
        // one day, which is rare and must not throw the second copy away.
        var destination = folder.appendingPathComponent(item.lastPathComponent)
        var attempt = 2
        while manager.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(
                "\(item.lastPathComponent).\(attempt)")
            attempt += 1
        }
        do {
            try manager.moveItem(at: item, to: destination)
            return true
        } catch {
            // Better gone than kept if moving is impossible, because the
            // alternative is a device that silently stops obeying deletions.
            try? manager.removeItem(at: item)
            return true
        }
    }

    /// Drop what has been in here longer than a fortnight.
    public static func purge(in library: Library, now: Date = Date()) {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(
            at: root(in: library), includingPropertiesForKeys: nil)) ?? []
        for day in entries {
            let name = day.lastPathComponent
            guard let when = Metadata.parser.date(from: name + "T00:00:00Z") else { continue }
            if now.timeIntervalSince(when) > days {
                try? manager.removeItem(at: day)
            }
        }
    }
}
