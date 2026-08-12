import Foundation
import Network
import ListenKit

/// The Mac half of the pair, as it was in `listen-sync` and now inside Listen.
///
/// Moved rather than rewritten. Everything here was proved by `roundtrip.sh`
/// where it was, and the migration's next phase deletes all of it, so the one
/// thing this port must not do is take the opportunity to change how it
/// behaves. The differences are that it is a type instead of top-level code,
/// and that transcription calls into Listen directly instead of spawning a
/// second copy of Listen to do it.
///
/// **This whole file goes at Phase 6.** `NetworkTransport`, `Wire`, `Request`,
/// `Response` and `Manifest` go with it, along with Bonjour, the Local Network
/// permission and the failure modes a person actually meets: no Mac found on
/// this network, a permission that fails by never completing, an agent that is
/// not running.
struct SyncServer {
    let library: ListenKit.Library
    let key: PairingKey
    /// Whether an arriving recording is transcribed on arrival. Off in the
    /// harnesses, which want the transfer proved and not an hour of Parakeet.
    let transcribes: Bool

    // MARK: - Manifest

    /// What this Mac holds, in the smallest form that lets a device work out
    /// what it is missing.
    static func manifest(of library: ListenKit.Library) -> Manifest {
        var entries: [Manifest.Entry] = []
        for recording in library.all() {
            var digests: [String: String] = [:]
            // `metadata.json` is in this set, so a device can tell whether the
            // copy it holds is the one this Mac holds. It could not before: the
            // manifest carried five scalar fields and the device rebuilt the
            // file out of them, so it could never notice what it was missing.
            for file in servedFiles {
                let url = recording.folder.appendingPathComponent(file)
                if let data = try? Data(contentsOf: url) { digests[file] = sha256Hex(data) }
            }
            entries.append(Manifest.Entry(
                id: recording.id,
                title: recording.metadata.title,
                recorded_at: recording.metadata.recorded_at,
                duration: recording.metadata.duration,
                state: recording.state.rawValue,
                room: recording.metadata.room,
                hasAudio: recording.hasAudio,
                digests: digests))
        }
        let notes = library.allNotes().map {
            Manifest.NoteStamp(slug: $0.slug, updated: $0.updated, version: $0.version)
        }
        return Manifest(recordings: entries, notes: notes)
    }

    // MARK: - Names

    /// The refusal for a request naming something that would become a path
    /// outside the library, or nil if every name it carries is one.
    ///
    /// `request.id` and a note's slug both reach `appendingPathComponent`,
    /// which resolves `..`, and neither was ever checked: `get` read a file
    /// outside the library and `deleteRecording` removed a directory outside
    /// it. A paired device is not a trusted device, because the key proves
    /// which device it is and not that it is sending what its own code would.
    static func pathRefusal(_ request: Request) -> Response? {
        func badID(_ id: String) -> Response { .failure("\"\(id)\" is not a recording id.") }
        switch request.op {
        case .hello, .manifest, .notes, .ack:
            return nil
        case .get, .put, .deleteRecording:
            guard let id = request.id else { return nil }
            return ListenKit.Metadata.isValidID(id) ? nil : badID(id)
        case .finish:
            guard let id = request.id else { return nil }
            guard ListenKit.Metadata.isValidID(id) else { return badID(id) }
            if let inner = request.metadata?.id, inner != id {
                return .failure("the uploaded metadata says \(inner), not \(id).")
            }
            return nil
        case .patch:
            guard let id = request.patch?.id else { return nil }
            return ListenKit.Metadata.isValidID(id) ? nil : badID(id)
        case .putNote:
            guard let slug = request.note?.slug else { return nil }
            return ListenKit.Note.isValidSlug(slug) ? nil : .failure("\"\(slug)\" is not a note name.")
        case .deleteNote:
            guard let slug = request.note?.slug ?? request.id else { return nil }
            return ListenKit.Note.isValidSlug(slug) ? nil : .failure("\"\(slug)\" is not a note name.")
        }
    }

    // MARK: - Handling

