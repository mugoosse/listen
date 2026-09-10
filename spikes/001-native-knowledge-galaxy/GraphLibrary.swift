import Foundation
import ListenKit

struct LibraryGraphSource: Sendable {
    var id: String
    var kind: String
    var title: String
    var relativePath: String
    var recordings: [String]
}

struct LibraryGraphInput: Sendable {
    var cards: [ContextCard] = []
    var sources: [LibraryGraphSource] = []
    var skipped = 0
    var snapshotPresent = false
}

enum GraphLibrary {
    enum Problem: Error, LocalizedError {
        case invalidRoot, unsafePath, sourceUnavailable
        var errorDescription: String? {
            switch self {
            case .invalidRoot: return "Choose an existing Listen library directory."
            case .unsafePath: return "Source path is not a safe library-relative path."
            case .sourceUnavailable: return "The source is missing, excluded, or no longer valid."
            }
        }
    }
    static func read(root: URL) throws -> LibraryGraphInput {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { throw Problem.invalidRoot }
        var result = LibraryGraphInput()
        let fm = FileManager.default
        func children(_ relative: String) throws -> [URL] {
            let url = try safeURL(relative, root: root)
            guard fm.fileExists(atPath: url.path) else { return [] }
            return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for folder in try children("recordings") {
            let id = folder.lastPathComponent
            guard Metadata.isValidID(id) else { result.skipped += 1; continue }
            let path = "recordings/\(id)/metadata.json"
            guard let url = try? safeURL(path, root: root), let bytes = try? boundedData(url),
                  let metadata = try? JSONDecoder().decode(Metadata.self, from: bytes), metadata.id == id else {
                result.skipped += 1; continue
            }
            result.sources.append(LibraryGraphSource(id: "rec:" + id, kind: "recording", title: metadata.title ?? id,
                relativePath: path, recordings: []))
        }
        let recordingIDs = Set(result.sources.map { String($0.id.dropFirst("rec:".count)) })
        for file in try children("notes") where file.pathExtension == "md" {
            let slug = file.deletingPathExtension().lastPathComponent, path = "notes/" + file.lastPathComponent
            guard Note.isValidSlug(slug), let url = try? safeURL(path, root: root),
                  let bytes = try? boundedData(url), let text = String(data: bytes, encoding: .utf8),
                  MemoryPreferences.sourceAllowed("note:" + slug, root: root),
                  let note = Note.parse(slug: slug, text) else { result.skipped += 1; continue }
            result.sources.append(LibraryGraphSource(id: "note:" + slug, kind: "note", title: note.title,
                relativePath: path, recordings: Array(Set(note.recordings.filter { Metadata.isValidID($0) && recordingIDs.contains($0) })).sorted()))
        }
        // Use the existing owner projection and verification rules. Never open
        // ContextDatabase here: its initializer performs migrations and writes.
        for path in [ContextSnapshot.filename, ContextSync.editsFilename, MemoryPreferences.filename] {
            _ = try safeURL(path, root: root)
        }
        if let snapshot = try ContextSnapshot.load(root: root) {
            result.snapshotPresent = true
            for paths in snapshot.proofs.values { for path in paths.keys { _ = try safeURL(path, root: root) } }
            result.cards = try ContextSync.readCards(root: root)
        }
        return result
    }

    static func safeURL(_ relative: String, root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
              !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { throw Problem.unsafePath }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var candidate = base
        // Resolve each existing ancestor, including a symlink whose final
        // target file does not exist. Resolving only the full URL misses that.
        for component in relative.split(separator: "/") {
            candidate.appendPathComponent(String(component))
            candidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard candidate.pathComponents.starts(with: base.pathComponents), candidate.pathComponents.count > base.pathComponents.count else { throw Problem.unsafePath }
        }
        return candidate
    }

    static func evidenceURL(source: String, relativePath: String, root: URL) throws -> URL {
        let url = try safeURL(relativePath, root: root)
        guard MemoryPreferences.sourceAllowed(source, root: root), FileManager.default.fileExists(atPath: url.path) else { throw Problem.sourceUnavailable }
        if source.hasPrefix("note:") {
            let slug = String(source.dropFirst(5))
            guard Note.isValidSlug(slug), relativePath == "notes/\(slug).md" else { throw Problem.unsafePath }
        } else if source.hasPrefix("rec:") {
            let id = String(source.dropFirst("rec:".count))
            guard Metadata.isValidID(id), relativePath.hasPrefix("recordings/\(id)/") else { throw Problem.unsafePath }
        } else { throw Problem.sourceUnavailable }
        return url
    }

    static func boundedData(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 4_000_000 else { throw Problem.sourceUnavailable }
        return try Data(contentsOf: url)
    }
}
