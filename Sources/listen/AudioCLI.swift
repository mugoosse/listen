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
        rest.removeAll { $0.hasPrefix("--") }
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
            guard recording.hasTracks else {
                print("\nNothing to build from: this Mac has no separate tracks.")
                exit(0)
            }
            // Removed first, so `--build` measures a build rather than
            // reporting the one that is already there: `AudioMaster.make`
            // returns an existing master untouched, on purpose.
            try? FileManager.default.removeItem(at: recording.masterURL)
            let began = Date()
            do {
                guard let url = try AudioMaster.make(micURL: recording.micURL,
                                                     systemURL: recording.systemURL,
                                                     into: recording.folder) else {
                    print("\nNo master was made.")
                    exit(1)
                }
                let took = Date().timeIntervalSince(began)
                let tracks = recording.tracks.reduce(Int64(0)) { $0 + fileSize($1) }
                let master = fileSize(url)
                print("\nbuilt \(url.lastPathComponent) in \(String(format: "%.1f", took))s")
                print("  tracks: \(ModelChoice.humanBytes(tracks))")
                print("  master: \(ModelChoice.humanBytes(master)), "
                      + "\(AudioMaster.channels(in: url)) channel"
                      + " (\(percent(master, of: tracks)) of the tracks)")
            } catch {
                print("\ncould not build a master: \(error.localizedDescription)")
                exit(1)
            }
        }
        exit(0)
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