    /// Where a recording being uploaded lives until every byte has arrived.
    /// `staging/` and not `recordings/`, because a recording in progress must
    /// never be visible to a second machine, and an upload is exactly that
    /// until `finish`.
    private func incoming(_ id: String) -> URL {
        library.staging.appendingPathComponent(id + ".incoming")
    }

    func handle(_ request: Request, body: Data) -> (Response, Data) {
        guard request.token == key.token else {
            return (.failure("This device is not paired with this Mac."), Data())
        }

        // Revocation is checked per request rather than at pairing, because the
        // point of taking a device off the list is that it is not in your hand:
        // it has the key and will keep using it until this Mac stops answering.
        if let id = request.deviceID {
            var registry = DeviceRegistry.load(library)
            if registry.isRevoked(id) {
                return (.failure("This device has been removed from your Mac. "
                                 + "Pair again to reconnect."), Data())
            }
            if registry.seen(id: id, name: request.deviceName ?? "") {
                registry.save(library)
            }
        }

        // Names, before any of them becomes a path. Once, here, rather than in
        // each case below, because the next case added would have been the one
        // that forgot.
        if let refusal = SyncServer.pathRefusal(request) { return (refusal, Data()) }

        switch request.op {
        case .hello:
            var r = Response(ok: true)
            r.name = Host.current().localizedName ?? "Mac"
            return (r, Data())

        case .manifest:
            var r = Response(ok: true)
            r.manifest = SyncServer.manifest(of: library)
            return (r, Data())

        case .get:
            guard let id = request.id, let file = request.file,
                  servedFiles.contains(file) else {
                return (.failure("not a file this server sends"), Data())
            }
            let url = library.folder(for: id).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url) else {
                return (.failure("\(id)/\(file) is not here"), Data())
            }
            return (Response(ok: true), data)

        case .put:
            guard let id = request.id, request.file == "mic.wav" else {
                return (.failure("only mic.wav may be uploaded"), Data())
            }
            let folder = incoming(id)
            let target = folder.appendingPathComponent("mic.wav")
            do {
                try FileManager.default.createDirectory(at: folder,
                                                        withIntermediateDirectories: true)
                if request.offset == 0 || !FileManager.default.fileExists(atPath: target.path) {
                    try body.write(to: target)
                } else {
                    let h = try FileHandle(forWritingTo: target)
                    defer { try? h.close() }
                    // Seek rather than append, so a chunk sent twice after a
                    // dropped connection overwrites. An upload that appends a
                    // resent chunk produces a file of plausible size full of
                    // repeated audio, which transcribes without complaining and
                    // is the worst possible failure.
                    try h.seek(toOffset: UInt64(request.offset ?? 0))
                    try h.write(contentsOf: body)
                }
                return (Response(ok: true), Data())
            } catch {
                return (.failure("could not write: \(error.localizedDescription)"), Data())
            }

        case .finish:
            guard let id = request.id, var metadata = request.metadata else {
                return (.failure("finish needs an id and metadata"), Data())
            }
            let from = incoming(id)
            let audio = from.appendingPathComponent("mic.wav")
            guard let info = AudioFile.inspect(audio) else {
                return (.failure("the uploaded audio is not a WAV this Mac can read"), Data())
            }
            guard info.isListenFormat else {
                return (.failure("expected 16 kHz mono Int16, got \(info.sampleRate) Hz, "
                                 + "\(info.channels) ch, \(info.bitsPerSample)-bit"), Data())
            }
            let to = library.folder(for: id)
            do {
                try FileManager.default.createDirectory(at: library.recordings,
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: to.path) {
                    // Clear the destination before moving onto it. This once
                    // read `audio.deletingLastPathComponent()`, which resolves
                    // back to `audio` itself, so re-uploading a recording the
                    // Mac already had deleted the freshly uploaded audio and
                    // then failed to move a file that was no longer there.
                    let destination = to.appendingPathComponent("mic.wav")
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: audio, to: destination)
                    try? FileManager.default.removeItem(at: from)
                } else {
                    try FileManager.default.moveItem(at: from, to: to)
                }
                // Duration from the file, not from the device. A phone killed
                // mid-recording reports the duration it intended.
                metadata.duration = info.duration
                let writer = try ListenKit.RecordingWriter(folder: to, metadata: metadata)
                try writer.finish()
            } catch {
                return (.failure("could not publish: \(error.localizedDescription)"), Data())
            }

