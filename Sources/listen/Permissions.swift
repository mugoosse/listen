import AVFoundation
import AppKit
import CoreAudio
import EventKit

/// The permissions Listen needs, and how to ask for them.
///
/// To record, Listen needs the microphone and nothing else. That is the point
/// of using a Core Audio process tap for system audio rather than
/// ScreenCaptureKit: **the tap asks for audio capture, not screen recording**.
/// Asking someone to hand over their screen so an app can hear a meeting is a
/// far larger request than the feature needs, and on a managed Mac it is often
/// simply refused.
///
/// The calendar is the odd one out and stays that way deliberately. It buys a
/// name for the recording and a list of who was invited, and Listen records,
/// transcribes and labels perfectly well without it, so it is never part of
/// `allGranted` and nothing blocks on it.
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

    /// Deliberately excludes the calendar. Onboarding and the recording path
    /// both gate on this, and a recorder that refuses to record because it
    /// cannot read your diary would be trading the feature for the garnish.
    static var allGranted: Bool { microphone && (!systemAudioSupported || systemAudio) }

    // MARK: - Calendar

    /// Whether the calendar can be read.
    ///
    /// `.fullAccess` and nothing else. macOS 14 split the old single grant into
    /// full and write-only, and write-only returns an **empty** event list
    /// rather than an error, which on screen is indistinguishable from a Mac
    /// with no calendars on it. `.authorized` is the pre-14 case and cannot
    /// occur here: `LSMinimumSystemVersion` is 14.0.
    static var calendar: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var calendarDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted || status == .writeOnly
    }

    /// Whether this process has already put the calendar dialog on screen.
    ///
    /// A dialog that is dismissed rather than answered records **nothing**, so
    /// the status stays `notDetermined`, which is exactly the state a button
    /// reading "Allow calendar access" is offered from. Without this flag that
    /// button goes on offering a prompt that may not come back, and a button
    /// that does nothing is the worst thing on a permissions screen.
    ///
    /// Deliberately conservative rather than precise: routing to System
    /// Settings always works, so being wrong here costs an extra click, while
    /// the other way round costs a dead button. It is **not** a claim about how
    /// often macOS is willing to prompt. The first version of this comment made
    /// that claim, from a diagnosis that turned out to be wrong: the real cause
    /// of the missing dialog was the Hardened Runtime refusing the request for
    /// want of `com.apple.security.personal-information.calendars`, which is
    /// now in `Listen.entitlements`.
    private(set) static var calendarAsked = false

    /// What the calendar button can usefully do right now.
    ///
    /// One derivation, because onboarding and the Settings pane both draw this
    /// button and a second copy of the rule is a second thing to keep true.
    enum CalendarAction { case granted, canAsk, settingsOnly }

    static var calendarAction: CalendarAction {
        if calendar { return .granted }
        // `calendarDenied` catches a refusal recorded in an earlier launch;
        // `calendarAsked` catches one dismissed in this one, which records
        // nothing at all.
        if calendarDenied || calendarAsked { return .settingsOnly }
        return .canAsk
    }

    /// Ask for calendar access.
    ///
    /// Uses `MeetingCalendar.store` rather than a fresh `EKEventStore`. The
    /// store this grant lands on has to be the one that later reads events: a
    /// store created before the grant keeps answering from the access it was
    /// born with, so reading through a second one returns nothing and looks
    /// like an empty calendar.
    /// The answer arrives on the main actor, which is stated in the type rather
    /// than left to a `DispatchQueue.main.async` inside. EventKit calls back on
    /// an arbitrary queue and every caller here is a view that has to redraw.
    static func requestCalendar(_ done: @escaping @MainActor (Bool) -> Void) {
        // Set before the call and never cleared. The dialog is spent from this
        // moment whatever happens next, including the case where the user
        // dismisses it and the completion below never runs at all.
        calendarAsked = true
        MeetingCalendar.store.requestFullAccessToEvents { granted, error in
            if let error { log("calendar access failed: \(error.localizedDescription)") }
            Task { @MainActor in done(granted) }
        }
    }

    static func openMicrophoneSettings() {
        openPane("com.apple.preference.security?Privacy_Microphone")
    }

    /// System audio has no pane of its own; it is granted with the microphone.
    static func openSystemAudioSettings() { openMicrophoneSettings() }

    static func openCalendarSettings() {
        openPane("com.apple.preference.security?Privacy_Calendars")
    }

    private static func openPane(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:" + path) {
            NSWorkspace.shared.open(url)
        }
    }
}
