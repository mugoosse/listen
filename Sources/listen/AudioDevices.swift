import AVFoundation
import CoreAudio
import IOKit

struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Which microphone a recording should use, and what it had to work around.
///
/// `rejected` is the reason the obvious device was not the one chosen, phrased
/// for somebody reading the recording panel. It is never dropped on the floor:
/// moving somebody's microphone without saying so is the same class of mistake
/// as recording silence without saying so.
struct MicChoice {
    let device: AudioDevice
    let rejected: String?
}

/// Enumerates input devices and resolves saved ones.
///
/// Devices are stored by UID rather than by `AudioDeviceID`, because the
/// numeric ID is assigned at connect time: unplug a USB mic and plug it back
/// in and it is a different number, while the UID is stable.
enum AudioDevices {
    static func inputs() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? "Unknown"
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func defaultInput() -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
            id != 0
        else { return nil }

        return inputs().first { $0.id == id }
    }

    static func find(uid: String) -> AudioDevice? {
        inputs().first { $0.uid == uid }
    }

    // -----------------------------------------------------------------------
    // Which of them can actually record

    /// Whether the laptop's lid is shut.
    ///
    /// This is the fault that cost somebody an hour of their own voice, and it
    /// is invisible from every property a recorder would think to ask. With the
    /// lid closed onto an external display, macOS keeps
    /// `BuiltInMicrophoneDevice` in the device list, keeps it as the **system
    /// default input**, and reports it alive, unmuted and at its usual 48 kHz
    /// mono format. Measured on the recording that prompted this: `alive = 1`,
    /// `mute = 0`, volume `0.27`, and 56,239,952 samples of which not one was
    /// nonzero.
    ///
    /// So not one of `MicRecorder.watchHardware`'s listeners fires and the stall
    /// watchdog sees a file growing perfectly. The lid is the only thing that
    /// tells you, and it has to come from the IO registry because Core Audio has
    /// no property for it.
    ///
    /// Read fresh every time rather than cached. It is one registry lookup, it
    /// happens a handful of times per recording, and the answer changes under
    /// you: caching it at launch would keep a Mac that was opened mid-meeting
    /// off its own microphone for the rest of the call.
    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(
            root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        // Absent on a desktop, which is not a closed lid.
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    /// How this device is attached, as a `kAudioDeviceTransportType…` code.
    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return UInt32(kAudioDeviceTransportTypeUnknown) }
        return value
    }

    private static let wiredTransports: Set<UInt32> = [
        UInt32(kAudioDeviceTransportTypeUSB),
        UInt32(kAudioDeviceTransportTypeThunderbolt),
        UInt32(kAudioDeviceTransportTypeFireWire),
        UInt32(kAudioDeviceTransportTypePCI),
    ]

    private static let wirelessTransports: Set<UInt32> = [
        UInt32(kAudioDeviceTransportTypeBluetooth),
        UInt32(kAudioDeviceTransportTypeBluetoothLE),
    ]

    /// How willing Listen is to move a running recording onto this device on its
    /// own. Lower is better, and `nil` means never without being asked.
    ///
    /// The filter is the dangerous half of automatic recovery, because the list
    /// of inputs on a working Mac is full of things that are not microphones.
    /// Measured on the machine this was written for: "Microsoft Teams Audio" is
    /// a virtual loopback input, present, alive, and every bit as silent as a
    /// closed lid. Switching onto it would have replaced one hour of nothing
    /// with another and reported success.
    ///
    /// Continuity Capture (an iPhone within reach) is deliberately excluded too.
    /// It is a real microphone and it works, but reaching across to somebody's
    /// phone unasked is a surprise, and a surprise is the thing this whole
    /// change exists to remove. It stays pickable by hand in Settings.
    private static func rank(_ device: AudioDevice) -> Int? {
        let kind = transport(device.id)
        if wiredTransports.contains(kind) { return 0 }
        if wirelessTransports.contains(kind) { return 1 }
        if kind == UInt32(kAudioDeviceTransportTypeBuiltIn) { return lidClosed ? nil : 2 }
        return nil
    }

    /// Whether this device can be recorded from at all right now.
    static func isUsable(_ device: AudioDevice) -> Bool { rank(device) != nil }

    /// The Mac's own microphone, as opposed to anything plugged in or paired.
    ///
    /// Asked so a warning can name the right cause. "Off while the lid is shut"
    /// is only true of this one, and saying it about a USB microphone that went
    /// away sends somebody to open a lid that was never the problem.
    static func isBuiltIn(_ device: AudioDevice) -> Bool {
        transport(device.id) == UInt32(kAudioDeviceTransportTypeBuiltIn)
    }

    /// Inputs Listen is willing to record from unattended, best first.
    ///
    /// The system default leads whenever it qualifies, and that is not merely
    /// politeness. macOS moves the default input onto a headset when a call
    /// starts, so honouring it is what keeps automatic recovery from preferring
    /// the desk microphone somebody is not talking into.
    static func candidates(excluding: Set<String> = []) -> [AudioDevice] {
        let preferred = defaultInput()?.uid
        return inputs()
            .filter { !excluding.contains($0.uid) }
            .compactMap { device -> (AudioDevice, Int)? in
                guard let rank = rank(device) else { return nil }
                return (device, device.uid == preferred ? -1 : rank)
            }
            // `sorted(by:)` is not stable, so equal ranks fall back to the name
            // rather than shuffling between two runs of the same recording.
            .sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }
            .map(\.0)
    }

    /// True when the device exposes at least one input channel. Most output
    /// devices also appear in the device list, so this is what separates them.
    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr
        else { return false }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID,
                               _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        // Unmanaged, not a bare CFString: CoreAudio writes a +1 retained
        // reference here, and taking a raw pointer to a managed CFString var
        // is unsound (the compiler warns about it) as well as leaking.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        return value.takeRetainedValue() as String
    }
}

