import AppKit
import Carbon.HIToolbox
import IOKit

/// Whether some app has secure input turned on, and which one.
///
/// Secure input exists to keep keyloggers away from the keyboard, and at the
/// layer it works on, `DictationHotkey`'s chord detection is a keylogger. While
/// it is on, the event tap is not handed ordinary key events. Modifier changes
/// can still arrive on some paths, so a modifier-only chord may start a
/// dictation while Escape never reaches the tap to cancel it.
///
/// Terminal's Secure Keyboard Entry is the deliberate case, and it stays on
/// until someone unticks it. The accidental case is an app that turns it on for
/// a password field and does not turn it off again, where it outlives the window
/// that wanted it and the user is left with a shortcut that stopped working for
/// no reason they can see.
///
/// Every other way a dictation can fail already says so in the menu: the
/// microphone gets a row and a retry hint, a model that will not load gets a row
/// and a Try again. This is the only failure that can remove some or all
/// keyboard control without telling Listen that anything changed.
///
/// Measured in Speak, with a tap of the same shape and a synthesized F13: seen
/// once with secure input off, and not at all with it on. Do not try to recover
/// Escape by polling `CGEventSource.keyState` or through an `IOHIDManager`. Both
/// reported no physical Escape while secure input was held. The pill's Cancel
/// button is the fallback, because mouse events are unaffected, and that is why
/// the panel stays nonactivating: using it must not move keyboard focus.
enum SecureInput {
    /// Cheap enough for `menuWillOpen`, which is the only thing that asks.
    ///
    /// Deliberately not polled. Secure input goes on for a second or two every
    /// time anybody types a password anywhere, so something watching it
    /// continuously would spend most of its life crying wolf, and the menu bar
    /// icon would flicker into a warning while the user was doing nothing more
    /// alarming than logging in. Asked at the moment somebody opens the menu,
    /// the answer is only ever given to a person who came looking for it.
    static var isOn: Bool { IsSecureEventInputEnabled() }

    /// The name of the app holding it, when it can be found.
    ///
    /// `nil` is an ordinary answer, not an error: the pid is not published as
    /// API and the process may be one with no application name to give. The menu
    /// says "Another app" in that case, which is still the useful half of the
    /// message, because the point is that this is not Listen being broken.
    ///
    /// The pid is the *responsible* application's, not the caller's. Measured: a
    /// bare command-line binary that calls `EnableSecureEventInput` is published
    /// under the pid of the terminal it was run from, not its own. That is the
    /// answer worth having. The user needs the app they can see and quit, not a
    /// helper process they have no way to find.
    static func holder() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        // The window server publishes the console session dictionaries into the
        // IO registry, and the pid holding secure input is one of their keys.
        // There is no public call that returns it, so it is read from where it
        // is already written rather than guessed at.
        guard let property = IORegistryEntrySearchCFProperty(
            root, kIOServicePlane, "IOConsoleUsers" as CFString,
            kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))
        else { return nil }

        guard let sessions = property as? [[String: Any]] else { return nil }
        for session in sessions {
            guard let pid = session["kCGSSessionSecureInputPID"] as? pid_t,
                  pid != 0 else { continue }
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                // A pid that will not resolve is a process without an
                // application to name, a helper or a daemon. Naming its pid
                // would be worse than not naming it: a number nobody can act on
                // reads as a fault in Listen.
                return nil
            }
            return app.localizedName ?? app.bundleIdentifier
        }
        return nil
    }
}
