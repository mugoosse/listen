import Foundation
import ListenKit

/// `listen audio …`: what audio exists, where it is, and what a master costs.
///
/// It exists for the same reason `listen sync inspect` does. Audio replicated
/// across three devices is a subsystem whose whole state is files that are not
/// there, and absence cannot tell "nobody has this" apart from "somebody has it
/// and has not said so". Before this the only way to ask was to open Finder on
/// each machine in turn.
///
/// The `--build` verb also exists so the encoder can be measured on real
/// meetings rather than on synthetic tones. `FakeSync` proves that a master
/// round-trips sample for sample; it says nothing about what an hour of
/// conversation costs in seconds and megabytes on this Mac.
@MainActor
enum AudioCLI {
    static func run(_ args: [String]) async -> Never {
        var rest = args
        let build = rest.contains("--build")
        let check = rest.contains("--check")
        rest.removeAll { $0.hasPrefix("--") }
        // Before the roster, because this asks nothing of the network and the
        // whole point of it is a fast answer straight after a call.
        if check { checkTracks(rest.first) }
        // Read straight from the container. This process has never run a sync
        // pass, so `CloudSyncHost.shared.devices` is empty here and a command
        // that trusted it would answer "nobody holds anything" every time.
        let devices = await CloudSyncHost.roster()
        if let id = rest.first { one(id, build: build, devices: devices) }
        all(devices)
    }

    private static var library: ListenKit.Library { ListenKit.Library.mac() }

    /// The whole library: what this Mac holds, and what nothing is keeping.
    private static func all(_ devices: [CloudRecords.DeviceBlob]) -> Never {
        let recordings = Recording.all()
        let held = recordings.filter(\.hasAudio)
        let bytes = held.reduce(Int64(0)) { $0 + size(of: $1) }
        print("this Mac: audio for \(held.count) of \(recordings.count) recordings, "
              + ModelChoice.humanBytes(bytes))
        print("keep audio: \(Settings.keepAudio ? "on" : "off")")

        let masters = held.filter {
            FileManager.default.fileExists(atPath: $0.masterURL.path)
        }
        print("masters here: \(masters.count)")

        // The devices, and what each says it is keeping. This is the whole
        // answer to "may anything be freed", and it is the list the reclaim
        // rule reads rather than a second opinion about it.
        if devices.isEmpty {
            print("\nNo other devices. iCloud sync is off for this library, or "
                  + "nothing has checked in yet.")
        } else {
            print("\ndevices:")
            for device in devices {
                var row = "  \(device.name) (\(device.kind)), \(device.seenAgo)"
                if let holds = device.holdsAudio {
                    row += device.keeps ? ", keeps audio, holds \(holds.count)"
                                        : ", frees audio, holds \(holds.count)"
                } else {
                    row += ", says nothing about audio (older build)"
                }
                print(row)
            }
            let unheld = CloudSyncHost.unheld(among: devices)
            if !unheld.isEmpty {
                print("\n\(unheld.count) recording(s) that no device reports keeping:")
                for recording in unheld.prefix(20) {
                    print("  \(recording.id)  \(recording.displayTitle)")
                }
                if unheld.count > 20 { print("  … and \(unheld.count - 20) more") }
            }
        }
        exit(0)
    }

    /// One recording, and optionally the master built for it now.
    private static func one(_ id: String, build: Bool,
                            devices: [CloudRecords.DeviceBlob]) -> Never {
        guard let recording = Recording.find(id) else {
            FileHandle.standardError.write(Data("no recording \(id)\n".utf8))
            exit(1)
        }
        print("recording: \(recording.id)  \(recording.displayTitle)")
        let files = recording.audioFiles
        if files.isEmpty {
            print("  on this Mac: no audio")
        } else {
            for url in files {
                print("  \(url.lastPathComponent): "
                      + ModelChoice.humanBytes(fileSize(url)))
            }
        }

        for device in CloudSyncHost.audioHolders(of: recording.id, among: devices) {
            print("  also on: \(device.name) (\(device.kind)), \(device.seenAgo)")
        }

        if build {
            guard recording.hasTracks || recording.hasMixdownOnly else {
                print("\nNothing to build from: this Mac has no audio for it.")
                exit(0)
            }
            // Removed first, so `--build` measures a build rather than
            // reporting the one that is already there: `AudioMaster.make`
            // returns an existing master untouched, on purpose.
            for name in AudioMaster.filenames {
                try? FileManager.default.removeItem(
                    at: recording.folder.appendingPathComponent(name))
            }
            let began = Date()
            do {
                guard let built = try AudioMaster.make(micURL: recording.micURL,
                                                       systemURL: recording.systemURL,
                                                       mixURL: recording.mixURL,
                                                       into: recording.folder) else {
                    print("\nNo master was made.")
                    exit(1)
                }
                let took = Date().timeIntervalSince(began)
                let from = built.layout == .everyone ? [recording.mixURL] : recording.tracks
                let source = from.reduce(Int64(0)) { $0 + fileSize($1) }
                let master = fileSize(built.url)
                print("\nbuilt \(built.url.lastPathComponent) in "
                      + "\(String(format: "%.1f", took))s")
                print("  source: \(ModelChoice.humanBytes(source)) "
                      + "(\(built.layout == .everyone ? "the mixdown" : "the tracks"))")
                print("  master: \(ModelChoice.humanBytes(master)), "
                      + "\(built.channels) channel, \(built.layout.rawValue)"
                      + " (\(percent(master, of: source)) of the source)")
            } catch {
                print("\ncould not build a master: \(error.localizedDescription)")
                exit(1)
            }
        }
        exit(0)
    }

