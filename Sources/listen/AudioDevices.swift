import AVFoundation
import CoreAudio

struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
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

    /// True when a specific device was chosen but is not currently present.
    static var microphoneMissing: Bool {
        guard let uid = microphoneUID else { return false }
        return AudioDevices.find(uid: uid) == nil
    }
}
