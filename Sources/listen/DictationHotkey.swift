import AppKit
import Carbon.HIToolbox

/// The global chord that starts and stops a dictation.
///
/// Ported from Speak's `App.installHotkey` and the two handlers beside it. Every
/// choice in here is one Speak paid for; the notes are kept with the code
/// because the obvious implementation of each is wrong.
///
/// Listen has no other global key handling. Everything else it watches is a
/// local monitor or a menu key equivalent, both of which only see events while
/// Listen is frontmost, and the whole point of dictation is that it is not.
@MainActor
final class DictationHotkey {
    private var tap: CFMachPort?
    private var comboLatched = false
    private var accessibilityWatch: Timer?

    /// True once the tap is live, so setup can arm it the moment Accessibility
    /// is granted rather than waiting until the flow finishes.
    var isInstalled: Bool { tap != nil }

    /// The chord fired.
    var onToggle: (() -> Void)?

    /// Escape was pressed. Return true to swallow it, which the owner does only
    /// while a dictation is running: at any other time Escape is none of our
    /// business and eating it would break every dialog on the Mac.
    var onEscape: (() -> Bool)?

    /// Set while Settings is capturing a replacement chord, so the chord being
    /// recorded does not also toggle dictation.
    var recorder: ((CGEventFlags, Int?) -> Void)?

    /// Arm the tap, if Accessibility has been granted and it is not already up.
    @discardableResult
    func installIfPermitted() -> Bool {
        guard tap == nil else { return true }
        guard Permissions.accessibility else { return false }
        return install()
    }

    func uninstall() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
        comboLatched = false
        trace("dictation hotkey disarmed")
    }

    /// Watch for Accessibility being granted and arm the tap the moment it is.
    ///
    /// macOS sends no notification when a TCC grant changes, and the grant is
    /// made in System Settings, in another app, minutes after we asked. Without
    /// polling, Listen sits there with no tap and the shortcut does nothing
    /// until the user thinks to relaunch, which reads as the feature being
    /// broken. Stops as soon as it succeeds, or after a minute, because a
    /// permanent timer for a one-time event is waste.
    func watchForAccessibility(seconds: TimeInterval = 60) {
        guard tap == nil else { return }
        accessibilityWatch?.invalidate()
        let deadline = Date().addingTimeInterval(seconds)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            // Synchronously, not `Task { @MainActor in }`. A timer added to
            // RunLoop.main already fires on the main thread, and the hop would
            // re-enter through the main dispatch queue, which does not drain
            // while a menu is open. See the same trap in `Capture`'s levels.
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                if self.tap != nil || Date() > deadline {
                    t.invalidate(); self.accessibilityWatch = nil; return
                }
                if self.installIfPermitted() {
                    t.invalidate(); self.accessibilityWatch = nil
                }
            }
        }
        // `.common`, so it keeps ticking while a menu is open. Somebody who has
        // just granted the permission is quite likely to be looking at the menu
        // to see whether it took.
        RunLoop.main.add(timer, forMode: .common)
        accessibilityWatch = timer
    }

    /// Modifier-only chords never arrive as keyDown, so we watch flagsChanged.
    ///
    /// This uses a `CGEventTap` rather than an `NSEvent` global monitor because
    /// on Apple Silicon the Globe/fn key is swallowed by the system before it
    /// reaches NSEvent: a global monitor sees the shift half of the chord and
    /// never the fn half. The tap sits lower down and reports fn as
    /// `.maskSecondaryFn`.
    private func install() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()

        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Not listenOnly: when the shortcut includes a character key, that
            // keystroke has to be swallowed, or pressing fn+⇧+P would toggle
            // dictation *and* type a P into whatever is focused. Everything
            // that does not match is passed straight through.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                guard let ctx else { return Unmanaged.passUnretained(event) }
                let hotkey = Unmanaged<DictationHotkey>.fromOpaque(ctx).takeUnretainedValue()

                // macOS disables a tap that ever runs long. Re-arm rather than
                // dying silently, which is what an unhandled one does: the
                // shortcut simply stops working, with nothing logged.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { hotkey.reenable() }
                    return Unmanaged.passUnretained(event)
                }

                // The tap runs on the main run loop, so this is already the
                // main thread and can be handled synchronously. That matters:
                // deciding whether to swallow the event has to happen before
                // returning, and it keeps events strictly in order.
                var swallow = false
                MainActor.assumeIsolated {
                    if type == .keyDown {
                        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                        swallow = hotkey.handleKeyDown(code, event.flags)
                    } else {
                        hotkey.handleFlags(event.flags)
                    }
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: me
        ) else {
            log("event tap refused; check Accessibility")
            return false
        }

        tap = created
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        log("dictation hotkey armed (CGEventTap)")
        return true
    }

    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        log("event tap re-enabled")
    }

    func handleFlags(_ flags: CGEventFlags) {
        if DEBUG {
            log(String(format: "raw=0x%09llx held=%@", flags.rawValue,
                       Modifier.describe(flags.rawValue & Modifier.tracked)))
        }

        if let record = recorder {
            record(flags, nil)
            return
        }

        // A chord that includes a character key is decided in handleKeyDown;
        // flag changes alone must not fire it.
        guard !DictationShortcut.usesCharacterKey else { return }

        if DictationShortcut.modifiersMatch(flags) {
            if !comboLatched { comboLatched = true; onToggle?() }
        } else {
            comboLatched = false        // require a fresh press to re-fire
        }
    }

    /// Returns true when the event should be swallowed.
    func handleKeyDown(_ code: Int, _ flags: CGEventFlags) -> Bool {
        if DEBUG {
            log("keyDown code=\(code) (\(KeyName.of(code))) held="
                + Modifier.describe(flags.rawValue & Modifier.tracked))
        }

        if let record = recorder {
            record(flags, code)
            return true          // never let a chord being recorded reach an app
        }

        // Escape abandons a dictation, and the keystroke is swallowed then so it
        // does not also dismiss whatever is in front. The owner decides, because
        // only it knows whether anything is running.
        if code == kVK_Escape, onEscape?() == true { return true }

        guard DictationShortcut.usesCharacterKey,
              DictationShortcut.keyCode == code,
              DictationShortcut.modifiersMatch(flags) else { return false }

        onToggle?()
        return true
    }
}