    /// `listen audio --check [<id>]`: did the far-end track actually record?
    ///
    /// This exists because on 2026-09-01 the answer was no for three meetings
    /// in a row and nothing on the Mac said so. A duration check passes, a file
    /// size check passes, and the recording screen drew a flat strip that is
    /// indistinguishable from a colleague who is listening. `TapHealth` asks the
    /// one question that separates a dead tap from a quiet room, and this is
    /// where a person can ask it without opening anything.
    ///
    /// With no id it walks the recent recordings, because the useful question
    /// after a bad week is "which of these lost audio", not "did this one".
    private static func checkTracks(_ id: String?) -> Never {
        var recordings: [Recording]
        if let id {
            guard let one = Recording.find(id) else {
                FileHandle.standardError.write(Data("no recording \(id)\n".utf8))
                exit(1)
            }
            recordings = [one]
        } else {
            recordings = Array(Recording.all().filter(\.hasTracks).prefix(10))
        }
        guard !recordings.isEmpty else {
            print("no recordings with audio on this Mac")
            exit(0)
        }

        var damaged = 0
        for recording in recordings {
            print("\(recording.id)  \(recording.displayTitle)")
            guard let track = TapHealth.readFloatTrack(recording.systemURL) else {
                print("  no system track on this Mac")
                continue
            }
            // The microphone track is what turns a long silence into a verdict.
            // Without it the head of every recording reads as a failure, which
            // it is not: measured across the library, both benign silences over
            // 45 seconds are lead-ins nobody spoke through.
            let mic = TapHealth.readFloatTrack(recording.micURL)?.samples
            let report = TapHealth.report(track: track.samples,
                                          sampleRate: track.sampleRate, against: mic)
            let arrived = report.signalSeconds
            print(String(format: "  far end: %.0fs of audio in %.0fs", arrived, report.seconds))
            if report.counts.torn > 0 {
                print(String(format: "  torn:    %.1fs across %d windows, %.1f%% of what arrived",
                             report.tornSeconds, report.counts.torn,
                             report.counts.tornShare * 100))
            }
            for run in report.deadRuns {
                let lost = run.speech >= TapHealth.deadSpeechSeconds
                print(String(format: "  %@ %d:%02d for %.0fs, you spoke %.0fs of it",
                             lost ? "dead:   " : "quiet:  ",
                             Int(run.at) / 60, Int(run.at) % 60, run.seconds, run.speech))
            }
            switch report.verdict {
            case .intact:
                print("  looks intact")
            case .minor:
                // Worth printing and not worth alarming anybody about. A tenth
                // of a percent is two hundred milliseconds in five minutes: it
                // says the route is not perfect, not that the meeting is gone.
                print("  a few gaps, too small to cost you words. "
                      + "Usually the output route rather than a fault.")
            case .lost:
                damaged += 1
                // Named rather than described, because the next question is
                // always "is this the known one".
                print("  the far-end track lost audio. See TapHealth and "
                      + ".agents/notes/capture.md")
            }
        }
        // A non-zero status so this can gate something later without parsing
        // the text, which is the shape `listen sync --fake` already uses.
        exit(damaged == 0 ? 0 : 2)
    }

    private static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "?" }
        return String(format: "%.0f%%", Double(part) / Double(whole) * 100)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
    }

    private static func size(of recording: Recording) -> Int64 {
        recording.audioFiles.reduce(0) { $0 + fileSize($1) }
    }
}
