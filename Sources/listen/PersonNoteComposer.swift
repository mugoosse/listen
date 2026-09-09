import AppKit
import AVFoundation
import ListenKit

@MainActor
final class PersonNoteComposer: NSWindowController {
    private let person: String
    private let editor = NSTextView()
    private let excluded = NSButton(checkboxWithTitle: "Exclude from AI", target: nil, action: nil)
    private let voice = NSButton(title: "Record Voice Note", target: nil, action: nil)
    private let save = NSButton(title: "Save Note", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let meter = NSLevelIndicator()
    private let recorder = DictationRecorder()
    private let engine = DictationEngine()
    private var working = false
    private var closed = false
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    var onSaved: (() -> Void)?

    init(person: String, text: String = "") {
        self.person = person
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                            styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Note about " + SpeakerName.display(person)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        }
        let heading = NSTextField(labelWithString: panel.title); heading.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(heading)
        editor.string = text; editor.isRichText = false; editor.font = .systemFont(ofSize: 14)
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Your note about " + SpeakerName.display(person))
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        voice.bezelStyle = .rounded; voice.target = self; voice.action = #selector(toggleVoice)
        meter.levelIndicatorStyle = .continuousCapacity; meter.minValue = 0; meter.maxValue = 1; meter.isHidden = true
        meter.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let voiceRow = NSStackView(views: [voice, meter]); voiceRow.orientation = .horizontal; voiceRow.spacing = 12
        stack.addArrangedSubview(voiceRow)
        stack.addArrangedSubview(excluded)
        let automatic = (try? MemoryPreferences.policy(MemoryPreferences.personID(person, root: Library.root), root: Library.root).automatic) == true
        status.stringValue = automatic
            ? "Automatic summaries are on for this person. Exclude this note to keep it out of Ask and summaries."
            : "Saved in your library. Used by AI only when you ask or create a summary. Voice is transcribed on this Mac."
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 510; stack.addArrangedSubview(status)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelNote)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        save.bezelStyle = .rounded; save.target = self; save.action = #selector(saveNote); save.keyEquivalent = "\r"; save.keyEquivalentModifierMask = [.command]
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [spacer, cancel, save]); actions.orientation = .horizontal; actions.spacing = 8
        stack.addArrangedSubview(actions); actions.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        recorder.onLevel = { [weak self] level in DispatchQueue.main.async { self?.meter.doubleValue = Double(level) } }
        recorder.onFirstBuffer = { [weak self] in DispatchQueue.main.async { self?.status.stringValue = "Recording your voice…" } }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(from parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window); window.makeFirstResponder(editor)
    }
    @objc private func toggleVoice() {
        if recorder.isRecording { finishVoice(); return }
        guard !working, !Capture.shared.isRecording, Dictation.shared.phase == .idle else {
            status.stringValue = "Finish the current recording or dictation before recording a note."; return
        }
        working = true; save.isEnabled = false; voice.isEnabled = false; status.stringValue = "Preparing local transcription…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw ContextProblem.message("Allow microphone access in System Settings to record a voice note.") }
                try await engine.prepare()
                guard await engine.isReady else { throw ContextProblem.message("Download a transcription model in Settings before recording a voice note.") }
                try Task.checkCancellation()
                guard !closed else { return }
                status.stringValue = "Starting the microphone…"
                recorder.start { [weak self] result in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.closed { _ = self.recorder.stop(); return }
                        switch result {
                        case .success:
                            self.voice.title = "Stop Recording"; self.voice.isEnabled = true; self.meter.isHidden = false
                            self.deadline = Task { [weak self] in
                                try? await Task.sleep(nanoseconds: 120_000_000_000)
                                if !Task.isCancelled { self?.finishVoice() }
                            }
                        case .failure(let error): self.failed(error.localizedDescription)
                        }
                    }
                }
            } catch { if !closed { failed(error.localizedDescription) } }
        }
    }
    private func finishVoice() {
        deadline?.cancel(); voice.isEnabled = false; meter.isHidden = true
        guard let samples = recorder.stop() else { failed("No audio was recorded."); return }
        status.stringValue = "Transcribing on this Mac…"
        task = Task { [weak self] in
            guard let self else { return }
            let result = await engine.transcribe(samples)
            guard !closed, !Task.isCancelled else { return }
            if let result, !result.isEmpty {
                editor.string += (editor.string.isEmpty ? "" : "\n\n") + result
                failed("Review your words, then Save Note.")
            } else { failed("No speech was recognised. You can try again or type your note.") }
        }
    }
    private func failed(_ message: String) {
        working = false; save.isEnabled = true; voice.isEnabled = true; voice.title = "Record Voice Note"; status.stringValue = message
    }
    @objc private func saveNote() {
        guard !working else { return }
        do {
            _ = try Notes.createPersonNote(editor.string, person: person, excluded: excluded.state == .on)
            onSaved?(); cancelNote()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func cancelNote() {
        closed = true; task?.cancel(); deadline?.cancel()
        if recorder.isRecording { _ = recorder.stop() }
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
    }
}

extension Notes {
    static func createPersonNote(_ text: String, person: String, excluded: Bool = false) throws -> Note {
        let person = try PeopleMemory.resolve(person)
        let id = MemoryPreferences.personID(person, root: Library.root)
        try MemoryPreferences.associate(person, id: id, root: Library.root)
        let title = String(text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first?.prefix(70) ?? "")
        let note = try create(title: title, body: text, source: .you, recordings: [], requiringSources: false,
                             aboutPersonID: id, excludedFromAI: excluded)
        NotificationCenter.default.post(name: PeopleMemory.changed, object: nil)
        return note
    }
}
