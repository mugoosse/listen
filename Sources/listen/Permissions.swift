import AVFoundation
import AppKit
import CoreAudio

/// The two permissions Listen needs, and how to ask for them.
///
/// Listen needs the microphone and nothing else. That is the point of using a
/// Core Audio process tap for system audio rather than ScreenCaptureKit:
/// **the tap asks for audio capture, not screen recording**. Asking someone to
/// hand over their screen so an app can hear a meeting is a far larger request
/// than the feature needs, and on a managed Mac it is often simply refused.
enum Permissions {
    static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    static func requestMicrophone(_ done: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Whether a process tap can actually be created.
    ///
    /// Checked by creating one and destroying it, because there is no TCC API
    /// that answers this question. The tap shares the microphone's permission
    /// but is refused for its own reasons too, and the status code for "not
    /// permitted" is indistinguishable from any other failure, so the only
    /// honest check is to try.
    ///
    /// Cheap: creating and destroying a private tap costs microseconds and is
    /// invisible to other apps.
    static var systemAudio: Bool {
        guard #available(macOS 14.2, *) else { return false }
        let description = CATapDescription()
        description.name = "Listen permission check"
        description.processes = []
        description.isExclusive = true
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = true

        var id = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &id) == noErr,
              id != kAudioObjectUnknown else { return false }
        AudioHardwareDestroyProcessTap(id)
        return true
    }

    /// True where process taps exist at all. On 14.0 and 14.1 the mic track
    /// still records, so this is a reduced feature rather than a broken app.
    static var systemAudioSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    static var allGranted: Bool { microphone && (!systemAudioSupported || systemAudio) }

    static func openMicrophoneSettings() {
        openPane("com.apple.preference.security?Privacy_Microphone")
    }

    /// System audio has no pane of its own; it is granted with the microphone.
    static func openSystemAudioSettings() { openMicrophoneSettings() }

    private static func openPane(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:" + path) {
            NSWorkspace.shared.open(url)
        }
    }
}
