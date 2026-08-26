import AVFoundation
import CloudKit
import Foundation

/// The whole sync, against a store in a dictionary, in about a second.
///
/// This is what replaces `roundtrip.sh`, which described itself as the whole
/// sync architecture on one machine in about a minute and did it by running
/// the real engine through a loopback server. **CloudKit has no loopback**, so
/// there is no second path to keep that alive on.
///
/// What is lost is nothing that was being tested: `roundtrip.sh` was never
/// testing TCP. What is gained is the two cases a real container will not
/// produce on demand, and which are the two that lose data: a change token the
/// server cannot resume from, and two devices racing for one ingest.
///
/// What this does **not** prove is that CloudKit behaves as documented. That is
/// a separate, slower pass against the Development container. Two layers, and
/// the fast one is hermetic.
public enum FakeSync {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs every seam and returns the lines to print. Throws on the first
    /// failure, because a suite that carries on after one is a suite whose
    /// later results nobody trusts.
    public static func run(root: URL) async throws -> [String] {
        var out: [String] = []
        func ok(_ what: String) { out.append("  ok: \(what)") }
        func check(_ condition: Bool, _ what: String) throws {
            guard condition else { throw Failure(description: what) }
        }

        try? FileManager.default.removeItem(at: root)
        let key = PairingKey.generate()

        // Two devices over one container, which is the shape everything here
        // is about. A Mac that ingests, and a phone that does not.
        let macLib = try scratchLibrary(root.appendingPathComponent("mac"))
        let phoneLib = try scratchLibrary(root.appendingPathComponent("phone"))

        // Per-device state is deliberately **outside** the library, so the
        // removal above does not touch it. `scratchLibrary` clears it, which
        // is what makes a second run of this suite start from nothing.
        let store = MemoryStore()

        // The key bootstrap, which is the seam behind the first real outside
        // install: turning sync on used to set a flag, nothing anywhere
        // created the key it then looked for, and a fresh Mac and its phone
        // each waited for the other for ever. See "Nothing ever created the
        // key" in `.agents/notes/cloud-sync.md`. Proved here: the first Mac
        // creates, a phone never does, and a device that can see somebody
        // else in the container waits for iCloud Keychain rather than minting
        // a rival key. A scratch keychain account, cleared both ways, so the
        // suite can never touch a real pairing key.
        let fakeKeys = KeyStore(service: "eu.jacarandalabs.listen",
                                account: "fake-suite-key")
        fakeKeys.clear()
        defer { fakeKeys.clear() }
        let emptyContainer = MemoryStore()
        guard case .noDeviceSyncingYet =
            await fakeKeys.provision(store: emptyContainer, mayCreate: false) else {
            throw Failure(description: "a phone minted a key, or misread an empty container")
        }
        guard case .created(let minted) =
            await fakeKeys.provision(store: emptyContainer, mayCreate: true) else {
            throw Failure(description: "the first Mac did not create the key")
        }
        guard case .existing(let reloaded) =
            await fakeKeys.provision(store: emptyContainer, mayCreate: true),
            reloaded == minted else {
            throw Failure(description: "the created key was not the one loaded back")
        }
        ok("the first Mac creates the key, a phone never does")
        fakeKeys.clear()
        let occupiedContainer = MemoryStore()
        _ = try await occupiedContainer.save(StoredRecord(
            name: CloudNaming.recordName(.device, "seam-device", key: key),
            type: .device, payload: Data([1])))
        guard case .keyOnItsWay =
            await fakeKeys.provision(store: occupiedContainer, mayCreate: true) else {
            throw Failure(description: "a keyless Mac minted a rival key over a syncing account")
        }
        ok("a keyless device that can see another one waits for its key")

        // `CKFetchRecordsOperation` can wrap a single absent record in an
        // operation-level partial failure. The item-level unknown-item is still
        // an ordinary cache miss, while any other nested error must stay fatal.
        let missingID = CKRecord.ID(recordName: "missing")
        let unknown = NSError(domain: CKErrorDomain,
                              code: CKError.Code.unknownItem.rawValue)
        let missingPartial = CKError(_nsError: NSError(
            domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: [missingID: unknown]]))
        try check(CloudKitStore.isUnknownItem(missingPartial, for: missingID),
                  "a partial-failure cache miss was treated as a hard failure")
        let offlineError = NSError(domain: CKErrorDomain,
                                   code: CKError.Code.networkUnavailable.rawValue)
        let offlinePartial = CKError(_nsError: NSError(
            domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: [missingID: offlineError]]))
        try check(!CloudKitStore.isUnknownItem(offlinePartial, for: missingID),
                  "a network failure was mistaken for a missing record")
        ok("CloudKit partial failures distinguish a missing record from an outage")

        // A shipped build can already hold the poisoned stamp. Constructing
        // the repaired core must invalidate recording checks exactly once,
        // without invalidating the separate proof that phone audio uploaded.
        let repairLib = try scratchLibrary(root.appendingPathComponent("stamp-repair"))
        let repairState = EngineState(library: repairLib)
        var poisoned = SyncState()
        let repairID = "2026-08-12-090000-F1F1"
        poisoned[sent: repairID] = "poisoned"
        poisoned[sent: "audio:\(repairID)"] = "1"
        repairState.base = poisoned
        _ = CloudSyncCore(library: repairLib, state: repairState,
                          store: store, key: key, policy: .mac,
                          device: "repair", ingests: true)
        try check(repairState.base[sent: repairID] == nil,
                  "the poisoned recording stamp survived the repair")
        try check(repairState.base[sent: "audio:\(repairID)"] == "1",
                  "the repair invalidated an audio upload stamp")
        var repaired = repairState.base
        repaired[sent: repairID] = "current"
        repairState.base = repaired
        repairState.repairSuppressedRecordingPushesOnce()
        try check(repairState.base[sent: repairID] == "current",
                  "the one-time recording repair ran twice")
        ok("existing recording stamps are rechecked once without reuploading audio")

        // A Mac keeps its audio, which is the shipped default and matters to
        // every seam below: a device that is not keeping audio is a device
        // nobody else is allowed to delete on. See `CloudSyncCore.reclaim`.
        let mac = CloudSyncCore(library: macLib, state: EngineState(library: macLib),
                                store: store, key: key, policy: .mac,
                                device: "mac-1", ingests: true, keepAudio: true)
        let phone = CloudSyncCore(library: phoneLib, state: EngineState(library: phoneLib),
                                  store: store, key: key, policy: .phone,
                                  device: "phone-1", ingests: false)

        // MARK: the audio master

        // Synthetic tracks, because what is being proved is the codec path and
        // not anybody's voice: two tones a fifth apart, so a channel landing in
        // the wrong half of the file is visible rather than plausible.
        let masterFolder = root.appendingPathComponent("master")
        try FileManager.default.createDirectory(at: masterFolder, withIntermediateDirectories: true)
        let leftURL = masterFolder.appendingPathComponent("mic.wav")
        let rightURL = masterFolder.appendingPathComponent("system.wav")
        func tone(_ hz: Double, to url: URL, seconds: Int = 3) throws -> [Int16] {
            let writer = try AudioFile.Writer(url: url)
            var all: [Int16] = []
            for second in 0..<seconds {
                let block = (0..<16_000).map { i -> Int16 in
                    let t = Double(second * 16_000 + i) / 16_000
                    return Int16(sin(t * hz * 2 * Double.pi) * 12_000)
                }
                try writer.append(block)
                all.append(contentsOf: block)
            }
            _ = try writer.close()
            return all
        }
        let leftIn = try tone(440, to: leftURL)
        let rightIn = try tone(660, to: rightURL)

        guard let built = try AudioMaster.make(micURL: leftURL, systemURL: rightURL,
                                               into: masterFolder) else {
            throw Failure(description: "no master was made from two tracks")
        }
        let made = built.url
        let masterBytes = try Data(contentsOf: made).count
        let rawBytes = try Data(contentsOf: leftURL).count + Data(contentsOf: rightURL).count
        try check(masterBytes < rawBytes,
                  "the master (\(masterBytes)) did not come out smaller than the tracks (\(rawBytes))")

        // Readable at all, which is the finalisation trap: left alive to the
        // end of the process the encoder produces a file of exactly the right
        // size that no decoder will open.
        let reopened = try AVAudioFile(forReading: made)
        try check(reopened.processingFormat.channelCount == 2,
                  "two tracks did not make a two channel master")
        try check(abs(Double(reopened.length) / 16_000 - 3) < 0.05,
                  "the master lost or gained time: \(reopened.length) frames")
        ok("two tracks become one stereo master, smaller than the pair and readable")

        let backFolder = root.appendingPathComponent("master-split")
        try FileManager.default.createDirectory(at: backFolder, withIntermediateDirectories: true)
        let backMic = backFolder.appendingPathComponent("mic.wav")
        let backSystem = backFolder.appendingPathComponent("system.wav")
        _ = try AudioMaster.split(made, into: backFolder, micURL: backMic, systemURL: backSystem)
        func peaks(_ url: URL) throws -> [Int16] {
            let data = try Data(contentsOf: url)
            var out: [Int16] = []
            var i = 44
            while i + 1 < data.count {
                out.append(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8))
                i += 2
            }
            return out
        }
        let leftOut = try peaks(backMic), rightOut = try peaks(backSystem)
        func worst(_ a: [Int16], _ b: [Int16]) -> Int {
            var m = 0
            for i in 0..<Swift.min(a.count, b.count) { m = Swift.max(m, abs(Int(a[i]) - Int(b[i]))) }
            return m
        }
        // Lossless, which is the whole reason this is FLAC and not AAC: a
        // device that frees its raw tracks has to be giving up nothing.
        try check(worst(leftIn, leftOut) <= 1,
                  "the left channel came back changed by \(worst(leftIn, leftOut))")
        try check(worst(rightIn, rightOut) <= 1,
                  "the right channel came back changed by \(worst(rightIn, rightOut))")
        try check(worst(leftIn, rightOut) > 100, "the two channels were not kept apart")
        ok("the master splits back into the two tracks, sample for sample")

        // One track stays one channel, rather than paying for a silent half.
        let memoFolder = root.appendingPathComponent("master-mono")
        try FileManager.default.createDirectory(at: memoFolder, withIntermediateDirectories: true)
        let memoMic = memoFolder.appendingPathComponent("mic.wav")
        _ = try tone(440, to: memoMic)
        guard let mono = try AudioMaster.make(micURL: memoMic, systemURL: nil, into: memoFolder)
        else { throw Failure(description: "no master was made from one track") }
        try check(try AVAudioFile(forReading: mono.url).processingFormat.channelCount == 1,
                  "a voice memo was widened to stereo")
        try check(mono.layout == .tracks, "a microphone track was not a tracks master")
        ok("one track stays one channel")

        // MARK: sealing and naming

        let sealed = try key.seal(Data("a meeting nobody else may read".utf8))
        try check(String(decoding: sealed, as: UTF8.self) != "a meeting nobody else may read",
                  "the payload was not sealed")
        try check(try key.open(sealed) == Data("a meeting nobody else may read".utf8),
                  "the payload did not survive a round trip")
        ok("sealing round-trips, and the sealed form is not the plain one")

        let a = CloudNaming.recordName(.recording, "2026-08-12-101010-ABCD", key: key)
        let b = CloudNaming.recordName(.recording, "2026-08-12-101010-ABCD", key: key)
        let c = CloudNaming.recordName(.note, "2026-08-12-101010-ABCD", key: key)
        let d = CloudNaming.recordName(.recording, "2026-08-12-101010-ABCD",
                                       key: PairingKey.generate())
        try check(a == b, "two devices with one key derived different names")
        try check(a != c, "a note and a recording with one natural key collided")
        try check(a != d, "a different key produced the same name")
        try check(!a.contains("2026"), "the record name leaks the meeting time")
        ok("record names are deterministic, typed apart, key-bound and opaque")

        // MARK: a recording crosses, verbatim

        let id = "2026-08-12-101010-ABCD"
        let metadata = """
        {"id":"\(id)","title":"Quarterly review","recorded_at":"2026-08-12T10:10:10Z",\
        "duration":1800,"source":"mac","state":"done","tags":["board"],\
        "calendar_people":[{"name":"Rita","email":"r@example.com","is_me":false,\
        "is_organizer":true}],"mic_silent":true,"transcribed_by":"mac-1",\
        "transcribed_on":"Studio","transcribe_started":"2026-08-12T10:40:00Z",\
        "transcribe_finished":"2026-08-12T11:12:30Z"}
        """
        try seed(macLib, id: id, metadata: metadata,
                 transcript: #"{"segments":[],"duration":1800,"model":"parakeet-v3"}"#)
        let sourceIcon = Data("small source icon".utf8)
        try sourceIcon.write(to: macLib.folder(for: id)
            .appendingPathComponent(DevicePolicy.sourceIcon))

        var push = CloudReport()
        await mac.push(into: &push)
        try check(push.errors.isEmpty, "pushing failed: \(push.errors)")

        var pull = CloudReport()
        await phone.pull(into: &pull)
        try check(pull.errors.isEmpty, "pulling failed: \(pull.errors)")

        let landed = try Data(contentsOf: phoneLib.folder(for: id)
            .appendingPathComponent("metadata.json"))
        try check(landed == Data(metadata.utf8),
                  "metadata.json did not cross byte-identical")
        ok("metadata.json crosses verbatim, with fields neither device models")

        // The provenance is inside those bytes and therefore inside the sealed
        // payload, which is the whole reason it costs no CloudKit schema. What
        // this proves is the other half: that a device which did not do the
        // work can read who did and how long it took, leniently, out of a file
        // it must never re-encode.
        let provenance = try unwrap(phoneLib.find(id)?.metadata, "the recording did not land")
        try check(provenance.transcribed_by == "mac-1"
                  && provenance.transcribed_on == "Studio",
                  "the phone could not read which device made the transcript")
        try check(provenance.transcribe_started == "2026-08-12T10:40:00Z"
                  && provenance.transcribe_finished == "2026-08-12T11:12:30Z",
                  "the phone could not read when the transcription ran")
        ok("who transcribed a recording, and how long it took, reaches every device")
        let landedIcon = try Data(contentsOf: phoneLib.folder(for: id)
            .appendingPathComponent(DevicePolicy.sourceIcon))
        try check(landedIcon == sourceIcon, "the source app icon did not reach the phone")
        ok("source app icons cross inside the sealed recording payload")

        // A second Mac without that application installed cannot make the
        // icon, and pushing the same recording from there used to take it out
        // of the container. Its `push` builds the record from local files, so
        // a file it can never hold reads as a file that has been removed.
        let iconless = try scratchLibrary(root.appendingPathComponent("mac-iconless"))
        try seed(iconless, id: id, metadata: metadata,
                 transcript: #"{"segments":[],"duration":1800,"model":"parakeet-v3"}"#)
        let iconlessMac = CloudSyncCore(library: iconless, state: EngineState(library: iconless),
                                        store: store, key: key, policy: .mac,
                                        device: "mac-3", ingests: true)
        var iconlessPush = CloudReport()
        await iconlessMac.push(into: &iconlessPush)
        let republished = try CloudRecords.openRecording(
            try await store.fetch(CloudNaming.recordName(.recording, id, key: key),
                                  in: .library)!, key: key)
        try check(republished.sourceIcon == sourceIcon,
                  "a Mac that cannot make the icon removed it from the container")
        try check(republished.digests[DevicePolicy.sourceIcon] != nil,
                  "the icon survived the payload but not the manifest")
        ok("a Mac without the application cannot strip a source icon it never had")

        // MARK: what the phone must never receive

        try check(!FileManager.default.fileExists(
            atPath: phoneLib.folder(for: id).appendingPathComponent("embeddings.json").path),
                  "voiceprints reached a device whose policy excludes them")
        ok("voiceprints stay off a device that does not keep them")

        // MARK: it converges

        var second = CloudReport()
        await phone.pull(into: &second)
        try check(!second.didSomething,
                  "a settled pair still had work: \(second.summary)")
        ok("a second pass is a no-op, so nothing rewrites what it received")

        // MARK: a pull cannot hide a local sidecar from the following push

        // A Mac publishes metadata before transcription finishes. Its next
        // pass pulls that earlier record before it pushes the transcript it
        // has just written. The pulled record does not contain the new files,
        // so treating the Mac's richer folder as the thing just received marks
        // unsent work as sent and leaves every other device waiting forever.
        let lateID = "2026-08-12-104545-C0DE"
        try seed(macLib, id: lateID,
                 metadata: #"{"id":"\#(lateID)","title":"Late transcript","source":"mac","state":"transcribing"}"#,
                 transcript: nil)
        var earlyPush = CloudReport()
        await mac.push(into: &earlyPush)

        let lateFolder = macLib.folder(for: lateID)
        try Data(#"{"segments":[{"speaker":"Me","start":0,"end":1,"text":"Arrived"}]}"#.utf8)
            .write(to: lateFolder.appendingPathComponent("transcript.json"))
        try Data(#"[{"speaker":"Me","start":0,"end":1,"text":"Arrived"}]"#.utf8)
            .write(to: lateFolder.appendingPathComponent("turns.json"))

        var selfPull = CloudReport()
        await mac.pull(into: &selfPull)
        var latePush = CloudReport()
        await mac.push(into: &latePush)

        let freshPhoneLib = try scratchLibrary(root.appendingPathComponent("fresh-phone"))
        try? FileManager.default.removeItem(at: EngineState(library: freshPhoneLib).root)
        let freshPhone = CloudSyncCore(
            library: freshPhoneLib, state: EngineState(library: freshPhoneLib),
            store: store, key: key, policy: .phone,
            device: "phone-2", ingests: false)
        var freshPull = CloudReport()
        await freshPhone.pull(into: &freshPull)
        try check(FileManager.default.fileExists(
            atPath: freshPhoneLib.folder(for: lateID)
                .appendingPathComponent("transcript.json").path),
                  "pulling the earlier cloud record hid the Mac's new transcript")
        try check(FileManager.default.fileExists(
            atPath: freshPhoneLib.folder(for: lateID)
                .appendingPathComponent("turns.json").path),
                  "pulling the earlier cloud record hid the Mac's new turns")
        ok("pulling an earlier record does not suppress newer local sidecars")

        // A phone can still hold the sparse copy it originally uploaded while
        // the Mac has already added the transcript. Its next push may add new
        // local files, but it must not replace the richer record with the old
        // metadata-only shape.
        let stalePhoneLib = try scratchLibrary(root.appendingPathComponent("stale-phone"))
        try? FileManager.default.removeItem(at: EngineState(library: stalePhoneLib).root)
        try seed(stalePhoneLib, id: lateID,
                 metadata: #"{"id":"\#(lateID)","title":"Late transcript","source":"iphone","state":"pending"}"#,
                 transcript: nil)
        let stalePhone = CloudSyncCore(
            library: stalePhoneLib, state: EngineState(library: stalePhoneLib),
            store: store, key: key, policy: .phone,
            device: "phone-3", ingests: false)
        var stalePush = CloudReport()
        await stalePhone.push(into: &stalePush)

        let afterStaleLib = try scratchLibrary(root.appendingPathComponent("after-stale-phone"))
        try? FileManager.default.removeItem(at: EngineState(library: afterStaleLib).root)
        let afterStalePhone = CloudSyncCore(
            library: afterStaleLib, state: EngineState(library: afterStaleLib),
            store: store, key: key, policy: .phone,
            device: "phone-4", ingests: false)
        var afterStalePull = CloudReport()
        await afterStalePhone.pull(into: &afterStalePull)
        try check(FileManager.default.fileExists(
            atPath: afterStaleLib.folder(for: lateID)
                .appendingPathComponent("transcript.json").path),
                  "a stale phone push erased the Mac transcript")
        try check(FileManager.default.fileExists(
            atPath: afterStaleLib.folder(for: lateID)
                .appendingPathComponent("turns.json").path),
                  "a stale phone push erased the Mac turns")
        let afterStaleMetadata = try Data(contentsOf: afterStaleLib.folder(for: lateID)
            .appendingPathComponent("metadata.json"))
        try check(String(decoding: afterStaleMetadata, as: UTF8.self).contains(#""source":"mac""#),
                  "a stale phone push replaced the Mac metadata")
        ok("a stale phone cannot downgrade a transcribed cloud record")

        // MARK: an edit nobody has sent yet outranks the container's copy of it

        // The failure this exists to stop, reported from a real two-Mac
        // library: a speaker was corrected at 21:27:19 and `transcript.json`
        // was rewritten at 21:28:14 with the pre-edit copy, while
        // `metadata.json` kept its 21:27 time because it had not changed. The
        // correction went off the screen while its author was looking at it,
        // nothing was reported, and the push that followed found the two sides
        // in agreement and sent nothing.
        //
        // Nothing exotic is needed for it. A pull runs before a push, so
        // between an edit and the next push the container still holds what this
        // device had before; any pass that re-fetches that record then sees the
        // two disagree, and until sidecars had a base it read that as being
        // behind. A second Mac is what makes the record come round again, and
        // it does not even have to touch the transcript: renaming the recording
        // republishes the record with its own older transcript still attached.
        let otherMacLib = try scratchLibrary(root.appendingPathComponent("other-mac"))
        try? FileManager.default.removeItem(at: EngineState(library: otherMacLib).root)
        let otherMac = CloudSyncCore(
            library: otherMacLib, state: EngineState(library: otherMacLib),
            store: store, key: key, policy: .mac,
            device: "mac-2", ingests: true)
        var otherPull = CloudReport()
        await otherMac.pull(into: &otherPull)
        let otherFolder = otherMacLib.folder(for: lateID)
        try check(String(decoding: try Data(contentsOf: otherFolder
            .appendingPathComponent("transcript.json")), as: UTF8.self).contains("Arrived"),
                  "the second Mac did not receive the transcript to be stale about")

        // The edit, on the Mac that made the recording, and not sent yet.
        let corrected = #"{"segments":[{"speaker":"Nick","start":0,"end":1,"text":"Corrected"}]}"#
        try Data(corrected.utf8).write(to: lateFolder.appendingPathComponent("transcript.json"))
        try Data(#"[{"speaker":"Nick","start":0,"end":1,"text":"Corrected"}]"#.utf8)
            .write(to: lateFolder.appendingPathComponent("turns.json"))

        // The second Mac republishes the record for a reason of its own, with
        // the transcript it still holds.
        try Data(#"{"id":"\#(lateID)","title":"Renamed elsewhere","source":"mac","state":"done"}"#.utf8)
            .write(to: otherFolder.appendingPathComponent("metadata.json"))
        var otherPush = CloudReport()
        await otherMac.push(into: &otherPush)

        var editPull = CloudReport()
        await mac.pull(into: &editPull)
        let keptEdit = String(decoding: try Data(contentsOf: lateFolder
            .appendingPathComponent("transcript.json")), as: UTF8.self)
        try check(keptEdit.contains("Corrected"),
                  "a pull overwrote an edit this device had not sent yet")
        try check(String(decoding: try Data(contentsOf: lateFolder
            .appendingPathComponent("turns.json")), as: UTF8.self).contains("Corrected"),
                  "a pull overwrote the turns beside the edited transcript")
        try check(editPull.conflicts.contains { $0.contains(lateID) },
                  "the kept edit was not reported")
        ok("a pull cannot overwrite a local edit the container has not seen")

        // And it converges: the push that follows carries the edit, and the
        // device that was stale takes it. Keeping local is only correct if it
        // is a delay rather than a fork.
        var editPush = CloudReport()
        await mac.push(into: &editPush)
        var otherAgain = CloudReport()
        await otherMac.pull(into: &otherAgain)
        try check(String(decoding: try Data(contentsOf: otherFolder
            .appendingPathComponent("transcript.json")), as: UTF8.self).contains("Corrected"),
                  "the edit was kept locally and never reached the other Mac")
        ok("and the push that follows carries it to the device that was stale")

        // MARK: notes, and the four cases

        try check(decideNote(base: nil, local: nil, remote: "r") == .pull, "never seen here")
        try check(decideNote(base: "b", local: "b", remote: "r") == .pull, "behind")
        try check(decideNote(base: "b", local: "l", remote: "b") == .push, "ahead")
        try check(decideNote(base: "b", local: "l", remote: "r") == .conflict, "both moved")
        try check(decideNote(base: nil, local: "l", remote: "r") == .conflict, "both new")
        try check(decideNote(base: "b", local: "x", remote: "x") == .nothing, "agreed")
        ok("decideNote's table is unchanged by the move to a container")

        // MARK: the reclaim invariant

        let memoID = "2026-08-12-111111-BEEF"
        // A real WAV rather than four kilobytes of the number seven, because
        // the Mac that ingests this then builds a master out of it and an
        // encoder cannot be fed a shape. Everything below still only checks
        // whether the file is there.
        let memoWAV = masterFolder.appendingPathComponent("memo.wav")
        _ = try tone(300, to: memoWAV, seconds: 1)
        let memoAudio = try Data(contentsOf: memoWAV)
        try seed(phoneLib, id: memoID,
                 metadata: #"{"id":"\#(memoID)","title":"Memo","source":"iphone","state":"done"}"#,
                 transcript: nil, audio: memoAudio)
        var up = CloudReport()
        await phone.push(into: &up)

        var upload = CloudReport()
        await phone.upload(phoneLib.find(memoID)!, into: &upload)
        let transferName = CloudNaming.recordName(.audioTransfer, memoID, key: key)
        try check(try await store.fetch(transferName, in: .transfer) != nil,
                  "the phone did not upload its audio")

        // A transfer can disappear before its library record carries audioOn.
        // The phone still has the only durable copy, so a remembered upload is
        // not enough reason to stop checking until a Mac acknowledges the bytes.
        try await store.delete(transferName, in: .transfer)
        var retryUpload = CloudReport()
        await phone.upload(phoneLib.find(memoID)!, into: &retryUpload)
        try check(try await store.fetch(transferName, in: .transfer) != nil,
                  "a missing unacknowledged transfer was not uploaded again")
        ok("unacknowledged phone audio is retried when its transfer disappears")

        var down = CloudReport()
        await phone.pull(into: &down)
        try check(FileManager.default.fileExists(
            atPath: phoneLib.find(memoID)!.micURL.path),
            "the phone deleted its only copy before any Mac held it")
        ok("audio survives an upload that no device has acknowledged")

        // Now a Mac really takes it, through the pipe rather than by hand.
        let memoName = CloudNaming.recordName(.recording, memoID, key: key)
        var ingesting = CloudReport()
        await mac.ingest(preferred: nil, into: &ingesting)
        try check(macLib.find(memoID)?.hasAudio == true,
                  "the Mac did not end up holding the audio it ingested")
        try check(try await store.fetch(memoName, in: .library)?.audioOn == "mac-1",
                  "the ingesting Mac never said it holds the bytes")

        // **The container holding a copy is not a device holding a copy**, and
        // a pull is not where anything is freed any more. `audioOn` is one
        // string written once by whichever Mac ingested, and it stays true
        // after that Mac has been wiped; the roster is a list republished from
        // disk every heartbeat. Until this Mac has said so in a heartbeat the
        // phone has heard, nothing may go.
        var seenNothing = CloudReport()
        await phone.pull(into: &seenNothing)
        await phone.reclaim([], into: &seenNothing)
        try check(FileManager.default.fileExists(
            atPath: phoneLib.folder(for: memoID).appendingPathComponent("mic.wav").path),
            "the phone freed audio on nobody's word")
        ok("a pull cannot free audio, and an empty roster authorises nothing")

        // A device that has not been heard from in a fortnight is not evidence
        // about a disk anybody can see, whatever its list says.
        let asleep = CloudRecords.DeviceBlob(
            id: "mac-asleep", name: "Shut", kind: "Mac",
            lastSeen: Metadata.stamp(Date().addingTimeInterval(-14 * 86_400)),
            appVersion: "test", keepsAudio: true, holdsAudio: [memoID])
        var shutAway = CloudReport()
        await phone.reclaim([asleep], into: &shutAway)
        try check(FileManager.default.fileExists(
            atPath: phoneLib.folder(for: memoID).appendingPathComponent("mic.wav").path),
            "a device that has said nothing for a fortnight freed the only other copy")
        ok("a stale device's list is not evidence")

        // Nor is a device that is itself trying to get rid of the recording.
        // Two of those read each other as a safe holder and delete on the same
        // pass, which is mutual deletion of the only two copies.
        let leaving = CloudRecords.DeviceBlob(
            id: "mac-leaving", name: "Leaving", kind: "Mac",
            lastSeen: Metadata.stamp(Date()), appVersion: "test",
            keepsAudio: false, holdsAudio: [memoID])
        var mutual = CloudReport()
        await phone.reclaim([leaving], into: &mutual)
        try check(FileManager.default.fileExists(
            atPath: phoneLib.folder(for: memoID).appendingPathComponent("mic.wav").path),
            "two devices both letting go deleted the recording between them")
        ok("only a device that is keeping audio may free somebody else's copy")

        // And the real thing: the Mac says what it holds, and the phone lets go.
        let roster = await mac.heartbeat(name: "Studio", kind: "Mac", appVersion: "test")
        try check(roster.first { $0.id == "mac-1" }?.holds(memoID) == true,
                  "the heartbeat did not say which recordings this Mac holds")
        try check(roster.first { $0.id == "mac-1" }?.keeps == true,
                  "the heartbeat did not say this Mac keeps its audio")
        var reclaim = CloudReport()
        await phone.reclaim(roster, into: &reclaim)
        try check(!FileManager.default.fileExists(
            atPath: phoneLib.folder(for: memoID).appendingPathComponent("mic.wav").path),
            "the phone kept audio a live Mac reported holding")
        try check(reclaim.freedBytes > 0, "freeing the audio reported nothing")
        ok("audio is freed only once a live device that keeps it reports holding it")

        // The same pull has to leave behind *which* Mac said so. A device
        // without the bytes could not name the device with them, so the window
        // guessed from `metadata.source` and told a two-Mac library that a
        // claimed phone recording was still on its way here. Nothing syncs on
        // this key; it exists so the sentence on screen can be true.
        try check(EngineState(library: phoneLib).base[audioOn: memoID] == "mac-1",
                  "the pull did not record which device holds the audio")
        var stillHeld = CloudReport()
        await phone.pull(into: &stillHeld)
        try check(EngineState(library: phoneLib).base[audioOn: memoID] == "mac-1",
                  "a pass that changed nothing forgot who holds the audio")
        ok("a device without the audio knows which device has it")

        // MARK: a claim that produces nothing expires

        // The record above carries `state done`, so taking the audio was also
        // delivering it and the phone is finished with it. A claim over a
        // recording nothing has been published for is the other case, and it
        // used to be indistinguishable: any `audioOn` wrote `acknowledged`,
        // nothing ever cleared it, and a Mac that could not publish parked the
        // recording for ever while the phone sat on the only other copy.
        // **A phone that keeps its audio is the only phone this can help**, and
        // that is deliberate rather than a gap. A phone that lets go does so on
        // `audioOn`, which is a Mac reporting the bytes on its own disk, and
        // that report stays true when the transcript never follows: the
        // recording is on that Mac, not lost. Nothing here touches the reclaim
        // invariant. Written with a keep-audio core for exactly that reason,
        // and the first draft used the ordinary one and failed, which is the
        // suite saying so.
        let keeper = CloudSyncCore(
            library: phoneLib, state: EngineState(library: phoneLib),
            store: store, key: key, policy: .phone,
            device: "phone-1", ingests: false, keepAudio: true)

        let strandedID = "2026-08-12-222222-CAFE"
        try seed(phoneLib, id: strandedID,
                 metadata: #"{"id":"\#(strandedID)","title":"Stranded","source":"iphone","state":"pending"}"#,
                 transcript: nil, audio: Data(repeating: 9, count: 4096))
        var strandedUp = CloudReport()
        await keeper.push(into: &strandedUp)
        await keeper.upload(phoneLib.find(strandedID)!, into: &strandedUp)

        // A Mac takes it, says so, and then publishes nothing made from it.
        let strandedTransfer = CloudNaming.recordName(.audioTransfer, strandedID, key: key)
        try await store.delete(strandedTransfer, in: .transfer)
        let strandedName = CloudNaming.recordName(.recording, strandedID, key: key)
        var claimedRecord = try await store.fetch(strandedName, in: .library)!
        claimedRecord.audioOn = "mac-1"
        _ = try await store.save(claimedRecord)

        let claimedAt = Date(timeIntervalSince1970: 1_760_000_000)
        var noticed = CloudReport()
        await keeper.pull(into: &noticed, now: claimedAt)
        try check(EngineState(library: phoneLib).base[sent: "audio:" + strandedID]
                  == CloudSyncCore.claimed(at: claimedAt),
                  "a claim with nothing published read as a delivery")

        // Inside the window the phone stays quiet, because a Mac that is
        // merely slow must not be hammered with the same audio every pass.
        var tooSoon = CloudReport()
        await keeper.upload(phoneLib.find(strandedID)!, into: &tooSoon,
                            now: claimedAt.addingTimeInterval(CloudSyncCore.claimGrace - 60))
        try check(try await store.fetch(strandedTransfer, in: .transfer) == nil,
                  "the phone re-offered audio a Mac had only just taken")

        // Past it, the audio goes back up for whichever Mac is awake.
        var again = CloudReport()
        await keeper.upload(phoneLib.find(strandedID)!, into: &again,
                            now: claimedAt.addingTimeInterval(CloudSyncCore.claimGrace + 60))
        try check(try await store.fetch(strandedTransfer, in: .transfer) != nil,
                  "a stranded recording was never offered again")
        try check(FileManager.default.fileExists(
            atPath: phoneLib.find(strandedID)!.micURL.path),
            "offering the audio again removed it from the phone")
        ok("a claim that publishes nothing expires, and the phone offers again")

        // MARK: the ingesting Mac authors its own metadata

        // `ingest` publishes the phone's `metadata.json`, then the pipeline
        // rewrites it here. Until the next push the record still carries the
        // pre-ingest snapshot, and pulling it used to hand this Mac its own
        // recording back with `state` reset to `pending`.
        let ingested = macLib.folder(for: strandedID)
        try FileManager.default.createDirectory(at: ingested, withIntermediateDirectories: true)
        try Data(#"{"id":"\#(strandedID)","title":"Stranded","source":"iphone","state":"needs_labelling"}"#.utf8)
            .write(to: ingested.appendingPathComponent("metadata.json"))
        var holds = try await store.fetch(strandedName, in: .library)!
        holds.audioOn = "mac-1"
        _ = try await store.save(holds)

        var macPull = CloudReport()
        await mac.pull(into: &macPull)
        let afterPull = try Data(contentsOf: ingested.appendingPathComponent("metadata.json"))
        try check(String(data: afterPull, encoding: .utf8)?.contains("needs_labelling") == true,
                  "a pull reset the state on the Mac that holds the audio")

        // And a Mac that does not hold it still stores the bytes verbatim,
        // which is the rule this is a single exception to.
        let bystanderLib = try scratchLibrary(root.appendingPathComponent("mac2"))
        let bystander = CloudSyncCore(library: bystanderLib,
                                      state: EngineState(library: bystanderLib),
                                      store: store, key: key, policy: .mac,
                                      device: "mac-2", ingests: true)
        var bystanderPull = CloudReport()
        await bystander.pull(into: &bystanderPull)
        let theirs = try Data(contentsOf: bystanderLib.folder(for: strandedID)
            .appendingPathComponent("metadata.json"))
        try check(String(data: theirs, encoding: .utf8)?.contains("\"state\":\"pending\"") == true
                  || String(data: theirs, encoding: .utf8)?.contains("\"state\": \"pending\"") == true,
                  "a Mac without the audio did not store the record's metadata verbatim")
        ok("only the Mac holding the audio authors an ingested recording's metadata")

        // The keep-audio preference retains the WAV after the same
        // acknowledgement. That local copy must not turn a completed handoff
        // back into an upload loop when the transfer is correctly absent.
        try Data(repeating: 7, count: 4096).write(
            to: phoneLib.folder(for: memoID).appendingPathComponent("mic.wav"))
        try await store.delete(transferName, in: .transfer)
        let keepingPhone = CloudSyncCore(
            library: phoneLib, state: EngineState(library: phoneLib),
            store: store, key: key, policy: .phone,
            device: "phone-1", ingests: false, keepAudio: true)
        var afterAcknowledgement = CloudReport()
        await keepingPhone.upload(phoneLib.find(memoID)!, into: &afterAcknowledgement)
        try check(try await store.fetch(transferName, in: .transfer) == nil,
                  "acknowledged audio was uploaded again when retained")
        ok("retained audio stays local after a Mac acknowledges it")

        // MARK: the master travels, and the pipe stays a pipe

        // A meeting recorded on this Mac, with both tracks, which is the shape
        // the master exists for: until now the machine that recorded it was
        // the only machine that could ever play it back.
        let sharedID = "2026-08-14-090000-A11C"
        let sharedFolder = macLib.folder(for: sharedID)
        try FileManager.default.createDirectory(at: sharedFolder,
                                                withIntermediateDirectories: true)
        let sharedLeft = try tone(440, to: sharedFolder.appendingPathComponent("mic.wav"),
                                  seconds: 1)
        let sharedRight = try tone(660, to: sharedFolder.appendingPathComponent("system.wav"),
                                   seconds: 1)
        try Data(#"{"id":"\#(sharedID)","title":"Standup","source":"mac","state":"done"}"#.utf8)
            .write(to: sharedFolder.appendingPathComponent("metadata.json"))

        var sharePush = CloudReport()
        await mac.push(into: &sharePush)
        var shareMasters = CloudReport()
        await mac.pushMasters(into: &shareMasters)
        try check(shareMasters.pushedMasters > 0, "no master was published for a meeting")
        // And it is **not** left behind. This Mac holds the raw tracks, which
        // are a better copy in every way that matters here, so keeping the
        // master beside them would add 12% to every recording on the one
        // machine that never needs it: 1.5 GB on the real library, to hold a
        // second copy of audio it already has.
        try check(!FileManager.default.fileExists(
            atPath: AudioMaster.url(in: sharedFolder).path),
            "the device that published a master kept a second copy of its own audio")
        try check(macLib.find(sharedID)?.hasAudio == true,
                  "removing the published master took the recording's audio with it")

        let sharedMaster = CloudRecords.masterName(sharedID, key: key)
        try check(try await store.fetch(sharedMaster, in: .masters) != nil,
                  "the master is not in the zone it was published to")

        // **`z4` stays a pipe.** `ingest` lists it whole on every pass with no
        // change token, on purpose, so a transfer whose ingest failed is seen
        // again. A listing brings each record's assets with it, so one master
        // per recording in there would have every Mac downloading the whole
        // audio library every two minutes. That is why the masters have a zone
        // of their own, and this is the line that says so.
        let pipe = try await store.changes(in: .transfer, since: nil)
        try check(!pipe.changed.contains { $0.name == sharedMaster },
                  "a master landed in the transfer pipe")
        try check(try await store.fetch(sharedMaster, in: .transfer) == nil,
                  "the master is addressable in the pipe as well as its own zone")
        ok("a master is published to a zone of its own, and z4 stays a pipe")

        // A Mac that has the transcript and none of the audio, which is the
        // ordinary state of every second machine, and what it does about it.
        let keeperLib = try scratchLibrary(root.appendingPathComponent("mac-keeps"))
        let keeperMac = CloudSyncCore(library: keeperLib,
                                      state: EngineState(library: keeperLib),
                                      store: store, key: key, policy: .mac,
                                      device: "mac-keeps", ingests: true, keepAudio: true)
        var keeperPull = CloudReport()
        await keeperMac.pull(into: &keeperPull)
        try check(keeperLib.find(sharedID) != nil, "the recording never reached the second Mac")
        try check(keeperLib.find(sharedID)?.hasAudio == false,
                  "a pull brought the audio, which is not what a pull is for")

        // Nothing is asked for on nobody's word. A master is tens of megabytes
        // and "is it there" costs the same fetch as "give it to me", so the
        // cheap question is answered from the roster and never from the
        // container.
        var unasked = CloudReport()
        await keeperMac.pullMasters([], into: &unasked)
        try check(keeperLib.find(sharedID)?.hasAudio == false,
                  "an empty roster still cost a fetch of the audio")

        let holders = await mac.heartbeat(name: "Studio", kind: "Mac", appVersion: "test")
        var fetched = CloudReport()
        await keeperMac.pullMasters(holders, into: &fetched)
        try check(fetched.pulledMasters > 0, "the second Mac never received the audio")
        let received = try unwrap(keeperLib.find(sharedID), "the recording went missing")
        try check(received.hasAudio, "the master arrived without making the recording playable")

        // And it is the audio, rather than something the right size: the two
        // tones come back out of it, in the right halves.
        let takenApart = keeperLib.folder(for: sharedID)
        let againMic = takenApart.appendingPathComponent("mic.wav")
        let againSystem = takenApart.appendingPathComponent("system.wav")
        _ = try AudioMaster.split(received.masterURL, into: takenApart,
                                  micURL: againMic, systemURL: againSystem)
        try check(worst(sharedLeft, try peaks(againMic)) <= 1,
                  "the microphone track did not survive the round trip")
        try check(worst(sharedRight, try peaks(againSystem)) <= 1,
                  "the system track did not survive the round trip")
        ok("a device with no audio receives the master and can take it apart again")

        // The received copy must not go back up. Both devices now hold the
        // audio, and a device that republished what it was given would take
        // turns with the other one re-uploading the same bytes for ever.
        try FileManager.default.removeItem(at: againMic)
        try FileManager.default.removeItem(at: againSystem)
        var echo = CloudReport()
        await keeperMac.pushMasters(into: &echo)
        try check(echo.pushedMasters == 0,
                  "a device published back the master it had just been given")
        ok("a device that received a master does not publish it back")

        // The second Mac now says it holds this recording, which is what lets
        // the first one let go if it is ever asked to.
        let bothHold = await keeperMac.heartbeat(name: "Desk", kind: "Mac",
                                                 appVersion: "test")
        try check(bothHold.first { $0.id == "mac-keeps" }?.holds(sharedID) == true,
                  "a device that received a master did not report holding it")
        ok("a device that received a master reports holding it")

        // MARK: audio asked for by hand, on a device that keeps none

        // The phone is the case this exists for. **Keep audio on this iPhone**
        // is off by default and means "keep what I recorded"; it deliberately
        // does not mean "download every meeting the Macs made", which is
        // gigabytes. So there has to be a way to ask for one recording, and it
        // has to survive the pass that would otherwise take it straight back.
        var phoneCatchUp = CloudReport()
        await phone.pull(into: &phoneCatchUp)
        try check(phoneLib.find(sharedID) != nil, "the meeting never reached the phone")
        try check(phoneLib.find(sharedID)?.hasAudio == false,
                  "a pull brought the phone audio it never asked for")

        var asked = CloudReport()
        try check(await phone.fetchMaster(sharedID, into: &asked),
                  "asking for one recording's audio brought nothing down")
        try check(phoneLib.find(sharedID)?.hasAudio == true,
                  "the audio was fetched and not written")
        try check(EngineState(library: phoneLib).base[pinned: sharedID],
                  "audio asked for by hand was not pinned")

        // Now every Mac reports holding it and the phone keeps no audio, which
        // is exactly the state that freed everything else above.
        let macsHold = await mac.heartbeat(name: "Studio", kind: "Mac", appVersion: "test")
        var wouldFree = CloudReport()
        await phone.reclaim(macsHold, into: &wouldFree)
        try check(phoneLib.find(sharedID)?.hasAudio == true,
                  "the next pass took back the audio somebody had just asked for")
        ok("audio asked for by hand survives the reclaim that would otherwise free it")

        // And it can be given back, which is the other half: a person saying
        // "remove this" is not the reclaim invariant, it is somebody deciding
        // about their own disk. It still refuses when nobody else holds the
        // bytes, because wanting the space back is not wanting to lose the
        // recording.
        var refused = CloudReport()
        try check(!(await phone.freeMaster(sharedID, [], into: &refused)),
                  "audio was removed with nobody else reporting a copy")
        try check(phoneLib.find(sharedID)?.hasAudio == true,
                  "refusing to remove the audio removed it anyway")
        var released = CloudReport()
        try check(await phone.freeMaster(sharedID, macsHold, into: &released),
                  "audio a Mac holds could not be removed by hand")
        try check(phoneLib.find(sharedID)?.hasAudio == false,
                  "removing the audio left it on disk")
        try check(!EngineState(library: phoneLib).base[pinned: sharedID],
                  "removing the audio left the pin behind")
        ok("and it can be handed back, but never when nothing else holds it")

        // MARK: an import has a mixdown and nothing else

        // A legacy recording whose m4a held one track has no separate tracks
        // at all, and it used to get no master: a second device could neither
        // play it nor transcribe it again, for ever. The mixdown **is** the
        // everyone-track, so it can have one like anything else, and the
        // master has to say that is what it is: written back as `mic.wav` an
        // import is transcribed as the user's own voice and every speaker in
        // it comes out labelled `Me`.
        let importID = "2026-05-04-090000-0DDE"
        let importFolder = macLib.folder(for: importID)
        try FileManager.default.createDirectory(at: importFolder,
                                                withIntermediateDirectories: true)
        // Written as an m4a at 44.1 kHz stereo, which is what a legacy
        // recorder produced and is the case a straight read gets wrong: taking
        // those samples for 16 kHz mono would slow an hour of talk to three.
        try writeLegacyMixdown(to: importFolder.appendingPathComponent("mix.m4a"))
        try Data(#"{"id":"\#(importID)","title":"Imported call","source":"import","state":"done"}"#.utf8)
            .write(to: importFolder.appendingPathComponent("metadata.json"))
        let imported = try unwrap(macLib.find(importID), "the import did not load")
        try check(imported.hasMixdownOnly, "a mixdown-only recording did not say so")

        var importPush = CloudReport()
        await mac.push(into: &importPush)
        var importMaster = CloudReport()
        await mac.pushMasters(into: &importMaster)
        let importRecord = try unwrap(
            try await store.fetch(CloudRecords.masterName(importID, key: key), in: .masters),
            "no master was published for a mixdown-only recording")
        let importBlob = try CloudRecords.openMaster(importRecord, key: key)
        try check(importBlob.layout == .everyone,
                  "a mixdown's master did not say what its channel is")
        try check(importBlob.channels == 1, "a mixdown's master was not one channel")
        ok("a recording with only a mixdown gets a master, and it says it is everybody")

        // The receiving device writes it under the name that carries the
        // layout, and splits it to the side of the pipeline that reads the
        // everyone-track.
        let importerLib = try scratchLibrary(root.appendingPathComponent("mac-import"))
        let importer = CloudSyncCore(library: importerLib,
                                     state: EngineState(library: importerLib),
                                     store: store, key: key, policy: .mac,
                                     device: "mac-import", ingests: true, keepAudio: true)
        var importerPull = CloudReport()
        await importer.pull(into: &importerPull)
        var importerGot = CloudReport()
        await importer.pullMasters(await mac.heartbeat(name: "Studio", kind: "Mac",
                                                       appVersion: "test"),
                                   into: &importerGot)
        let landedImport = try unwrap(importerLib.find(importID),
                                      "the imported recording did not reach the second Mac")
        try check(landedImport.masterLayout == .everyone,
                  "the received master lost what its channel is")
        let importSplit = importerLib.folder(for: importID)
        _ = try AudioMaster.split(landedImport.masterURL, layout: .everyone, into: importSplit,
                                  micURL: importSplit.appendingPathComponent("mic.wav"),
                                  systemURL: importSplit.appendingPathComponent("system.wav"))
        try check(!FileManager.default.fileExists(
            atPath: importSplit.appendingPathComponent("mic.wav").path),
            "an imported meeting was split back as the user's own microphone")
        try check(FileManager.default.fileExists(
            atPath: importSplit.appendingPathComponent("system.wav").path),
            "an imported meeting was not split back as the everyone-track")
        ok("a mixdown master comes back as the everyone-track, never as the microphone")

        // A deleted recording takes its audio with it. Nothing lists the
        // master zone, so a master left behind is tens of megabytes nobody
        // would ever see again.
        try FileManager.default.removeItem(at: sharedFolder)
        var retract = CloudReport()
        await mac.push(into: &retract)
        try check(try await store.fetch(sharedMaster, in: .masters) == nil,
                  "deleting a recording left its audio in the container for ever")
        ok("deleting a recording deletes its audio master too")

        // MARK: exactly one transcriber

        // The same race as the ingest below, one layer up. Audio landing on
        // every device removes the accident that used to serialise this: a
        // recording only one Mac could hear was a recording only one Mac could
        // transcribe.
        let jobID = "2026-08-12-131313-BEEF"
        try seed(macLib, id: jobID,
                 metadata: #"{"id":"\#(jobID)","title":"Standup","source":"mac","state":"pending"}"#,
                 transcript: nil)
        var jobPush = CloudReport()
        await mac.push(into: &jobPush)

        let rival = CloudSyncCore(library: macLib, state: EngineState(library: macLib),
                                  store: store, key: key, policy: .mac,
                                  device: "mac-9", ingests: true)
        async let leaseHere = mac.takeTranscriptionLease(jobID)
        async let leaseThere = rival.takeTranscriptionLease(jobID)
        let both = await [leaseHere, leaseThere]
        try check(both.filter(\.granted).count == 1,
                  "\(both.filter(\.granted).count) devices took the same transcription")
        try check(both.contains { $0.holder != nil },
                  "the device that lost was not told who has it")
        ok("exactly one device may transcribe a recording at a time")

        // **Which** device won is a real race and not a property worth
        // asserting: this used to name `mac-1` as the loser and passed until
        // the suite grew enough around it to change the timing, at which point
        // it failed for a reason that had nothing to do with leasing. What has
        // to be true is that both devices read the same holder and exactly one
        // of them reads it as itself.
        let here = await mac.transcriptionLease(jobID)
        let there = await rival.transcriptionLease(jobID)
        try check(here != nil && there != nil, "the lease was not readable by both devices")
        try check(here?.device == there?.device, "two devices named different transcribers")
        try check([here?.mine, there?.mine].filter { $0 == true }.count == 1,
                  "the lease did not read as exactly one device's own")
        ok("both devices name the same transcriber, and only one of them is itself")

        // A lease that never expired would park a recording for ever on a Mac
        // that died mid-run, which is the failure the ingest claim already
        // learned about.
        let later = Date().addingTimeInterval(1_000)
        try check(await mac.transcriptionLease(jobID, now: later) == nil,
                  "the lease outlived its window")
        try check(await rival.takeTranscriptionLease(jobID, now: later).granted,
                  "an expired lease could not be taken over")
        ok("a lease expires, so a Mac that dies mid-run does not park the work")

        await rival.releaseTranscriptionLease(jobID)
        try check(await mac.transcriptionLease(jobID) == nil,
                  "releasing the lease left it held")
        try check(await mac.takeTranscriptionLease(jobID).granted,
                  "a released lease could not be retaken")
        await mac.releaseTranscriptionLease(jobID)
        ok("releasing frees it at once, rather than after the window")

        // Reading the record can succeed while the claim write itself fails.
        // That is not proof that another device won. The old fallback invented
        // a holder named "another device" for the full lease window, removed
        // the job from the queue, and repeated the same stall after relaunch.
        // When a read-back still shows no holder, this is the same safe offline
        // answer as an unreachable container: proceed locally, with the caller
        // retaining the caveat that no lease was recorded.
        let writeFailure = CloudSyncCore(
            library: macLib, state: EngineState(library: macLib),
            store: SaveFailureStore(base: store), key: key, policy: .mac,
            device: "mac-write-failure", ingests: true, keepAudio: true)
        try check(await writeFailure.takeTranscriptionLease(jobID) == .unreachable,
                  "a failed claim write with no real holder invented one")
        ok("a failed claim write cannot invent another transcriber")

        // MARK: the offline window, which nothing could refuse in

        // A Mac with no container still transcribes its own recording, because
        // Listen works with the network off and the cost of two Macs doing the
        // same hour of work is wasted CPU rather than lost data. What was never
        // measured is what happens to a recording another Mac had already
        // started, and the answer used to be "both of them do it": `state:
        // transcribing` was described as travelling in the metadata and nothing
        // read it.
        let offlineLib = try scratchLibrary(root.appendingPathComponent("mac-offline"))
        let offline = CloudSyncCore(library: offlineLib,
                                    state: EngineState(library: offlineLib),
                                    store: UnreachableStore(), key: key, policy: .mac,
                                    device: "mac-offline", ingests: true, keepAudio: true)
        try check(await offline.takeTranscriptionLease(jobID) == .unreachable,
                  "an unreachable container did not say so")
        try check(await offline.takeTranscriptionLease(jobID).granted,
                  "an offline Mac was stopped from transcribing")
        try check(await offline.transcriptionLease(jobID) == nil,
                  "an unreachable container answered who holds a lease")
        ok("an unreachable container grants the lease and says that is what it did")

        // The deterrent, asked rather than assumed. These are the four fields
        // as they arrive in `metadata.json`, which is the only thing an offline
        // Mac has to go on.
        let began = Date(timeIntervalSince1970: 1_760_000_000)
        func looksLive(by who: String?, state: String?, started: Date?, finished: String? = nil,
                       at now: Date) -> Bool {
            CloudSyncCore.othersRunLooksLive(
                transcribedBy: who, state: state,
                started: started.map(Metadata.stamp), finished: finished,
                device: "mac-offline", now: now)
        }
        try check(looksLive(by: "mac-1", state: "transcribing", started: began,
                            at: began.addingTimeInterval(300)),
                  "a run another Mac started five minutes ago read as nobody's")
        try check(!looksLive(by: "mac-offline", state: "transcribing", started: began,
                             at: began.addingTimeInterval(300)),
                  "this Mac's own run read as somebody else's")
        try check(!looksLive(by: "mac-1", state: "done", started: began,
                             at: began.addingTimeInterval(300)),
                  "a finished recording read as a run in progress")
        try check(!looksLive(by: "mac-1", state: "transcribing", started: began,
                             finished: Metadata.stamp(began), at: began.addingTimeInterval(300)),
                  "a run that recorded its own end read as still going")
        try check(!looksLive(by: "mac-1", state: "transcribing", started: nil,
                             at: began.addingTimeInterval(300)),
                  "a run with no start time was believed anyway")
        // And it expires, so a Mac that died mid-run cannot park a recording
        // for ever on a machine that cannot ask anybody about it.
        try check(!looksLive(by: "mac-1", state: "transcribing", started: began,
                             at: began.addingTimeInterval(CloudSyncCore.offlineGrace + 60)),
                  "an abandoned run was believed past its grace")
        try check(looksLive(by: "mac-1", state: "transcribing", started: began,
                            at: began.addingTimeInterval(CloudSyncCore.offlineGrace - 60)),
                  "a run inside its grace was not believed")
        ok("offline, another device's unfinished run is believed for six hours and no longer")

        // MARK: exactly one claimant

        let contested = StoredRecord(
            name: CloudNaming.recordName(.audioTransfer, "2026-08-12-121212-CAFE", key: key),
            type: .audioTransfer, payload: try key.seal(Data("x".utf8)))
        let saved = try await store.save(contested)
        let second_mac = CloudSyncCore(library: macLib, state: EngineState(library: macLib),
                                       store: store, key: key, policy: .mac,
                                       device: "mac-2", ingests: true)
        async let first = mac.claim(saved, preferred: nil, window: 300)
        async let other = second_mac.claim(saved, preferred: nil, window: 300)
        let winners = [try await first, try await other].filter { $0 }.count
        try check(winners == 1, "\(winners) devices claimed one ingest, not 1")
        ok("exactly one device wins a contested ingest, before downloading it")

        // MARK: deletion, and the token that expired

        macLib.deleteNote("nothing")   // no-op, proves a delete of the absent is fine
        let noteSlug = "quarterly-review"
        try macLib.writeNote(Note(slug: noteSlug, title: "Quarterly review", created: "",
                                  updated: "", source: "you", recordings: [id],
                                  body: "What we agreed."), expecting: nil)
        var notePush = CloudReport()
        await mac.push(into: &notePush)
        var notePull = CloudReport()
        await phone.pull(into: &notePull)
        try check(phoneLib.note(noteSlug) != nil, "the note did not arrive")
        ok("a note reaches the other device")

        // Hand-written markdown is part of the on-disk format, not an import
        // accident. Prove both liberal forms through the whole sync rather than
        // only through `Note.parse`, because a note that parses locally but is
        // skipped by the record path is still a note that does not sync.
        let plainSlug = "plain-markdown"
        let plain = "# A note made in Finder\n\nNo frontmatter here.\n"
        try plain.write(to: macLib.notes.appendingPathComponent(plainSlug + ".md"),
                        atomically: true, encoding: .utf8)
        let blockSlug = "block-recordings"
        let block = """
        ---
        title: "Two meetings"
        created: 2026-08-12T12:00:00Z
        updated: 2026-08-12T12:00:00Z
        source: you
        recordings:
          - "\(id)"
          - "\(memoID)"
        ---

        Kept as a YAML block sequence.
        """
        try block.write(to: macLib.notes.appendingPathComponent(blockSlug + ".md"),
                        atomically: true, encoding: .utf8)
        var handwrittenPush = CloudReport()
        await mac.push(into: &handwrittenPush)
        var handwrittenPull = CloudReport()
        await phone.pull(into: &handwrittenPull)
        let landedPlain = try checkNote(phoneLib.note(plainSlug), named: plainSlug)
        try check(landedPlain.title == "A note made in Finder"
                  && landedPlain.recordings.isEmpty,
                  "a note without frontmatter changed shape")
        let landedBlock = try checkNote(phoneLib.note(blockSlug), named: blockSlug)
        try check(landedBlock.recordings == [id, memoID],
                  "a YAML block sequence lost its recordings")
        ok("hand-written notes sync with no frontmatter or a YAML block sequence")

        // MARK: tags on a note, and the digest that carries them

        // **The assertion that says the library does not all re-sync.**
        //
        // `Note.version` gained `tags`, and two devices computing it by
        // different formulas push and pull the same note for ever: `pullNote`
        // stamps the sender's digest into the base while push stamps its own,
        // so neither side ever agrees with itself. Appending the tags only when
        // there are any is what bounds that to notes which actually carry one,
        // and this constant is what says it stayed bounded. It was taken from
        // the build before the field existed; if it changes, every untagged
        // note in every library on every device is about to be re-sent, and
        // that is a decision rather than a refactor.
        //
        // Every field is a literal, including the recording id, so the constant
        // does not move when this harness changes what it seeds.
        let untagged = Note(slug: "digest-probe", title: "Quarterly review",
                            created: "", updated: "", source: "you",
                            recordings: ["2026-08-20-090000-AAAA"],
                            body: "What we agreed.")
        try check(untagged.version
                  == "e73500f3277774a26c473edea2f9852220fbd470ca93862e5b887b66d750e7ad",
                  "the digest of an untagged note moved: \(untagged.version)")
        ok("an untagged note's digest is unchanged, so nothing already on disk re-syncs")

        var tagged = untagged
        tagged.tags = ["kinsight"]
        try check(tagged.version != untagged.version,
                  "tags are not in the digest, so a tag-only change would never push")
        ok("a tag changes the digest, so filing travels")

        // Through the whole sync, not only through `version`: a note that
        // parses locally and is dropped by the record path is a note whose
        // tags do not sync.
        let filedSlug = "filed-note"
        try macLib.writeNote(Note(slug: filedSlug, title: "Filed", created: "",
                                  updated: "", source: "you", recordings: [id],
                                  body: "Body.", tags: ["kinsight", "acme"]),
                             expecting: nil)
        var filedPush = CloudReport()
        await mac.push(into: &filedPush)
        var filedPull = CloudReport()
        await phone.pull(into: &filedPull)
        let landedFiled = try checkNote(phoneLib.note(filedSlug), named: filedSlug)
        try check(landedFiled.tags == ["kinsight", "acme"],
                  "the tags did not cross: \(landedFiled.tags)")
        ok("a tagged note crosses with its filing intact")

        // A second pass sends nothing. This is the churn check: with the two
        // devices computing the same formula it is zero, and the day it is not,
        // the digest has moved on one side only.
        var settle = CloudReport()
        await mac.push(into: &settle)
        try check(settle.pushedNotes == 0,
                  "a settled library pushed \(settle.pushedNotes) notes on a second pass")
        ok("and a second pass pushes nothing, so tagged notes do not ping-pong")

        // Clearing the last tag has to reach the other side. It is why the
        // `tags:` key is written even when the list is empty: `Library.writeNote`
        // merges `extra` with "absent means unchanged", so a clear spelled as a
        // missing key would be put straight back by a peer still holding them.
        var cleared = try checkNote(macLib.note(filedSlug), named: filedSlug)
        // The digest *before* the edit, which is what the swap is against. Taken
        // after mutating, it is the new one, and the write is refused against
        // its own change.
        let wasFiled = cleared.version
        cleared.tags = []
        try macLib.writeNote(cleared, expecting: wasFiled, stamp: false)
        var clearPush = CloudReport()
        await mac.push(into: &clearPush)
        var clearPull = CloudReport()
        await phone.pull(into: &clearPull)
        let landedClear = try checkNote(phoneLib.note(filedSlug), named: filedSlug)
        try check(landedClear.tags.isEmpty,
                  "clearing the tags did not cross: \(landedClear.tags)")
        ok("and taking every tag off crosses too, rather than being merged back")

        // The hole modelling `tags` closed on the way past. An unknown key with
        // an empty value used to take both routes at once: into `extra` as a
        // bare scalar, and its `- ` lines into a sequence nothing read, so
        // writing the note back left `tags:` with nothing after it.
        let filedBlockSlug = "filed-by-hand"
        let filedBlock = """
        ---
        title: "Filed in Finder"
        created: 2026-08-12T12:00:00Z
        updated: 2026-08-12T12:00:00Z
        source: you
        tags:
          - alpha
          - "beta gamma"
        recordings: []
        ---

        Body.
        """
        try filedBlock.write(to: macLib.notes.appendingPathComponent(filedBlockSlug + ".md"),
                             atomically: true, encoding: .utf8)
        var blockTagPush = CloudReport()
        await mac.push(into: &blockTagPush)
        var blockTagPull = CloudReport()
        await phone.pull(into: &blockTagPull)
        let landedFiledBlock = try checkNote(phoneLib.note(filedBlockSlug),
                                             named: filedBlockSlug)
        try check(landedFiledBlock.tags == ["alpha", "beta gamma"],
                  "a hand-written tag list was lost crossing: \(landedFiledBlock.tags)")
        ok("a YAML block sequence of tags survives a whole sync")

        try await store.delete(CloudNaming.recordName(.note, noteSlug, key: key), in: .library)
        var deletion = CloudReport()
        await phone.pull(into: &deletion)
        try check(phoneLib.note(noteSlug) == nil, "a deletion did not propagate")
        ok("a deletion propagates rather than coming back")

        // The other half of that round trip, which nothing covered.
        //
        // The seam above deletes the record itself and then checks the
        // receiving device, so it proves a device obeys a deletion and says
        // nothing about whether a device ever reports one. It did not: deleting
        // a recording in the Mac app removed it from that Mac and left it in
        // the container and on every other device. Found on the real library by
        // counting, 71 against 72, not by this suite.
        // Its own recording, seeded here rather than reusing one above, so
        // deleting it cannot disturb what the later seams still assert about.
        let doomedID = "2026-08-12-121212-DEAD"
        try seed(macLib, id: doomedID,
                 metadata: #"{"id":"\#(doomedID)","title":"Delete me","source":"mac","state":"done"}"#,
                 transcript: #"{"segments":[],"duration":5,"model":"parakeet-v3"}"#)
        var sendDoomed = CloudReport()
        await mac.push(into: &sendDoomed)
        var getDoomed = CloudReport()
        await phone.pull(into: &getDoomed)
        try check(phoneLib.find(doomedID) != nil,
                  "the recording to delete never reached the other device")

        try FileManager.default.removeItem(at: macLib.folder(for: doomedID))
        var outgoing = CloudReport()
        await mac.push(into: &outgoing)
        try check(outgoing.deletedRemotely == 1,
                  "deleting a recording here did not reach the container")
        var arrives = CloudReport()
        await phone.pull(into: &arrives)
        try check(phoneLib.find(doomedID) == nil,
                  "a recording deleted on the Mac survived on the phone")

        // A recording that merely fails to load must not look like one that was
        // deleted, or a single corrupt sidecar takes the last copy of a meeting
        // off every device at once.
        let corruptFolder = macLib.folder(for: id)
        let goodMetadata = try Data(contentsOf: corruptFolder.appendingPathComponent("metadata.json"))
        try Data("{ not json".utf8).write(to: corruptFolder.appendingPathComponent("metadata.json"))
        try check(macLib.find(id) == nil, "the corrupt recording still loaded")
        var corrupt = CloudReport()
        await mac.push(into: &corrupt)
        try check(corrupt.deletedRemotely == 0,
                  "an unreadable metadata.json deleted a recording everywhere")
        try goodMetadata.write(to: corruptFolder.appendingPathComponent("metadata.json"))
        ok("a deletion made here reaches the other device, and corruption does not")

        // The library disappearing is not the library being emptied.
        //
        // A scratch library removed and recreated at the same path kept its
        // state directory, which is keyed on the path, so the next pass held a
        // stamp for every recording and a folder for none. Seventy-three
        // recordings and fourteen notes went from the container and from both
        // Macs. This is that, in one second, against a fake store.
        // More than one, because "held none, missing one" is somebody deleting
        // the last recording they had, which is ordinary and must still work.
        // What must not work is every recording going at once.
        for suffix in ["CAFE", "BEAD"] {
            let extra = "2026-08-13-101010-\(suffix)"
            try seed(macLib, id: extra,
                     metadata: #"{"id":"\#(extra)","title":"Kept","source":"mac","state":"done"}"#,
                     transcript: #"{"segments":[],"duration":2,"model":"parakeet-v3"}"#)
        }
        var stamping = CloudReport()
        await mac.push(into: &stamping)

        let before = (try? await store.changes(in: .library, since: nil))?.changed.count ?? 0
        try check(before > 2, "the vanishing test needs a library to lose")
        // Moved aside rather than deleted, and put back afterwards. The first
        // version removed them, which left the library wrecked for every seam
        // that followed and made a later one fail for a reason that had nothing
        // to do with what it tested.
        let aside = macLib.root.appendingPathComponent("aside")
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        let vanishing = (try? FileManager.default.contentsOfDirectory(
            at: macLib.recordings, includingPropertiesForKeys: nil)) ?? []
        for entry in vanishing {
            try FileManager.default.moveItem(
                at: entry, to: aside.appendingPathComponent(entry.lastPathComponent))
        }
        var vanished = CloudReport()
        await mac.push(into: &vanished)
        for entry in vanishing {
            try FileManager.default.moveItem(
                at: aside.appendingPathComponent(entry.lastPathComponent), to: entry)
        }
        try FileManager.default.removeItem(at: aside)

        let after = (try? await store.changes(in: .library, since: nil))?.changed.count ?? 0
        try check(after == before,
                  "a library that lost everything deleted \(before - after) records")
        try check(!vanished.errors.isEmpty,
                  "it deleted nothing and also said nothing")
        ok("a library that has lost everything does not empty the container")

        // A deletion obeyed is still a deletion recoverable.
        let victim = "2026-08-13-111111-C0FE"
        try seed(macLib, id: victim,
                 metadata: #"{"id":"\#(victim)","title":"Recoverable","source":"mac","state":"done"}"#,
                 transcript: #"{"segments":[],"duration":2,"model":"parakeet-v3"}"#)
        var sendVictim = CloudReport()
        await mac.push(into: &sendVictim)
        var getVictim = CloudReport()
        await phone.pull(into: &getVictim)
        try check(phoneLib.find(victim) != nil, "the recording never reached the phone")

        try FileManager.default.removeItem(at: macLib.folder(for: victim))
        var send = CloudReport()
        await mac.push(into: &send)
        var receive = CloudReport()
        await phone.pull(into: &receive)
        try check(phoneLib.find(victim) == nil, "the phone kept a deleted recording")
        let kept = Trash.root(in: phoneLib)
        let found = (try? FileManager.default.subpathsOfDirectory(atPath: kept.path)) ?? []
        try check(found.contains { $0.hasSuffix(victim) },
                  "the phone deleted it outright instead of keeping it back")

        // And a fortnight later it is gone for real.
        Trash.purge(in: phoneLib, now: Date().addingTimeInterval(15 * 86_400))
        let after15 = (try? FileManager.default.subpathsOfDirectory(atPath: kept.path)) ?? []
        try check(!after15.contains { $0.hasSuffix(victim) },
                  "the trash never empties")
        ok("a deletion obeyed here is recoverable for a fortnight")

        // **And so is a note, which it was not.**
        //
        // Two paths apply somebody else's note deletion, and only one of them
        // trashed it. The pull side goes through `deleteLocally`, which does.
        // The push side is the branch for a pass whose pull failed on the
        // network, and it called `deleteNote`, a bare `removeItem`. That is the
        // path a real library took: `sync_deleted count: 4`, four notes gone,
        // and nothing in the trash to put back.
        //
        // Driven through the push branch on purpose, by deleting the record
        // behind the phone's back so its pull has nothing to react to.
        let doomed = "note-worth-keeping"
        try macLib.writeNote(Note(slug: doomed, title: "Worth keeping", created: "",
                                  updated: "", source: "you", recordings: [id],
                                  body: "Something somebody typed."), expecting: nil)
        var sendNote = CloudReport()
        await mac.push(into: &sendNote)
        var takeNote = CloudReport()
        await phone.pull(into: &takeNote)
        try check(phoneLib.note(doomed) != nil, "the note never reached the phone")

        try await store.delete(CloudNaming.recordName(.note, doomed, key: key), in: .library)
        var phonePush = CloudReport()
        await phone.push(into: &phonePush)
        try check(phoneLib.note(doomed) == nil, "the phone kept a deleted note")
        let notesKept = Trash.root(in: phoneLib)
        let notesFound = (try? FileManager.default
            .subpathsOfDirectory(atPath: notesKept.path)) ?? []
        try check(notesFound.contains { $0.hasSuffix(doomed + ".md") },
                  "a note deleted on the push side was removed outright, not trashed")
        ok("and a note deleted on somebody else's say-so is recoverable too")

        // The case a real container will not stage on demand, and the one that
        // silently resurrects deleted meetings.
        await store.setExpireNextToken(true)
        var expired = CloudReport()
        await phone.pull(into: &expired)
        try check(phoneLib.note(noteSlug) == nil,
                  "an expired change token resurrected a deleted note")
        try check(phoneLib.find(id) != nil,
                  "an expired change token deleted a recording that still exists")
        ok("a refetch after an expired token neither resurrects nor destroys")

        // MARK: forgetting a voiceprint sticks, in the exact order that undid it

        // A third Mac, because the resurrection race needs a device whose
        // files are stale and whose pass runs in the wrong order on purpose.
        let mac3Lib = try scratchLibrary(root.appendingPathComponent("mac-3"))
        try? FileManager.default.removeItem(at: EngineState(library: mac3Lib).root)
        let mac3 = CloudSyncCore(library: mac3Lib, state: EngineState(library: mac3Lib),
                                 store: store, key: key, policy: .mac,
                                 device: "mac-3", ingests: false)

        let vp1 = "2026-08-13-140000-AAAA", vp2 = "2026-08-13-150000-BBBB"
        for (vpID, bank) in [(vp1, #"{"Anna":{"embedding":[0.1]},"Ben":{"embedding":[0.2]}}"#),
                             (vp2, #"{"Anna":{"embedding":[0.3]}}"#)] {
            try seed(macLib, id: vpID,
                     metadata: #"{"id":"\#(vpID)","title":"Voices","source":"mac","state":"done"}"#,
                     transcript: #"{"segments":[],"duration":2,"model":"parakeet-v3"}"#)
            try Data(bank.utf8).write(to: macLib.folder(for: vpID)
                .appendingPathComponent("embeddings.json"))
        }
        var vpSend = CloudReport()
        await mac.push(into: &vpSend)
        await mac.pushVoiceprints(into: &vpSend)
        try check(vpSend.errors.isEmpty, "seeding voiceprints failed: \(vpSend.errors)")
        var vpGet = CloudReport()
        await mac3.pull(into: &vpGet)
        await mac3.pullVoiceprints(into: &vpGet)
        let crossed = try Data(contentsOf: mac3Lib.folder(for: vp1)
            .appendingPathComponent("embeddings.json"))
        try check(crossed == Data(contentsOf: macLib.folder(for: vp1)
            .appendingPathComponent("embeddings.json")),
                  "a voiceprint bank did not cross byte-identical between Macs")
        ok("voiceprint banks cross byte-identical between Macs")

        // The forget, on the first Mac only.
        var stones = VoiceprintTombstones.load(macLib)
        stones.forget("Anna")
        stones.save(macLib)
        var forgetPush = CloudReport()
        await mac.pushVoiceprints(into: &forgetPush)
        try check(forgetPush.errors.isEmpty, "the forget pass failed: \(forgetPush.errors)")
        let vp1Bank = String(decoding: try Data(contentsOf: macLib.folder(for: vp1)
            .appendingPathComponent("embeddings.json")), as: UTF8.self)
        try check(!vp1Bank.contains("Anna") && vp1Bank.contains("Ben"),
                  "the forget did not strip the local bank")
        try check(!FileManager.default.fileExists(atPath: macLib.folder(for: vp2)
            .appendingPathComponent("embeddings.json").path),
                  "a bank holding only the forgotten person survived")
        let vp2Record = try await store.fetch(
            CloudNaming.recordName(.voiceprint, vp2, key: key), in: .voiceprints)
        try check(vp2Record == nil, "the emptied bank's record was not deleted")
        let tombRecord = try await store.fetch(
            CloudNaming.recordName(.voiceprint, VoiceprintTombstones.cloudKey, key: key),
            in: .voiceprints)
        try check(tombRecord != nil, "no tombstone record was pushed")
        ok("a forget strips the banks, empties the emptied record, and leaves a tombstone")

        // The race, deliberately in the wrong order: the stale Mac pushes
        // before it pulls, which is exactly how a fat bank comes back.
        var wrongOrder = CloudReport()
        await mac3.pushVoiceprints(into: &wrongOrder)
        let resurrected = try await store.fetch(
            CloudNaming.recordName(.voiceprint, vp1, key: key), in: .voiceprints)
        let resurrectedBank = try CloudRecords.openBlob(
            try unwrap(resurrected, "the stale Mac pushed nothing"), key: key)
        try check(String(decoding: resurrectedBank.contents, as: UTF8.self).contains("Anna"),
                  "the race this design exists for did not occur, so it proves nothing")
        var repairRace = CloudReport()
        await mac3.pushVoiceprints(into: &repairRace)
        var settleMac = CloudReport()
        await mac.pullVoiceprints(into: &settleMac)
        for (lib, name) in [(macLib, "mac"), (mac3Lib, "mac-3")] {
            for vpID in [vp1, vp2] {
                let file = lib.folder(for: vpID).appendingPathComponent("embeddings.json")
                if let data = try? Data(contentsOf: file) {
                    try check(!String(decoding: data, as: UTF8.self).contains("Anna"),
                              "\(name) still holds the forgotten voiceprint in \(vpID)")
                }
            }
        }
        let settled = try await store.fetch(
            CloudNaming.recordName(.voiceprint, vp1, key: key), in: .voiceprints)
        let settledBank = try CloudRecords.openBlob(
            try unwrap(settled, "the repaired record vanished"), key: key)
        try check(!String(decoding: settledBank.contents, as: UTF8.self).contains("Anna"),
                  "the container still holds the forgotten voiceprint")
        try check(try await store.fetch(
            CloudNaming.recordName(.voiceprint, vp2, key: key), in: .voiceprints) == nil,
                  "the emptied record came back and stayed")
        ok("a stale Mac pushing before it pulls is repaired on its next pass")

        // Convergence: another pass on both changes nothing in the zone.
        let snapshotBefore = (try? await store.changes(in: .voiceprints, since: nil))?
            .changed.map { $0.name + ":" + sha256Hex($0.payload) }.sorted() ?? []
        var idleA = CloudReport(), idleB = CloudReport()
        await mac.pushVoiceprints(into: &idleA)
        await mac3.pushVoiceprints(into: &idleB)
        let snapshotAfter = (try? await store.changes(in: .voiceprints, since: nil))?
            .changed.map { $0.name + ":" + sha256Hex($0.payload) }.sorted() ?? []
        try check(snapshotBefore == snapshotAfter,
                  "a settled voiceprint zone was rewritten by an idle pass")
        ok("the voiceprint zone converges and stays put")

        // A deleted recording takes its voiceprint record with it.
        let vp3 = "2026-08-13-160000-CCCC"
        try seed(macLib, id: vp3,
                 metadata: #"{"id":"\#(vp3)","title":"Leaving","source":"mac","state":"done"}"#,
                 transcript: #"{"segments":[],"duration":2,"model":"parakeet-v3"}"#)
        try Data(#"{"Cara":{"embedding":[0.4]}}"#.utf8).write(
            to: macLib.folder(for: vp3).appendingPathComponent("embeddings.json"))
        var vp3Send = CloudReport()
        await mac.push(into: &vp3Send)
        await mac.pushVoiceprints(into: &vp3Send)
        try FileManager.default.removeItem(at: macLib.folder(for: vp3))
        var vp3Delete = CloudReport()
        await mac.push(into: &vp3Delete)
        try check(try await store.fetch(
            CloudNaming.recordName(.recording, vp3, key: key), in: .library) == nil,
                  "the deleted recording's record survived")
        try check(try await store.fetch(
            CloudNaming.recordName(.voiceprint, vp3, key: key), in: .voiceprints) == nil,
                  "the deleted recording left its voiceprint behind")
        ok("deleting a recording deletes its voiceprint record too")

        // Unforget: a re-taught name crosses again.
        var pardon = VoiceprintTombstones.load(macLib)
        pardon.unforget("Anna", now: Date().addingTimeInterval(5))
        pardon.save(macLib)
        try Data(#"{"Anna":{"embedding":[0.9]}}"#.utf8).write(
            to: macLib.folder(for: vp2).appendingPathComponent("embeddings.json"))
        var reSend = CloudReport()
        await mac.pushVoiceprints(into: &reSend)
        var reGet = CloudReport()
        await mac3.pullVoiceprints(into: &reGet)
        let returned = try Data(contentsOf: mac3Lib.folder(for: vp2)
            .appendingPathComponent("embeddings.json"))
        try check(String(decoding: returned, as: UTF8.self).contains("Anna"),
                  "an unforgotten voiceprint could not come back")
        ok("unforget lets a re-taught voiceprint travel again")

        // Expiry: an entry old enough to be dead weight is dropped on merge.
        let stale = VoiceprintTombstones(entries: [.init(
            name: "Old", at: Metadata.stamp(Date().addingTimeInterval(-91 * 86_400)))])
        try check(VoiceprintTombstones.merged(stale, VoiceprintTombstones()).entries.isEmpty,
                  "an expired tombstone survived a merge")
        ok("tombstones expire after 90 days rather than naming people for ever")

        // And the phone still receives none of it, tombstone included.
        var phoneVP = CloudReport()
        await phone.pullVoiceprints(into: &phoneVP)
        try check(!FileManager.default.fileExists(
            atPath: VoiceprintTombstones.url(in: phoneLib).path),
                  "the tombstone list reached the phone")
        ok("the voiceprint zone, tombstones included, never reaches the phone")

        return out
    }

    /// Unwrap for the suite: the failure text is the assertion.
    private static func unwrap<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw Failure(description: what) }
        return value
    }

    private static func checkNote(_ note: Note?, named slug: String) throws -> Note {
        guard let note else { throw Failure(description: "the \(slug) note did not arrive") }
        return note
    }

    // MARK: - Scratch

    /// A container that cannot be reached, for the one window the design
    /// flagged and could not measure.
    ///
    /// `takeTranscriptionLease` answers `.unreachable` here rather than
    /// refusing, because Listen works with the network off and a Mac must
    /// still transcribe its own recording. What that costs, and what the
    /// second deterrent is, is the thing this store exists to make provable.
    actor UnreachableStore: RecordStore {
        func save(_ record: StoredRecord) async throws -> StoredRecord {
            throw StoreError.unavailable("the network is off")
        }
        func delete(_ name: String, in zone: CloudNaming.Zone) async throws {
            throw StoreError.unavailable("the network is off")
        }
        func changes(in zone: CloudNaming.Zone, since token: String?) async throws -> StoreChanges {
            throw StoreError.unavailable("the network is off")
        }
        func fetch(_ name: String, in zone: CloudNaming.Zone) async throws -> StoredRecord? {
            throw StoreError.unavailable("the network is off")
        }
    }

    /// A store that can read the shared container but cannot land a write.
    /// This is distinct from `UnreachableStore`: it reproduces the partial
    /// CloudKit failure that used to fabricate a foreign lease.
    actor SaveFailureStore: RecordStore {
        let base: MemoryStore

        init(base: MemoryStore) { self.base = base }

        func save(_ record: StoredRecord) async throws -> StoredRecord {
            throw StoreError.unavailable("the claim write failed")
        }
        func delete(_ name: String, in zone: CloudNaming.Zone) async throws {
            try await base.delete(name, in: zone)
        }
        func changes(in zone: CloudNaming.Zone,
                     since token: String?) async throws -> StoreChanges {
            try await base.changes(in: zone, since: token)
        }
        func fetch(_ name: String, in zone: CloudNaming.Zone) async throws -> StoredRecord? {
            try await base.fetch(name, in: zone)
        }
    }

    /// A library with nothing behind it, **including the state that is kept
    /// somewhere else**.
    ///
    /// `EngineState` lives beside the library rather than inside it, keyed on
    /// the library path, so removing the scratch tree at the top of `run` does
    /// not clear it. A second run of this suite therefore started holding a
    /// change token issued by the first run's store, and a fresh `MemoryStore`
    /// has never heard of that token: nothing was fetched, and the failure
    /// surfaced several assertions later as a missing `metadata.json` on
    /// whichever library was unlucky. Two of the libraries here were cleared by
    /// hand and the rest were not, so the suite passed once per scratch
    /// directory and then began failing for a reason that had nothing to do
    /// with the code under test.
    ///
    /// Hermetic means starting from nothing, and nothing includes this.
    private static func scratchLibrary(_ root: URL) throws -> Library {
        let library = Library(root: root)
        try? FileManager.default.removeItem(at: EngineState(library: library).root)
        try library.prepare()
        return library
    }

    /// An m4a of the shape a legacy recorder wrote: one track, stereo, at a
    /// sample rate that is not the one Listen works in. Both of those are what
    /// make a straight read of it wrong.
    private static func writeLegacyMixdown(to url: URL) throws {
        let rate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 64_000,
        ]
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: 2, interleaved: false)!
        var written = 0
        let frames = Int(rate * 2)      // two seconds
        while written < frames {
            let count = Swift.min(4096, frames - written)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(count))
            else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<2 {
                guard let samples = buffer.floatChannelData?[channel] else { break }
                for i in 0..<count {
                    let t = Double(written + i) / rate
                    samples[i] = Float(sin(t * 440 * 2 * Double.pi) * 0.4)
                }
            }
            try file?.write(from: buffer)
            written += count
        }
        // The same finalisation trap `AudioMaster.write` records.
        file = nil
    }

    private static func seed(_ library: Library, id: String, metadata: String,
                             transcript: String?, audio: Data? = nil) throws {
        let folder = library.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let transcript {
            try Data(transcript.utf8).write(to: folder.appendingPathComponent("transcript.json"))
        }
        if let audio {
            try audio.write(to: folder.appendingPathComponent("mic.wav"))
        }
        // Last, always.
        try Data(metadata.utf8).write(to: folder.appendingPathComponent("metadata.json"))
    }
}
