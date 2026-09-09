import AppKit
import ListenKit

/// The Dictionary settings pane: the user's own vocabulary, and what it did.
///
/// ## One list of words, not two lists of mechanisms
///
/// This pane used to be a segmented control over *terms* and *corrections*, with
/// an editable table under each. That put the wrong question first. A person
/// with a word Listen keeps getting wrong had to decide whether it was a
/// sounds-like term or an exact correction before they could type anything, and
/// the consequence of choosing wrong is silence: a term under five letters never
/// fires, and a term that sounds like an English word never fires either.
///
/// Measured on the library this was rebuilt against, the split had done real
/// damage. One term, `Kinsight`, had fired 19 times. Five hand-written
/// corrections for the same word had fired 9 between them, and three of the five
/// had never fired at all. The pane showed a name and a checkbox and no numbers,
/// so the half that worked looked like the half that did not.
///
/// So: one row per word, however many rules it takes, and the rows are read-only.
/// Adding and editing happen in `DictionaryWordSheet`, which has room to say
/// which mechanism it chose and what the rule would do to the transcripts you
/// already have.
///
/// ## Everything here is a number, not an assurance
///
/// Listen applies this list at transcription time, to an archive nobody may read
/// for a week, and now applies it on request to transcripts that already exist.
/// So the pane reports: how often each word has been fixed, read off the counts
/// every transcript carries, and what a change would do before it is made.
@MainActor
final class DictionaryPane: Pane, NSTableViewDataSource, NSTableViewDelegate,
                            NSTextFieldDelegate {
    private var entries: [CustomDictionary.Entry] = []
    /// The rows, one per word. Rebuilt from `entries` whenever they change.
    private var words: [DictionaryWord] = []
    /// Fire counts across the library, keyed by `Entry.countKey`. Loaded off the
    /// main thread, so the table draws before they arrive.
    private var totals: [String: Int] = [:]

    private var table: NSTableView!
    private var empty: NSTextField!
    private var effect: NSTextField!
    private var status: NSTextField!
    private var tryField: NSTextField!
    private var tryResult: NSTextField!
    private var suggestionRows: NSStackView!
    private var suggestions: [DictionarySuggestions.Suggestion] = []
    private var suggestionNote: NSTextField!

    /// Held so a sheet is not deallocated while it is on screen.
    private var sheet: DictionaryWordSheet?

    override func viewWillAppear() {
        super.viewWillAppear()
        // The file is editable by hand and `listen dictionary` writes it from
        // another process, so re-read rather than trusting what was loaded when
        // the pane was built.
        reload()
        previewSheetIfAsked()
    }

    /// `LISTEN_DICTIONARY_SHEET=add`, or a word to open it on.
    ///
    /// Scaffolding, in the family of `LISTEN_PANEL`, and for its stated reason:
    /// a state that cannot be put on screen on demand is a state nobody checks.
    /// The sheet is two clicks into a settings pane, so it is the part of this
    /// pane least likely to be looked at after the day it was written, and it
    /// is the part that says what a rule will do before it does it.
    private func previewSheetIfAsked() {
        guard let want = ProcessInfo.processInfo.environment["LISTEN_DICTIONARY_SHEET"],
              sheet == nil else { return }
        // After the pane has a window, or `presentAsSheet` has nothing to
        // attach to and the sheet never appears.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            present(editing: want == "add"
                    ? nil
                    : words.first { $0.key == want.lowercased() })
        }
    }

    override func build() {
        entries = CustomDictionary.load()
        words = DictionaryWord.group(entries)

        // No "Dictionary" heading: the pane draws its own section name at the
        // top now that settings live in the library window's sidebar.
        note("Words Listen should get right: names, products, jargon. Add the spelling you "
             + "want, and the ways you have seen it come out wrong. Listen matches anything "
             + "that sounds like the word as well, when the word is distinctive enough for "
             + "that to be safe, and says which it is doing when you add one.")
        note("One list, used twice: once when a meeting is transcribed, to what is written "
             + "to the library, and again on every dictation before it reaches the "
             + "clipboard. A name Listen mishears in a meeting is the same name it "
             + "mishears when you dictate, so fixing it here fixes both.")

        buildTable()

        empty = note("")
        updateEmpty()

        row([
            NSButton(title: "Add…", target: self, action: #selector(addWord)),
            NSButton(title: "Edit…", target: self, action: #selector(editWord)),
            NSButton(title: "Remove", target: self, action: #selector(removeWord)),
            NSButton(title: "Fix older transcripts…", target: self,
                     action: #selector(backfillEverything)),
        ])
        row([
            NSButton(title: "Import…", target: self, action: #selector(importEntries)),
            NSButton(title: "Export…", target: self, action: #selector(exportEntries)),
            NSButton(title: "Reveal file", target: self, action: #selector(reveal)),
        ])

        status = note("")
        status.isHidden = true

        note("Adding a word applies it to meetings from now on. Whether it also fixes the "
             + "transcripts you already have is a question the sheet asks, with the number "
             + "of sentences it would change, and \"Fix older transcripts\" asks it for the "
             + "whole list. Notes and chats are never rewritten: those are yours.")

        buildSuggestions()
        buildTry()
        buildEffect()
    }

    override func refresh() {
        refreshEffect()
        refreshSuggestions()
    }

    /// Re-read the file and redraw the rows, without tearing the pane down.
    private func reload() {
        entries = CustomDictionary.load()
        words = DictionaryWord.group(entries)
        table?.reloadData()
        updateEmpty()
        refreshEffect()
        refreshSuggestions()
        resizeDocument()
    }

    // -----------------------------------------------------------------------
    // Table
    // -----------------------------------------------------------------------

    private func buildTable() {
        table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(editWord)

        for (id, title, width) in [("word", "Word", 170), ("spellings", "Also heard as", 210),
                                   ("fixed", "Fixed", 60), ("enabled", "On", 40)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = CGFloat(width)
            // Pinned, or the table redistributes the width it was given and
            // squeezes the last column until its header renders as "...".
            column.minWidth = CGFloat(width)
            table.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll)
        widthCapped(scroll)
        // A fixed height, so the table scrolls internally rather than growing
        // the pane without limit. The pane scrolls too, and a scroll view that
        // grows inside a scroll view means the wheel does one of two plausible
        // things depending on where the pointer is.
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { words.count }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < words.count, let id = column?.identifier.rawValue else { return nil }
        let word = words[row]
        let cell = NSTableCellView()

        let control: NSView
        switch id {
        case "enabled":
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle))
            box.state = word.enabled ? .on : .off
            box.tag = row
            box.setAccessibilityLabel("\(word.display) on")
            control = box
        default:
            let field = NSTextField(labelWithString: text(for: word, column: id))
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            if id == "fixed" || (id == "spellings" && word.spellings.isEmpty) {
                field.textColor = .secondaryLabelColor
            }
            field.toolTip = tip(for: word, column: id)
            control = field
        }

        cell.addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            control.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor,
                                              constant: -4),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func text(for word: DictionaryWord, column: String) -> String {
        switch column {
        case "word": return word.display
        case "spellings":
            var parts = word.spellings
            // A rule with no text can never fire, and it looks exactly like a
            // rule that works. One of these sat in a real dictionary doing
            // nothing, so it is said out loud rather than hidden.
            if word.blankRules > 0 { parts.append("(\(word.blankRules) blank, does nothing)") }
            return parts.isEmpty ? "sounds-like only" : parts.joined(separator: ", ")
        case "fixed":
            let n = word.entries.reduce(0) { $0 + (totals[$1.countKey] ?? 0) }
            return n == 0 ? "–" : "\(n)"
        default: return ""
        }
    }

    private func tip(for word: DictionaryWord, column: String) -> String? {
        switch column {
        case "word":
            guard let term = word.term else {
                return "Only the exact spellings listed are replaced."
            }
            if !CustomDictionary.eligible(term.text) {
                return "Too short to be matched by sound: a single word needs five letters, "
                    + "a phrase eight. Only the spellings listed are replaced."
            }
            return "Matched by sound as well as by the spellings listed."
        case "fixed":
            return "How many times these rules have rewritten a transcript."
        default: return nil
        }
    }

    private func updateEmpty() {
        empty?.stringValue = words.isEmpty
            ? "No words yet. Add the names of the people you meet, your products, and "
                + "anything that comes back misspelled every time."
            : ""
        empty?.isHidden = words.isEmpty ? false : true
    }

    @objc private func toggle(_ sender: NSButton) {
        guard sender.tag < words.count else { return }
        let word = words[sender.tag]
        let on = sender.state == .on
        // Every rule for the word, because the row is the word. Turning off
        // "Kinsight" and leaving three corrections for it live would be a
        // switch that lies.
        for i in entries.indices where belongs(entries[i], to: word) {
            entries[i].enabled = on
        }
        CustomDictionary.save(entries)
        words = DictionaryWord.group(entries)
    }

    private func belongs(_ entry: CustomDictionary.Entry, to word: DictionaryWord) -> Bool {
        DictionaryWord.word(for: entry).lowercased() == word.key
    }

    // -----------------------------------------------------------------------
    // Adding and editing
    // -----------------------------------------------------------------------

    @objc private func addWord() { present(editing: nil) }

    @objc private func editWord() {
        guard table.selectedRow >= 0, table.selectedRow < words.count else {
            NSSound.beep()
            return
        }
        present(editing: words[table.selectedRow])
    }

    private func present(editing word: DictionaryWord?) {
        let sheet = DictionaryWordSheet(editing: word) { [weak self] result in
            self?.saved(result, replacing: word)
        }
        self.sheet = sheet
        presentAsSheet(sheet)
    }

    /// Write what the sheet decided, replacing the word's old rules.
    ///
    /// Replaced rather than merged: the sheet showed every spelling this word
    /// has, so a spelling that is not in the result is one somebody deleted, and
    /// merging would put it straight back.
    private func saved(_ result: DictionaryWordSheet.Result, replacing old: DictionaryWord?) {
        var list = entries
        if let old { list.removeAll { belongs($0, to: old) } }
        let merged = CustomDictionary.merge(result.entries, into: list)
        list.append(contentsOf: merged.added)
        CustomDictionary.save(list)
        reload()

        guard result.backfill else { return }
        // The plans the sheet computed, unless somebody saved before the preview
        // came back, in which case they are computed now rather than skipped.
        backfill(result.entries, plans: result.plans)
    }

    @objc private func removeWord() {
        let row = table.selectedRow
        guard row >= 0, row < words.count else { NSSound.beep(); return }
        let word = words[row]
        entries.removeAll { belongs($0, to: word) }
        CustomDictionary.save(entries)
        reload()
    }

    // -----------------------------------------------------------------------
    // Fixing transcripts that already exist
    // -----------------------------------------------------------------------

    /// The whole dictionary against the whole library, with a preview first.
    ///
    /// The pane's route to what `listen dictionary backfill` does, and it asks
    /// the same question in the same order: read what it would change, then say
    /// yes. Never on its own, and never as a side effect of adding a rule.
    @objc private func backfillEverything() {
        guard !entries.isEmpty else { NSSound.beep(); return }
        say("Reading your transcripts…")
        let rules = entries
        Task.detached(priority: .userInitiated) {
            let plans = DictionaryBackfill.preview(rules)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !plans.isEmpty else {
                    say("Nothing to change: every transcript already matches the list.")
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Fix " + DictionaryBackfill.summary(plans) + "?"
                alert.informativeText = examples(plans)
                    + "\n\nThe recordings themselves are not touched, and neither are your "
                    + "notes. Transcribing a recording again would apply the same rules."
                alert.addButton(withTitle: "Fix Them")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    say("Nothing was changed.")
                    return
                }
                apply(plans)
            }
        }
    }

    private func examples(_ plans: [DictionaryBackfill.Plan], cap: Int = 4) -> String {
        let changes = plans.flatMap(\.changes)
        var lines = changes.prefix(cap).map { DictionaryBackfill.excerpt($0, width: 30) }
        if changes.count > cap {
            lines.append("and \(changes.count - cap) more.")
        }
        return lines.joined(separator: "\n")
    }

    /// Compute the plans if they were not computed already, then apply them.
    private func backfill(_ rules: [CustomDictionary.Entry],
                          plans ready: [DictionaryBackfill.Plan]) {
        guard !ready.isEmpty else {
            say("Fixing older transcripts…")
            Task.detached(priority: .userInitiated) {
                let plans = DictionaryBackfill.preview(rules)
                await MainActor.run { [weak self] in self?.apply(plans) }
            }
            return
        }
        apply(ready)
    }

    private func apply(_ plans: [DictionaryBackfill.Plan]) {
        guard !plans.isEmpty else {
            say("Nothing in your transcripts changed.")
            return
        }
        say("Fixing older transcripts…")
        Task.detached(priority: .userInitiated) {
            var sentences = 0, recordings = 0, refused = 0
            for plan in plans {
                if DictionaryBackfill.apply(plan) {
                    recordings += 1
                    sentences += plan.changes.count
                } else {
                    refused += 1
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                var line = "Fixed \(count(sentences, "sentence")) in "
                    + "\(count(recordings, "recording"))."
                // A refusal is a transcript that changed under the plan. Rare,
                // and not something to swallow: the compare-and-swap did its job
                // and the reader is owed the reason their number is short.
                if refused > 0 {
                    line += " \(count(refused, "recording")) "
                        + (refused == 1 ? "was" : "were")
                        + " left alone because it changed while this ran."
                }
                say(line)
                refreshEffect()
            }
        }
    }

    /// The one status line under the buttons.
    ///
    /// A line rather than an alert: this reports on work the user asked for and
    /// then watched, and an alert to say a thing they asked for happened is a
    /// click for nothing. The alert above is different, because it is a question.
    private func say(_ text: String) {
        status?.stringValue = text
        status?.isHidden = text.isEmpty
        resizeDocument()
    }

    // -----------------------------------------------------------------------
    // Suggestions
    // -----------------------------------------------------------------------

    private func buildSuggestions() {
        separator()
        heading("Suggested")
        suggestionNote = note("")
        suggestionRows = NSStackView()
        suggestionRows.orientation = .vertical
        suggestionRows.alignment = .leading
        suggestionRows.spacing = 6
        stack.addArrangedSubview(suggestionRows)
        row([NSButton(title: "Scan the library", target: self, action: #selector(scan))])
        note("Every time you correct a sentence in a transcript, Listen keeps what the model "
             + "wrote and what you replaced it with. Those pairs are the suggestions here. "
             + "Scanning adds a second kind: words that repeat, are not English, and sound "
             + "like somebody on your roster. Nothing is ever added on its own.")
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        guard let suggestionRows else { return }
        suggestions = DictionarySuggestions.pending()
        for view in suggestionRows.arrangedSubviews { view.removeFromSuperview() }

        suggestionNote?.stringValue = suggestions.isEmpty
            ? "Nothing suggested yet. Correct a sentence in a transcript and the word you "
                + "fixed shows up here."
            : ""
        suggestionNote?.isHidden = !suggestions.isEmpty

        for (index, suggestion) in suggestions.prefix(6).enumerated() {
            let text = "\(suggestion.heard) → \(suggestion.meant)"
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 220).isActive = true
            label.toolTip = suggestion.example.isEmpty ? nil : suggestion.example

            let why = NSTextField(labelWithString: suggestion.source == .edit
                                  ? "you fixed it \(suggestion.seen)×"
                                  : "heard \(suggestion.seen)×")
            why.font = .systemFont(ofSize: 11)
            why.textColor = .secondaryLabelColor
            why.translatesAutoresizingMaskIntoConstraints = false
            why.widthAnchor.constraint(equalToConstant: 100).isActive = true

            let add = NSButton(title: "Add", target: self, action: #selector(acceptSuggestion))
            add.tag = index
            add.setAccessibilityLabel("Add \(text)")
            let no = NSButton(title: "Dismiss", target: self,
                              action: #selector(dismissSuggestion))
            no.tag = index
            no.setAccessibilityLabel("Dismiss \(text)")

            let line = NSStackView(views: [label, why, add, no])
            line.orientation = .horizontal
            line.spacing = 8
            suggestionRows.addArrangedSubview(line)
        }
        if suggestions.count > 6 {
            let more = NSTextField(labelWithString:
                "and \(suggestions.count - 6) more, in `listen dictionary suggestions`.")
            more.font = .systemFont(ofSize: 11)
            more.textColor = .secondaryLabelColor
            suggestionRows.addArrangedSubview(more)
        }
        resizeDocument()
    }

    @objc private func acceptSuggestion(_ sender: NSButton) {
        guard sender.tag < suggestions.count else { return }
        let suggestion = suggestions[sender.tag]
        DictionarySuggestions.accept(suggestion)
        reload()
        // Straight into the sheet on the word it just added, because a
        // suggestion is one spelling and the person accepting it usually knows
        // two more. The rule is saved either way: cancelling the sheet leaves
        // what was accepted.
        if let word = words.first(where: { $0.key == suggestion.meant.lowercased() }) {
            present(editing: word)
        }
    }

    @objc private func dismissSuggestion(_ sender: NSButton) {
        guard sender.tag < suggestions.count else { return }
        DictionarySuggestions.dismiss(suggestions[sender.tag])
        refreshSuggestions()
    }

    @objc private func scan() {
        say("Reading your transcripts…")
        Task.detached(priority: .utility) {
            let found = DictionarySuggestions.absorbScan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                say(found == 0
                    ? "Nothing new: no repeated word sounds like a name Listen knows."
                    : "Found \(found) word(s) worth a rule.")
                refreshSuggestions()
            }
        }
    }

    // -----------------------------------------------------------------------
    // Import and export
    // -----------------------------------------------------------------------

    @objc private func reveal() {
        // Create it first, so the button reveals a folder with the file in it
        // rather than silently doing nothing before anything has been saved.
        if !FileManager.default.fileExists(atPath: CustomDictionary.file.path) {
            CustomDictionary.save(entries)
        }
        NSWorkspace.shared.activateFileViewerSelecting([CustomDictionary.file])
    }

    /// Merge a file in rather than replacing what is here.
    ///
    /// Replacing would be one misclick away from destroying a list somebody
    /// built up over months, and merging is what importing usually means.
    @objc private func importEntries() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Import words and spellings. Existing entries are kept."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        take(from: url, source: url.lastPathComponent)
    }

    private func take(from url: URL, source: String) {
        guard let data = try? Data(contentsOf: url),
              let incoming = CustomDictionary.decode(data) else {
            report("Nothing imported",
                   "\(source) is not a dictionary file Listen understands. It reads its "
                   + "own exports and TypeWhisper's.",
                   style: .warning)
            return
        }

        let result = CustomDictionary.merge(incoming, into: entries)
        entries.append(contentsOf: result.added)
        CustomDictionary.save(entries)
        reload()

        let terms = result.added.filter { $0.kind == .term }.count
        let corrections = result.added.count - terms
        var detail = "\(count(terms, "word")) and \(count(corrections, "spelling"))."
        if result.duplicates > 0 {
            detail += " Skipped \(count(result.duplicates, "entry", plural: "entries")) "
                + "already in the dictionary."
        }
        if !result.added.isEmpty {
            detail += " \"Fix older transcripts\" applies them to what you already have."
        }
        report(result.added.isEmpty ? "Nothing new to import" : "Imported", detail)
    }

    @objc private func exportEntries() {
        guard let data = CustomDictionary.encode(entries) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "listen-dictionary.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : plural ?? noun + "s")"
    }

    private func report(_ message: String, _ detail: String,
                        style: NSAlert.Style = .informational) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.alertStyle = style
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // -----------------------------------------------------------------------
    // Trying a rule out
    // -----------------------------------------------------------------------

    /// Type a sentence, see what the dictionary does to it.
    ///
    /// Not a nicety. The sounds-like half is the one part of this app whose
    /// behaviour nobody can predict by reading their own rule: whether "Gusens"
    /// becomes "Goossens" depends on a consonant code and on whether the word is
    /// in the system lexicon. The sheet answers that for a word being added;
    /// this answers it for a sentence somebody has in front of them.
    private func buildTry() {
        separator()
        heading("Try it")
        let field = NSTextField(string: "")
        field.placeholderString = "Type a sentence the way it comes out wrong"
        field.delegate = self
        field.identifier = .init("try")
        field.target = self
        field.action = #selector(runTryNow)
        stack.addArrangedSubview(field)
        widthCapped(field)
        tryField = field

        tryResult = note("")
        tryResult.textColor = .labelColor
    }

    @objc private func runTryNow() { runTry() }

    func controlTextDidEndEditing(_ n: Notification) {
        guard let field = n.object as? NSTextField,
              field.identifier?.rawValue == "try" else { return }
        runTry()
    }

    private func runTry() {
        let input = tryField.stringValue
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else {
            tryResult.stringValue = ""
            resizeDocument()
            return
        }
        let applied = CustomDictionary.apply(to: input, entries: entries)
        tryResult.stringValue = applied.fired.isEmpty
            ? "No rule matched."
            : applied.text + "\n" + summary(applied.fired)
        tryResult.textColor = applied.fired.isEmpty ? .secondaryLabelColor : .labelColor
        resizeDocument()
    }

    // -----------------------------------------------------------------------
    // What it changed
    // -----------------------------------------------------------------------

    private func buildEffect() {
        separator()
        heading("What it changed")
        effect = note("Counting…")
        note("Every transcript records which rules rewrote it. A rule that fires somewhere "
             + "you did not expect is otherwise invisible, because the transcript reads as "
             + "what the model said.")
    }

    /// Total the per-recording counts across the library, off the main thread.
    ///
    /// Reading every `transcript.json` is a few megabytes of JSON on a real
    /// library, which is nothing on its own and is still not something to do
    /// while the settings window is trying to open.
    private func refreshEffect() {
        effect?.stringValue = "Counting…"
        Task.detached(priority: .utility) {
            var totals: [String: Int] = [:]
            var recordings = 0
            for recording in Recording.all() {
                guard let counts = recording.storedTranscript?.dictionary,
                      !counts.isEmpty else { continue }
                recordings += 1
                CustomDictionary.combine(counts, into: &totals)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.totals = totals
                effect?.stringValue = effectText(totals, recordings: recordings)
                // The per-word column reads the same numbers, so it redraws
                // when they land rather than staying at "–" until the pane is
                // opened again.
                table?.reloadData()
                resizeDocument()
            }
        }
    }

    private func effectText(_ totals: [String: Int], recordings: Int) -> String {
        guard !totals.isEmpty else {
            return entries.isEmpty
                ? "Nothing yet, because the dictionary is empty."
                : "No transcript has been rewritten by these rules yet. \"Fix older "
                    + "transcripts\" says what they would change in the ones you have."
        }
        let replacements = totals.values.reduce(0, +)
        return "\(count(replacements, "replacement")) across "
            + "\(count(recordings, "recording")).\n" + summary(totals)
    }

    /// Rules and their counts, biggest first, as one line each.
    ///
    /// Capped, and the cap is stated rather than silently truncating: a list
    /// that stops at six without saying so reads as the only six rules that ever
    /// fired.
    private func summary(_ counts: [String: Int], cap: Int = 6) -> String {
        let sorted = counts.sorted { $0.value == $1.value ? $0.key < $1.key
                                                          : $0.value > $1.value }
        var lines = sorted.prefix(cap).map { key, n in
            // Keys are `term:text` and `correction:text`. Shown as the rule
            // itself, since the two kinds never mean the same edit.
            let parts = key.split(separator: ":", maxSplits: 1)
            let kind = parts.count == 2 ? String(parts[0]) : "rule"
            let text = parts.count == 2 ? String(parts[1]) : key
            return "\(text) · \(kind == "term" ? "by sound" : "exact") · \(n)"
        }
        if sorted.count > cap {
            lines.append("and \(count(sorted.count - cap, "other rule")).")
        }
        return lines.joined(separator: "\n")
    }
}