extension Settings {
    private static let micKey = "microphoneUID"

    /// nil means follow the system default input, which is what most people
    /// want: change it in Sound settings and Listen follows.
    static var microphoneUID: String? {
        get {
            // `Settings.defaults`, not `UserDefaults.standard`: `listen record`
            // has to read the same microphone the window chose, and through the
            // installed symlink the standard domain is not the app's.
            let v = defaults.string(forKey: micKey)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set { defaults.set(newValue ?? "", forKey: micKey) }
    }

    /// The device to record from, falling back to the system default when the
    /// saved one has been unplugged.
    static var resolvedMicrophone: AudioDevice? {
        if let uid = microphoneUID, let d = AudioDevices.find(uid: uid) { return d }
        return AudioDevices.defaultInput()
    }

    /// The device to record from, refusing the ones that cannot record, and
    /// saying what it refused.
    ///
    /// `excluding` is how the caller reports a device it has already watched
    /// deliver nothing, so a second attempt does not resolve straight back onto
    /// it. See `MicRecorder.silentGrace`.
    ///
    /// The choice in Settings is honoured wherever honouring it records
    /// something, and this is the one place it is overridden. That looks like a
    /// contradiction of `watchHardware`'s rule that "somebody who picked a
    /// specific microphone meant it", and it is not: that rule is about not
    /// moving somebody off a *working* device because macOS changed its mind. A
    /// device that cannot record is not a preference, it is a fault, and
    /// honouring it to the letter means handing back an hour of silence with the
    /// user's own setting as the excuse.
    static func chooseMicrophone(excluding: Set<String> = []) -> MicChoice? {
        let chosen = microphoneUID.flatMap(AudioDevices.find(uid:))
        if let chosen, !excluding.contains(chosen.uid), AudioDevices.isUsable(chosen) {
            return MicChoice(device: chosen, rejected: nil)
        }
        let fallbacks = AudioDevices.candidates(excluding: excluding)

        // Why the obvious device is not the one being used. Ordered by how much
        // the user needs to hear it: a shut lid is the one they can undo in a
        // second, and the one nothing else on the machine will tell them about.
        let reason: String?
        if let chosen {
            reason = excluding.contains(chosen.uid)
                ? "\(chosen.name) is not picking anything up"
                : (AudioDevices.lidClosed
                    ? "the built-in microphone is off while the lid is shut"
                    : "\(chosen.name) cannot be recorded from")
        } else if microphoneUID != nil {
            reason = "the microphone you chose is not connected"
        } else if let current = AudioDevices.defaultInput(),
                  excluding.contains(current.uid) || !AudioDevices.isUsable(current) {
            reason = excluding.contains(current.uid)
                ? "\(current.name) is not picking anything up"
                : "the built-in microphone is off while the lid is shut"
        } else {
            reason = nil
        }

        guard let device = fallbacks.first else { return nil }
        return MicChoice(device: device, rejected: reason)
    }

    /// True when a specific device was chosen but is not currently present.
    static var microphoneMissing: Bool {
        guard let uid = microphoneUID else { return false }
        return AudioDevices.find(uid: uid) == nil
    }
}
