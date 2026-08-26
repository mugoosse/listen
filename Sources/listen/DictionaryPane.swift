import AppKit

/// The Dictionary settings pane: the user's own vocabulary, and what it did.
///
/// Two halves of one list, because they explain each other. A term is matched by
/// sound and a correction is matched exactly, and neither is comprehensible on
/// its own: split across two tabs, neither half says what it is relative to.
///
/// "What it changed" is the section that earns the pane. Listen applies this
/// list at transcription time, to an archive nobody may read for a week, so the
/// pane has to be able to answer "what has this actually changed" with numbers
/// rather than an assurance. It reads the counts every transcript carries.
@MainActor
final class DictionaryPane: Pane, NSTableViewDataSource, NSTableViewDelegate,
                            NSTextFieldDelegate {
    private var entries: [CustomDictionary.Entry] = []
    /// Which half the table is showing. Held here rather than read back off the
    /// control, so `rebuild()` does not snap it back to Terms.
    private var showing: CustomDictionary.Kind = .term
    private var table: NSTableView!
    private var empty: NSTextField!
    private var effect: NSTextField!
    private var tryField: NSTextField!
    private var tryResult: NSTextField!

    /// Indices into `entries` for the rows on screen, so a row number can be
    /// turned back into the entry it edits.
    private var visible: [Int] {
        entries.indices.filter { entries[$0].kind == showing }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The file is editable by hand and `listen dictionary` writes it from
        // another process, so re-read rather than trusting what was loaded when
        // the pane was built.
        entries = CustomDictionary.load()
        table?.reloadData()
        updateEmpty()
    }

    override func build() {
        entries = CustomDictionary.load()

        // No "Dictionary" heading: the pane draws its own section name at the
        // top now that settings live in the library window's sidebar.
        note("Terms are words Listen should know: names, products, jargon. Anything in a "
             + "transcript that sounds like one, and is not a word in its own right, is "
             + "corrected to it. Corrections are exact replacements, for mishearings that "
             + "sound nothing like the word you meant.")
        note("One list, used twice: once when a meeting is transcribed, to what is written "
             + "to the library, and again on every dictation before it reaches the "
             + "clipboard. A name Listen mishears in a meeting is the same name it "
             + "mishears when you dictate, so fixing it here fixes both.")
        note("Adding a rule does not change transcripts you already have, and "
             + "re-transcribing a recording applies the list as it stands then.")

        let picker = NSSegmentedControl(
            labels: ["Terms", "Corrections"], trackingMode: .selectOne,
            target: self, action: #selector(switchKind))
        picker.selectedSegment = showing == .term ? 0 : 1
        stack.addArrangedSubview(picker)

        buildTable()

        empty = note("")
        updateEmpty()

        row([
            NSButton(title: "Add", target: self, action: #selector(addEntry)),
            NSButton(title: "Remove", target: self, action: #selector(removeEntry)),
            NSButton(title: "Import…", target: self, action: #selector(importEntries)),
            NSButton(title: "Export…", target: self, action: #selector(exportEntries)),
            NSButton(title: "Reveal file", target: self, action: #selector(reveal)),
        ])

        note(showing == .term
             ? "Matched by sound. A single word needs five letters and is never swapped "
                 + "for a real English word, so \"Codex\" leaves \"codes\" alone. A phrase "
                 + "needs every word to match, which is how \"Claude Code\" catches "
                 + "\"Cloud coat\"."
             : "Matches whole words where the text is a word, so \"cat\" leaves "
                 + "\"category\" alone. The longest match wins, so a rule for a full name "
                 + "beats one for the first name.")

        buildTry()
        buildEffect()
    }

    override func refresh() {
        refreshEffect()
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

        for (id, title, width) in columns() {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            // Pinned, or the table redistributes the width it was given and
            // squeezes the last column until its header renders as "...".
            column.minWidth = width
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

    private func columns() -> [(String, String, CGFloat)] {
        showing == .term
            ? [("text", "Term", 430), ("enabled", "On", 50)]
            : [("text", "Replace", 165), ("replacement", "With", 160),
               ("caseSensitive", "Match case", 90), ("enabled", "On", 45)]
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let rows = visible
        guard row < rows.count, let id = column?.identifier.rawValue else { return nil }
        let entry = entries[rows[row]]
        let cell = NSTableCellView()

        let control: NSView
        switch id {
        case "enabled", "caseSensitive":
            let box = NSButton(checkboxWithTitle: "", target: self,
                               action: #selector(toggleFlag))
            box.state = (id == "enabled" ? entry.enabled : entry.caseSensitive) ? .on : .off
            box.tag = row
            box.identifier = .init(id)
            control = box
        default:
            let field = NSTextField(string: id == "text" ? entry.text : entry.replacement)
            field.isBordered = false
            field.drawsBackground = false
            field.font = .systemFont(ofSize: 12)
            field.delegate = self
            field.tag = row
            field.identifier = .init(id)
            // A term too short to be matched by sound is stored and does
            // nothing, which is indistinguishable from the feature not working.
            // Say so on the row rather than in a note nobody reads twice.
            if showing == .term, !entry.text.isEmpty,
               !CustomDictionary.eligible(entry.text) {
                field.textColor = .secondaryLabelColor
                field.toolTip = "Too short to match by sound. A single word needs five "
                    + "letters, a phrase needs eight."
            }
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

    private func updateEmpty() {
        empty?.stringValue = showing == .term
            ? "No terms yet. Add the names of the people you meet, and anything that comes "
                + "back misspelled every time."
            : "No corrections yet. Add one for anything you fix by hand after every meeting."
        empty?.isHidden = !visible.isEmpty
    }

    @objc private func switchKind(_ sender: NSSegmentedControl) {
        showing = sender.selectedSegment == 0 ? .term : .correction
        // Rebuilt rather than reloaded: the columns and the explanation beneath
        // the table are both different for the two kinds.
        rebuild()
    }

    @objc private func addEntry() {
        entries.append(CustomDictionary.Entry(kind: showing, text: ""))
        CustomDictionary.save(entries)
        table.reloadData()
        updateEmpty()
        let row = visible.count - 1
        guard row >= 0 else { return }
        table.scrollRowToVisible(row)
        table.selectRowIndexes([row], byExtendingSelection: false)
        // Straight into editing: an empty row is not self-explanatory, and a
        // blank entry left behind does nothing at all.
        table.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeEntry() {
        let row = table.selectedRow
        guard row >= 0, row < visible.count else { NSSound.beep(); return }
        entries.remove(at: visible[row])
        CustomDictionary.save(entries)
        table.reloadData()
        updateEmpty()
    }

    @objc private func toggleFlag(_ sender: NSButton) {
        let rows = visible
        guard sender.tag < rows.count else { return }
        let index = rows[sender.tag]
        if sender.identifier?.rawValue == "enabled" {
            entries[index].enabled = sender.state == .on
        } else {
            entries[index].caseSensitive = sender.state == .on
        }
        CustomDictionary.save(entries)
    }

    /// Commit on focus loss as well as on Return.
    ///
    /// Without this, typing a term and clicking straight to Close would throw it
    /// away, which reads as the feature being broken rather than as an
    /// uncommitted edit.
    func controlTextDidEndEditing(_ n: Notification) {
        guard let field = n.object as? NSTextField,
              let id = field.identifier?.rawValue else { return }
        if id == "try" { runTry(); return }

        let rows = visible
        guard field.tag < rows.count else { return }
        let index = rows[field.tag]
        if id == "text" {
            entries[index].text = field.stringValue
        } else {
            entries[index].replacement = field.stringValue
        }
        CustomDictionary.save(entries)
        table.reloadData()
        updateEmpty()
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
    /// built up over months, and merging is what importing usually means. Both
    /// kinds arrive at once whatever the table is showing, since a file holds
    /// terms and corrections together.
    @objc private func importEntries() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Import terms and corrections. Existing entries are kept."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        take(from: url, source: url.lastPathComponent)
    }

    private func take(from url: URL, source: String) {
        guard let data = try? Data(contentsOf: url),
              let incoming = CustomDictionary.decode(data) else {
            report("Nothing imported",
                   "\(source) is not a dictionary file Listen understands. It reads its "
                   + "own exports, Speak's, and TypeWhisper's.",
                   style: .warning)
            return
        }

        let result = CustomDictionary.merge(incoming, into: entries)
        entries.append(contentsOf: result.added)
        CustomDictionary.save(entries)
        rebuild()

        let terms = result.added.filter { $0.kind == .term }.count
        let corrections = result.added.count - terms
        var detail = "\(count(terms, "term")) and \(count(corrections, "correction"))."
        if result.duplicates > 0 {
            detail += " Skipped \(count(result.duplicates, "entry", plural: "entries")) "
                + "already in the dictionary."
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
    /// in the system lexicon. The alternative to trying it here is adding a rule
    /// and finding out an hour later, on a real meeting, in an archive.
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
                effect?.stringValue = effectText(totals, recordings: recordings)
                resizeDocument()
            }
        }
    }

    private func effectText(_ totals: [String: Int], recordings: Int) -> String {
        guard !totals.isEmpty else {
            return entries.isEmpty
                ? "Nothing yet, because the dictionary is empty."
                : "No transcript has been rewritten by these rules yet. Only recordings "
                    + "transcribed since you added them are counted."
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
            return "\(text) · \(kind) · \(n)"
        }
        if sorted.count > cap {
            lines.append("and \(count(sorted.count - cap, "other rule")).")
        }
        return lines.joined(separator: "\n")
    }
}