            if transcribes {
                // Close the loop without waiting for somebody to open the app.
                // In-process now rather than by spawning a second copy of
                // Listen: the queue rebuilds itself by listing the library, so
                // asking it to resume is exactly the job it would pick up on
                // next activation, run now. `Queue` is main-actor isolated
                // because it drives the UI as well.
                Task { @MainActor in Queue.shared.resume() }
            }
            return (Response(ok: true), Data())

        case .ack:
            return (Response(ok: true), Data())

        case .patch:
            guard let patch = request.patch, let recording = library.find(patch.id) else {
                return (.failure("no such recording"), Data())
            }
            // Applied to the JSON on disk, never to a decoded struct. This was
            // load, mutate, `save()`, which re-encodes through ListenKit's
            // `Metadata`, a smaller struct than the one Listen writes, so every
            // rename from a phone silently deleted `calendar_people`,
            // `title_source` and `mic_silent` from this Mac's canonical copy.
            do { try recording.patch(patch) } catch {
                return (.failure(error.localizedDescription), Data())
            }
            return (Response(ok: true), Data())

        case .notes:
            var r = Response(ok: true)
            r.notes = library.allNotes()
            return (r, Data())

        case .deleteNote:
            guard let slug = request.note?.slug ?? request.id else {
                return (.failure("no note named"), Data())
            }
            // No tombstone and no confirmation that it existed. A delete of
            // something already gone is the outcome the caller wanted.
            library.deleteNote(slug)
            return (Response(ok: true), Data())

        case .deleteRecording:
            guard let id = request.id, let recording = library.find(id) else {
                return (Response(ok: true), Data())
            }
            do {
                try FileManager.default.removeItem(at: recording.folder)
                return (Response(ok: true), Data())
            } catch {
                return (.failure("could not delete: \(error.localizedDescription)"), Data())
            }

        case .putNote:
            guard let note = request.note else { return (.failure("no note"), Data()) }
            do {
                try library.writeNote(note, expecting: request.expecting, stamp: false)
                return (Response(ok: true), Data())
            } catch let conflict as NoteConflict {
                var r = Response(ok: true)
                r.conflict = conflict.theirs
                return (r, Data())
            } catch {
                return (.failure(error.localizedDescription), Data())
            }
        }
    }

    // MARK: - Serving

    func serve(port: UInt16) async throws {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Listen",
                                              type: listenServiceType)

        listener.newConnectionHandler = { connection in
            Task {
                let channel = Channel(connection)
                do {
                    try await channel.start()
                    while true {
                        let (header, body) = try await channel.readFrame()
                        let request = try JSONDecoder().decode(Request.self, from: header)
                        let opened = body.isEmpty ? Data() : try key.open(body)
                        let (response, payload) = handle(request, body: opened)
                        // One line per request. Without it, a device that
                        // cannot reach this Mac and a device that reaches it
                        // and is refused look identical from here, and the
                        // second is the common case: a stale key, or a token
                        // that does not match.
                        let stamp = ISO8601DateFormatter().string(from: Date())
                        let detail = [request.id, request.file]
                            .compactMap { $0 }.joined(separator: "/")
                        print("\(stamp)  \(request.op.rawValue)"
                              + (detail.isEmpty ? "" : "  \(detail)")
                              + (response.ok ? "" : "  REFUSED: \(response.error ?? "")"))
                        let sealed = payload.isEmpty ? Data() : try key.seal(payload)
                        try await channel.writeFrame(try JSONEncoder().encode(response),
                                                     body: sealed)
                    }
                } catch {
                    await channel.close()
                }
            }
        }

        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("listen sync serving \(library.root.path)")
                print("  port \(listener.port?.rawValue ?? 0), advertised as \(listenServiceType)")
                print("  pair a device with:\n")
                print("      \(key.code)\n")
                if transcribes { print("  will transcribe each upload automatically") }
            }
        }
        listener.start(queue: .main)
        while true { try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }
    }
}
