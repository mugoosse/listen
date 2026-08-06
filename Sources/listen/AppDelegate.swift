import AppKit

/// The app itself: menu bar, capture control, and the confirm step.
@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem?
    private let indicator = RecordingIndicator()

    /// The app whose call started the recording that is running now, while the
    /// "are you in a meeting?" question is still unanswered. Nil for a manual
    /// recording, and nil again the moment it is answered.
    private var awaitingAnswer: String?
    /// Set for a recording detection started, so the detector only ends what it
    /// began. Somebody who pressed Record meant it, and a call ending is not a
    /// reason to stop a recording they asked for.
    private var startedByDetection = false

    func applicationDidFinishLaunching(_ note: Notification) {
        trace("launched, build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")

        // Installed first so a preview launch has a Cmd-Q, and unchanged for a
        // real one: `QuitConfirm` still goes on top of it below.
        MainMenu.install()
        // A preview launch is for looking at a panel and nothing else, and it
        // has to be safe to start beside the app that is already running.
        // Everything below this line writes to the library: adopting staged
        // recordings, sweeping staging, and a queue that would start
        // transcribing the same audio the other process is already working on.
        // So a preview does none of it and stops here.
        if previewPanelIfAsked() { return }

        try? Library.prepare()

        // Adopt before sweeping, not after. The sweep deletes staged
        // recordings older than 24 hours, and now that nothing is ever left
        // waiting on an answer, a staged recording is not one somebody declined
        // to keep: it is one a crash or a quit interrupted. Sweeping first
        // would delete exactly the recording this is meant to rescue.
        adoptStaged()

        // Still swept, as a net under anything adoption could not promote.
        Library.sweepStaging()

        // And then Cmd-Q asks before it quits. Installed after the menu on
        // purpose: it intercepts the keystroke ahead of the Quit item rather
        // than replacing it, so the menu has to exist first for there to be
        // anything to intercept.
        QuitConfirm.shared.install()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.ready.image
        item.button?.toolTip = "Listen"
        // One menu for the life of the process, refilled in place. Handing the
        // status item a *new* `NSMenu` from `menuWillOpen` would swap the menu
        // out from under the one being displayed.
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        status = item
        rebuildMenu()

        Capture.shared.onChange = { [weak self] in self?.rebuildMenu() }

        let detector = MeetingDetector.shared
        detector.onMeetingStarted = { [weak self] in self?.meetingStarted($0) }
        detector.onMeetingEnded = { [weak self] in self?.meetingEnded() }
        // A recording started by hand before the call was joined has no app on
        // it. `noteApp` writes the first one seen and ignores every poll after.
        detector.onCallersSeen = { if let first = $0.first { Capture.shared.noteApp(first) } }
        indicator.onYes = { [weak self] in self?.answerMeeting(.yes) }
        indicator.onNo = { [weak self] in self?.answerMeeting(.no) }
        indicator.onNeverFor = { [weak self] in self?.answerMeeting(.never) }
        indicator.onStop = { [weak self] in self?.stopRecording() }
        detector.refresh()

        // Anything with audio and no transcript is pending, so the queue is
        // rebuilt from the file system rather than from saved state. A job
        // interrupted by a quit costs one re-run, not a stuck row.
        Queue.shared.resume()

        // Open at login, on by default, for new installations only.
        //
        // Straight from Speak, and the argument is stronger here. Speak is a
        // menu bar utility you reach for; Listen watches for meetings, and
        // `MeetingDetector` only polls while the app is running. Off by
        // default means somebody who never finds the checkbox has a recorder
        // that misses every call and says nothing about why, which is the same
        // silent-failure shape the detection default already avoids.
        //
        // Read before the branch below, because finishing onboarding sets
        // `Settings.onboarded` and this has to see the value from launch.
        // `applyDefaultIfNeeded` records that it ran either way, so a later
        // launch never overrides a choice made here or in System Settings.
        LoginItem.applyDefaultIfNeeded(isNewInstallation: !Settings.onboarded)

        // Setup on a first run, the library otherwise. `isFirstRun` is the
        // absence of the key rather than a false value, so somebody who
        // finished setup and turned everything off is not shown it again.
        if Settings.isFirstRun {
            Onboarding.shared.show()
        } else {
            LibraryWindow.shared.show()
        }
        _ = Updater.shared

    }

    /// Recordings left in staging by a crash or a quit join the library.
    ///
    /// They used to be offered back with a Keep and Discard panel. Nothing asks
    /// any more: a recording that exists is kept, and the way to get rid of one
    /// is Delete in the library, where you can see what you are deleting and
    /// hear it first. Being asked "keep this recording?" about an hour of audio
    /// you have no memory of, at launch, with no way to listen to it before
    /// answering, is a worse question than no question.
    ///
    /// This is SPEC 5.3's own stated fallback, which it describes as "Blackbox's
    /// behaviour, which is to keep everything with a Discard button".
    private func adoptStaged() {
        for orphan in Recording.staged() {
            do {
                _ = try Capture.shared.keep(orphan)
            } catch {
                log("could not adopt \(orphan.id): \(error.localizedDescription)")
            }
        }
    }

    /// `LISTEN_PANEL=detected|recording[:seconds]|settings` shows a state at
    /// launch. True when it did, which is also the signal to launch no further.
    ///
    /// For looking at the thing, and nothing else. The panel's states are
    /// otherwise only reachable by holding a real meeting, so one of them
    /// shipped with its label overlapping a button and stayed that way until
    /// somebody happened to look. A state that cannot be put on screen on
    /// demand is a state nobody checks.
    ///
    /// In the same family as `LISTEN_CHUNK`: a measurement affordance, not a
    /// feature, and not mentioned anywhere a user would read.
    private func previewPanelIfAsked() -> Bool {
        guard let want = ProcessInfo.processInfo.environment["LISTEN_PANEL"] else { return false }
        switch want {
        case "detected":
            // A real, installed bundle identifier, so the icon and the name are
            // the ones a user would see rather than placeholders that hide a
            // sizing bug.
            indicator.show(.detected("com.google.Chrome"))
        case let want where want.hasPrefix("settings"):
            // `settings`, or `settings:developers` for a particular tab.
            let name = want.dropFirst("settings".count).drop { $0 == ":" }
            LibraryWindow.shared.showSettings(
                SettingsTab.allCases.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
                    ?? .general)
        default:
            indicator.show(.recording)
            // `recording:1994` runs the clock at 33:14 rather than 0:00, which
            // is the only value a preview could show before this: the panel is
            // not recording anything.
            //
            // That mattered. Every frame in the panel is measured from the
            // strings it is drawing, and the clock is the only one that changes
            // after `show` has laid it out, so a clock that has only ever been
            // looked at reading "0:00" is a layout nobody has checked. The
            // version that shipped was a character too narrow from ten minutes
            // in, and lost a digit for the rest of the meeting.
            indicator.previewElapsed = Double(want.dropFirst("recording".count)
                                                  .drop { $0 == ":" })
        }
        return true
    }

    // MARK: - Menu

    /// Refill the menu, and follow capture everywhere else it shows.
    ///
    /// Split from `refreshMenu` because opening the menu must not do any of
    /// this: `indicator.show` puts a panel on screen and `recordingChanged`
    /// rebuilds the library window's sidebar and toolbar, and neither is
    /// something clicking the menu bar asked for.
    private func rebuildMenu() {
        refreshMenu()

        let recording = Capture.shared.isRecording
        status?.button?.image = (recording ? MenuBarIcon.recording : .ready).image
        status?.button?.toolTip = recording ? "Listen, recording" : "Listen"
        // The window says so too. The menu bar item is 16 points wide and may
        // be behind the notch, so it cannot be the only place that reports it.
        LibraryWindow.shared.recordingChanged()

        if recording {
            // The unanswered question outranks the plain recording panel.
            // Without this, every menu rebuild, and `Capture.onChange` fires
            // one, would replace the question with "Recording" and there would
            // be no way to answer it.
            if let app = awaitingAnswer {
                indicator.show(.detected(app))
            } else {
                indicator.show(.recording)
            }
        } else {
            indicator.hide()
        }
    }

    /// Kept deliberately thin, the same shape as Speak's. Everything
    /// configurable lives in Settings; the menu is for state, the recordings
    /// worth reaching in one click, and the four things every menu bar app has
    /// at the bottom.
    private func refreshMenu() {
        guard let menu = status?.menu else { return }
        menu.removeAllItems()
        // Every enablement is stated here. Left to AppKit, an item is enabled
        // whenever its target responds to its action, which quietly ignores the
        // one line in this menu that says otherwise: Sparkle disables its own
        // check while one is already running, and `Updater` has no
        // `validateMenuItem` for AppKit to ask. The cost is that the rows which
        // only report something have to say they are not controls, which `info`
        // does.
        menu.autoenablesItems = false

        // Say whose menu this is. Somebody who cannot place an icon in a menu
        // bar of twenty clicks it to find out, and until this row existed the
        // only answer was "About Listen", eight items down past the verbs and
        // the library.
        let name = info("Listen")
        name.image = MenuBarIcon.ready.menuImage
        menu.addItem(name)
        menu.addItem(.separator())

        let recording = Capture.shared.isRecording
        if recording {
            // Right whenever the menu is open, because `menuWillOpen` refills
            // it. `Capture.onChange` fires on the edges of capture and not per
            // second, so a clock drawn once at the start would say "0:00" for
            // the length of the meeting.
            let elapsed = info("Recording, \(Self.clock(Capture.shared.elapsed))")
            elapsed.image = symbol("record.circle")
            menu.addItem(elapsed)
            let stop = NSMenuItem(title: "Stop Recording",
                                  action: #selector(stopRecording), keyEquivalent: "")
            stop.target = self
            stop.image = symbol("stop.circle")
            menu.addItem(stop)
        } else {
            let start = NSMenuItem(title: "Start Recording",
                                   action: #selector(startRecording), keyEquivalent: "")
            start.target = self
            start.image = symbol("record.circle")
            menu.addItem(start)
        }

        // Said here because this is the menu recording starts from, and it is
        // the last moment it costs nothing to know.
        //
        // A missing model never loses a meeting: ASR.load fetches it and the
        // transcript arrives late rather than not at all. But "late" is a
        // 2.5 GB download standing between a finished call and its transcript,
        // discovered afterwards, and the pane that reports it is three clicks
        // away in Settings. Not a dialog: detection starts recordings on its
        // own, and a modal in front of somebody joining a call is worse than
        // the wait it warns about.
        if !Settings.model.isDownloaded {
            menu.addItem(.separator())
            let size = ModelChoice.humanBytes(Settings.model.approxBytes)
            let warn = NSMenuItem(title: "Speech model not downloaded (\(size))",
                                  action: #selector(openModelSettings), keyEquivalent: "")
            warn.target = self
            warn.image = symbol("exclamationmark.triangle")
            menu.addItem(warn)
            let hint = info("Recordings are kept and transcribed once it is")
            hint.image = symbol("arrow.down.circle")
            menu.addItem(hint)
        }

        // The other half of the same argument. A recorder with no microphone
        // permission records silence and says nothing about it, and the pane
        // that fixes it is behind Settings.
        if !Permissions.allGranted {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "Finish setup…",
                                  action: #selector(openPermissions), keyEquivalent: "")
            warn.target = self
            warn.image = symbol("exclamationmark.triangle")
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Listen", action: #selector(openLibrary),
                              keyEquivalent: "o")
        open.target = self
        open.image = symbol("macwindow")
        menu.addItem(open)

        let recordings = Recording.all()
        menu.addItem(info(recordings.count == 1 ? "1 recording"
                                                : "\(recordings.count) recordings"))
        if Queue.shared.isBusy { menu.addItem(info("Transcribing…")) }
        let reveal = NSMenuItem(title: "Reveal Library in Finder",
                                action: #selector(revealLibrary), keyEquivalent: "")
        reveal.target = self
        reveal.image = symbol("folder")
        menu.addItem(reveal)

        // The five most recent, straight to the recording rather than to the
        // library with the user to find it again. Speak's equivalent row copies
        // the dictation, because a dictation *is* its text; a meeting is an
        // hour of audio, a transcript and a set of speakers, so the useful
        // thing to do with one in a menu is open it.
        //
        // The recording in progress is deliberately not here. It is the two
        // rows at the top of this menu, and listing it twice would put the same
        // meeting under two different verbs.
        let recent = recordings.prefix(5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(info("Recent"))
            for recording in recent {
                var title = recording.metadata.title
                    .replacingOccurrences(of: "\n", with: " ")
                if title.count > 52 { title = String(title.prefix(51)) + "…" }
                // A recording whose `recorded_at` will not parse gets its title
                // alone rather than two leading spaces where a stamp should be.
                let stamp = Self.stamp(recording)
                let item = NSMenuItem(title: stamp.isEmpty ? title : "\(stamp)  \(title)",
                                      action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                // The id, not the row number. The menu is rebuilt on every open
                // and a recording can arrive or be deleted between two of them,
                // so an index taken from the menu that was drawn last time names
                // a different meeting by the time it is clicked.
                item.representedObject = recording.id
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                               keyEquivalent: ",")
        prefs.target = self
        prefs.image = symbol("gearshape")
        menu.addItem(prefs)

        let update = NSMenuItem(title: "Check for Updates…",
                                action: #selector(Updater.checkForUpdates(_:)),
                                keyEquivalent: "")
        update.target = Updater.shared
        update.isEnabled = Updater.shared.canCheck
        update.image = symbol("arrow.triangle.2.circlepath")
        menu.addItem(update)

        let about = NSMenuItem(title: "About Listen", action: #selector(openAbout),
                               keyEquivalent: "")
        about.target = self
        about.image = symbol("info.circle")
        menu.addItem(about)

        // Not `NSApplication.terminate`, unlike Speak: capture has to stop
        // cleanly first so the WAV headers are finalised. `QuitConfirm` does not
        // intercept this, deliberately, because reaching for a menu item is
        // already a decision.
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = symbol("power")
        menu.addItem(quitItem)
    }

    /// Right before it is displayed, so the clock, the library count and the
    /// recent list are what they are now rather than what they were the last
    /// time capture changed.
    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    /// A row that reports something rather than doing something.
    ///
    /// Both halves are needed with `autoenablesItems` off: no action so a click
    /// does nothing, and `isEnabled` false so it is drawn as the note it is
    /// instead of highlighting under the pointer like a command.
    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.size = NSSize(width: 15, height: 15)
        image?.isTemplate = true
        return image
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// When a recent recording was made, in one narrow column.
    ///
    /// Speak prints the time and nothing else, which is right there: its history
    /// is the last five things you dictated, all of them minutes old. A library
    /// of meetings is not, and "15:14" on a recording from Tuesday is a lie
    /// nothing on the row corrects, so anything older than today gets its date
    /// instead.
    private static func stamp(_ recording: Recording) -> String {
        guard let date = recording.date else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM"
        return f.string(from: date)
    }

    // MARK: - Capture

    /// Also reachable from the library window's toolbar, so recording does not
    /// require going to the menu bar while reading a transcript.
    @objc func startRecordingFromUI() { startRecording() }
    @objc func stopRecordingFromUI() { stopRecording() }

    @objc private func startRecording() {
        // Pressing Start is not an answer to a question nobody asked.
        awaitingAnswer = nil
        startedByDetection = false
        do {
            _ = try Capture.shared.start()
            if !Capture.shared.warnings.isEmpty {
                // Say which track failed rather than letting someone discover
                // at playback that half the meeting is missing.
                notify("Recording with one track only",
                       Capture.shared.warnings.joined(separator: "\n"))
            }
        } catch {
            notify("Could not start recording", error.localizedDescription)
        }
    }

    @objc private func stopRecording() {
        guard let recording = Capture.shared.stop() else { return }
        finish(recording)
    }

    /// Capture has stopped, so the recording joins the library.
    ///
    /// No question. The only thing that deletes a recording is answering "no"
    /// to "are you in a meeting?", which happens at the start while the answer
    /// is obvious, or Delete in the library later.
    private func finish(_ recording: Recording) {
        awaitingAnswer = nil
        startedByDetection = false
        MeetingDetector.shared.captureEnded()
        resolve(recording, keep: true)
        indicator.hide()
        rebuildMenu()
    }

    // MARK: - Detected meetings

    private enum MeetingAnswer { case yes, no, never }

    /// Something started a call. Record it, then ask.
    private func meetingStarted(_ bundleID: String) {
        // A recording already running wins. Somebody who pressed Start before
        // joining meant it, and restarting would cut the meeting in two.
        guard !Capture.shared.isRecording else { return }
        do {
            // `source` is how the recording was started and `app_bundle_id` is
            // what it is of. They used to be one field, which meant the app was
            // on disk under a name that said provenance, and nothing read it.
            _ = try Capture.shared.start(source: "detected", app: bundleID)
        } catch {
            // Logged, not alerted. A detected meeting is not something the user
            // asked for at this moment, and a modal in front of the call they
            // are joining is worse than the recording it is apologising for.
            log("could not start the detected recording: \(error.localizedDescription)")
            MeetingDetector.shared.captureEnded()
            return
        }
        awaitingAnswer = bundleID
        startedByDetection = true
        rebuildMenu()
    }

    /// Everything that was on a call has stopped.
    private func meetingEnded() {
        guard Capture.shared.isRecording, startedByDetection else { return }
        stopRecording()
    }

    private func answerMeeting(_ answer: MeetingAnswer) {
        guard let app = awaitingAnswer else { return }
        awaitingAnswer = nil

        if answer == .yes {
            // Nothing to record: the recording is already running and is kept
            // by default. Yes just dismisses the question, and the panel goes
            // back to showing the clock and Stop.
            rebuildMenu()
            return
        }

        if answer == .never { Settings.skip(app) }
        // Suppressed either way. The skip list is consulted on the next poll,
        // but so is the app that is still on the call, so without this "No" is
        // answered by the same question three seconds later.
        MeetingDetector.shared.suppress(app)
        startedByDetection = false

        if let recording = Capture.shared.stop() {
            // The one place a recording is deleted without being asked
            // about. "No" is the answer, given while the call is in front of
            // you and the answer is obvious.
            //
            // One exception, and it is the whole reason their note is editable
            // during a recording: somebody who has already typed into it has
            // said this is a meeting more clearly than the panel ever asked, so
            // deleting it on a mis-click would throw away the only thing here
            // that could not be recorded again.
            if let yours = Notes.yours(for: recording), !yours.body.isEmpty,
               !confirmDiscardingNotes() {
                resolve(recording, keep: true)
                MeetingDetector.shared.captureEnded()
                indicator.hide()
                rebuildMenu()
                return
            }
            do {
                try Capture.shared.discard(recording)
            } catch {
                log("could not discard the declined recording: "
                    + error.localizedDescription)
            }
        }
        MeetingDetector.shared.captureEnded()
        indicator.hide()
        rebuildMenu()
    }

    /// The one follow-up question "No" is allowed to ask.
    ///
    /// Answering a question with another question is normally how people are
    /// trained to click through both, which is why "No" deletes without
    /// confirming. This asks only when there is something in the recording that
    /// was not recorded: text the user typed themselves. Returns true to go
    /// ahead with the deletion.
    private func confirmDiscardingNotes() -> Bool {
        let alert = NSAlert()
        alert.messageText = "You have written notes on this recording."
        alert.informativeText = "Deleting it now deletes the audio. What you typed "
            + "was not recorded from anything, so it cannot be got back."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep the Recording")
        alert.addButton(withTitle: "Delete Anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() != .alertFirstButtonReturn
    }

    /// Keep or delete, wherever the decision came from.
    ///
    /// Shared rather than duplicated, so a recording that ends normally and one
    /// adopted from staging at launch join the library and the transcription
    /// queue by exactly the same steps.
    private func resolve(_ recording: Recording, keep: Bool) {
        do {
            if keep {
                let kept = try Capture.shared.keep(recording)
                // Transcription starts as soon as the recording joins the
                // library, without being asked for. Nobody records a meeting
                // in order to not read it.
                Queue.shared.enqueue(kept.id)
                LibraryWindow.shared.reload()
            } else {
                try Capture.shared.discard(recording)
            }
        } catch {
            notify(keep ? "Could not keep the recording" : "Could not discard the recording",
                   error.localizedDescription)
        }
    }

    @objc private func openLibrary() {
        LibraryWindow.shared.show()
    }

    /// One recording, from the Recent list.
    ///
    /// `open` does not raise the window on its own, because its other callers
    /// are links inside a window that is already key. This one is pressed from
    /// the menu bar, where the window may be closed or behind a browser.
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        LibraryWindow.shared.open(recording: id, note: nil)
    }

    @objc private func openSettings() {
        LibraryWindow.shared.showSettings()
    }

    /// Straight to the pane that can do something about it, rather than to
    /// Settings in general with the user to find it.
    @objc private func openModelSettings() {
        LibraryWindow.shared.showSettings(.models)
    }

    @objc private func openPermissions() {
        LibraryWindow.shared.showSettings(.permissions)
    }

    @objc private func openAbout() {
        LibraryWindow.shared.showSettings(.about)
    }

    @objc private func revealLibrary() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Library.recordings.path)
    }

    /// An alert, floated and activated.
    ///
    /// An `LSUIElement` app has no Dock icon, so a dialog that falls behind the
    /// meeting window is unreachable and the app looks hung.
    private func notify(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.window.level = .floating
        alert.runModal()
    }

    @objc private func quit() {
        // Stop cleanly so the WAV headers are finalised. Quitting mid-capture
        // otherwise leaves the tap and the aggregate device behind in Core
        // Audio, which survives the process.
        if Capture.shared.isRecording { _ = Capture.shared.stop() }
        NSApp.terminate(nil)
    }

    /// Clicking the Dock icon brings the library back rather than doing
    /// nothing, which is what it does by default once the window is closed.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { LibraryWindow.shared.show() }
        return true
    }

    /// Closing the window does not quit. A recording may still be running, and
    /// quitting mid-capture to tidy a window away is the wrong trade.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ note: Notification) {
        if Capture.shared.isRecording { _ = Capture.shared.stop() }
    }
}
