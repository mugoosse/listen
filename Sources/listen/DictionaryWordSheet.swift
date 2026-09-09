import AppKit

/// One word the dictionary knows, however many rules that takes.
///
/// **A lens over the file, not a change to it.** `dictionary.json` still holds
/// one entry per pattern, which is what Speak wrote, what an import reads and
/// what the per-rule fire counts are keyed on. Grouping happens on the way to
/// the screen, where "Kinsight, also heard as Kinsite, Kinsai, Kinsey" is one
/// thing a person has an opinion about and six rows is not.
///
/// The key is the right spelling: a term's own text, or a correction's
/// replacement. Case-insensitive, because two rules differing only in the
/// capitalisation of the same word are not two words.
struct DictionaryWord {
    var display: String
    /// The sounds-like half, if this word has one.
    var term: CustomDictionary.Entry?
    /// Exact spellings that become it.
    var corrections: [CustomDictionary.Entry]

    var entries: [CustomDictionary.Entry] { (term.map { [$0] } ?? []) + corrections }
    var enabled: Bool { entries.allSatisfy(\.enabled) }
    /// True only when every correction says so, since the sheet offers one
    /// switch for the word rather than one per spelling.
    var caseSensitive: Bool {
        !corrections.isEmpty && corrections.allSatisfy(\.caseSensitive)
    }
    /// Spellings a person can read. A correction with no text is a rule that can
    /// never fire, and it is counted rather than hidden.
    var spellings: [String] { corrections.map(\.text).filter { !$0.isEmpty } }
    var blankRules: Int { corrections.filter { $0.text.isEmpty }.count }

    var key: String { display.lowercased() }

    /// Which word an entry belongs to.
    ///
    /// A correction with no replacement at all is a rule that deletes text. The
    /// pane's old editable table could make one by accident and nothing else
    /// can, so it files under its own text rather than under the empty string:
    /// a rule nobody can see is a rule nobody can delete.
    static func word(for entry: CustomDictionary.Entry) -> String {
        if entry.kind == .term { return entry.text }
        return entry.replacement.isEmpty ? entry.text : entry.replacement
    }

    /// Group a flat entry list, keeping the order the file has them in.
    static func group(_ entries: [CustomDictionary.Entry]) -> [DictionaryWord] {
        var order: [String] = []
        var byKey: [String: DictionaryWord] = [:]
        for entry in entries {
            let word = word(for: entry)
            let key = word.lowercased()
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = DictionaryWord(display: word, term: nil, corrections: [])
            }
            if entry.kind == .term {
                byKey[key]?.term = entry
                // The term's own spelling is the authority on how the word
                // looks: a correction's replacement could have been typed in a
                // hurry, and the term is the one that gets written into
                // transcripts.
                byKey[key]?.display = entry.text
            } else {
                byKey[key]?.corrections.append(entry)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}

/// Adding or editing one word, with what it would do to the library on the way.
///
/// ## Why a sheet, and why the table stopped being editable
///
/// The table used to be the editor: click a cell, type, and a rule was live. It
/// asked the wrong question first. Somebody adding "Kinsight" had to know
/// whether it was a *term* or a *correction* before they could type anything,
/// which is a question about the matching mechanism, not about their word, and
/// getting it wrong is silent. Editing in place also had no room to say what a
/// rule was about to do, and what it is about to do now includes rewriting
/// transcripts that already exist.
///
/// So: the word on top, the spellings underneath, and Listen decides which
/// mechanism carries which. The sheet says which it chose, in a sentence, before
/// anything is saved.
///
/// ## The preview is the point
///
/// The sounds-like half is the one part of this app nobody can predict by
/// reading their own rule, and the corrections half is exact but its reach over
/// a library of 75 meetings is not something anybody can hold in their head.
/// Both are answerable by running the rules, so the sheet runs them: "would fix
/// 18 sentences in 4 recordings", with two of them shown.
///
/// It costs about six seconds on a 75-recording library, measured twice warm,
/// and almost all of that is reading 8.9 MB of JSON rather than matching:
/// 10,000 words of text go through the rules in 0.04s. So it is a background
/// task behind a debounce, it says it is working, and its results carry a
/// generation number, because two passes started a keystroke apart finish in
/// whichever order they like and the stale one must not win.
@MainActor
final class DictionaryWordSheet: NSViewController, NSTextFieldDelegate {

    struct Result {
        /// The entries this word is now, replacing whatever it was.
        var entries: [CustomDictionary.Entry]
        /// Whether to apply them to transcripts that already exist.
        var backfill: Bool
        /// What the preview found, when it had finished. Empty means nobody
        /// asked it yet, and the caller works it out rather than assuming
        /// there is nothing to do: somebody who types a word and hits Return
        /// inside half a second still means the same thing by it.
        var plans: [DictionaryBackfill.Plan]
    }

    private let editing: DictionaryWord?
    private let onSave: (Result) -> Void

    private let wordField = NSTextField()
    private var spellingFields: [NSTextField] = []
    private var spellingRows: NSStackView!
    private let caseBox = NSButton(checkboxWithTitle: "Match capitals exactly",
                                   target: nil, action: nil)
    private let backfillBox = NSButton(checkboxWithTitle: "Also fix transcripts you already "
                                       + "have", target: nil, action: nil)
    private var advice: NSTextField!
    private var preview: NSTextField!
    private var saveButton: NSButton!

    /// The debounce. Typing a name is six keystrokes and each one would
    /// otherwise start a six-second pass over every transcript in the library.
    private var pending: DispatchWorkItem?
    /// Which preview is current. A pass that finishes after a newer one started
    /// is answering a question nobody is asking any more, and letting it write
    /// its answer would leave the sheet describing a rule that is no longer in
    /// the fields.
    private var generation = 0
    /// The plans the preview last found, so Save does not compute them twice.
    private var plans: [DictionaryBackfill.Plan] = []

    init(editing: DictionaryWord? = nil, onSave: @escaping (Result) -> Void) {
        self.editing = editing
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: editing == nil
                                ? "Add a word" : "Edit \(editing?.display ?? "")")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)

        stack.addArrangedSubview(label("Spell it like this", bold: true))
        wordField.placeholderString = "Kinsight"
        wordField.stringValue = editing?.display ?? ""
        wordField.delegate = self
        wordField.translatesAutoresizingMaskIntoConstraints = false
        wordField.widthAnchor.constraint(equalToConstant: Self.width - 40).isActive = true
        stack.addArrangedSubview(wordField)

        stack.addArrangedSubview(label("Also heard as", bold: true))
        stack.addArrangedSubview(note("Exact spellings Listen should replace. One per line, "
                                      + "and you can add as many as you keep seeing."))

        spellingRows = NSStackView()
        spellingRows.orientation = .vertical
        spellingRows.alignment = .leading
        spellingRows.spacing = 6
        stack.addArrangedSubview(spellingRows)
        for spelling in editing?.spellings ?? [] { addSpellingRow(spelling) }
        if spellingFields.isEmpty { addSpellingRow("") }

        let another = NSButton(title: "Add another spelling", target: self,
                               action: #selector(addAnother))
        another.bezelStyle = .rounded
        stack.addArrangedSubview(another)

        caseBox.state = (editing?.caseSensitive ?? false) ? .on : .off
        caseBox.target = self
        caseBox.action = #selector(recheck)
        stack.addArrangedSubview(caseBox)

        advice = note("")
        advice.isHidden = true
        stack.addArrangedSubview(advice)

        preview = note("")
        preview.isHidden = true
        stack.addArrangedSubview(preview)

        backfillBox.state = .on
        backfillBox.target = self
        backfillBox.action = #selector(nothing)
        stack.addArrangedSubview(backfillBox)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        stack.addArrangedSubview(buttons)
        // Trailing, which is where a sheet's buttons live, and the only row here
        // that is not leading-aligned.
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor,
                                          constant: -20).isActive = true

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        recheck()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(wordField)
    }

    private static let width: CGFloat = 460

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        return field
    }

    /// A wrapping label has to be told its width, or it reports one line high
    /// and the sheet clips everything under it.
    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = Self.width - 40
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Self.width - 40).isActive = true
        return field
    }

    // -----------------------------------------------------------------------
    // The spelling rows
    // -----------------------------------------------------------------------

    private func addSpellingRow(_ text: String) {
        let field = NSTextField(string: text)
        field.placeholderString = "Kinsite"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Self.width - 90).isActive = true

        let remove = NSButton(title: "−", target: self, action: #selector(removeSpelling(_:)))
        remove.bezelStyle = .rounded
        remove.setAccessibilityLabel("Remove this spelling")

        let row = NSStackView(views: [field, remove])
        row.orientation = .horizontal
        row.spacing = 6
        spellingRows.addArrangedSubview(row)
        spellingFields.append(field)
    }

    @objc private func addAnother() {
        addSpellingRow("")
        view.window?.makeFirstResponder(spellingFields.last)
        resize()
    }

    @objc private func removeSpelling(_ sender: NSButton) {
        guard let row = sender.superview as? NSStackView,
              let field = row.arrangedSubviews.first as? NSTextField else { return }
        spellingFields.removeAll { $0 === field }
        row.removeFromSuperview()
        // Never nothing: an empty list has no way back to a first row, and the
        // row is also how somebody starts typing the spelling they came for.
        if spellingFields.isEmpty { addSpellingRow("") }
        recheck()
        resize()
    }

    private func resize() {
        view.layoutSubtreeIfNeeded()
        view.window?.setContentSize(view.fittingSize)
    }

    // -----------------------------------------------------------------------
    // What it would do
    // -----------------------------------------------------------------------

    func controlTextDidChange(_ notification: Notification) { recheck() }

    /// The entries this sheet would write.
    ///
    /// A term for the word itself, always, even when it is too short to be
    /// matched by sound: a term is also the spelling hint the dictation
    /// polisher is given, and that half has no length floor. The advice line
    /// says which of the two jobs it will actually do.
    private func candidates() -> [CustomDictionary.Entry] {
        let word = wordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return [] }
        var out = [CustomDictionary.Entry(kind: .term, text: word)]
        var seen = Set([word.lowercased()])
        for field in spellingFields {
            let spelling = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty row is somebody who has not typed yet, and a spelling
            // equal to the word is a rule that replaces a word with itself.
            guard !spelling.isEmpty, !seen.contains(spelling.lowercased()) else { continue }
            seen.insert(spelling.lowercased())
            out.append(CustomDictionary.Entry(kind: .correction, text: spelling,
                                              replacement: word,
                                              caseSensitive: caseBox.state == .on))
        }
        return out
    }

    @objc private func recheck() {
        let entries = candidates()
        saveButton.isEnabled = !entries.isEmpty
        pending?.cancel()
        guard !entries.isEmpty else {
            // Hidden rather than emptied. A wrapping label with no string in
            // it still takes a line of the sheet, and the sheet with nothing
            // typed in it opened with a hole where the answer goes.
            advice.stringValue = ""
            advice.isHidden = true
            preview.stringValue = ""
            preview.isHidden = true
            plans = []
            resize()
            return
        }

        preview.stringValue = "Checking your transcripts…"
        preview.isHidden = false
        generation += 1
        let mine = generation
        let work = DispatchWorkItem {
            Task.detached(priority: .userInitiated) {
                let word = entries[0].text
                let eligible = CustomDictionary.eligible(word)
                let clash = CustomDictionary.englishSoundalike(for: word)
                let plans = DictionaryBackfill.preview(entries)
                await MainActor.run { [weak self] in
                    guard let self, mine == generation else { return }
                    show(word: word, eligible: eligible, clash: clash, plans: plans)
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func show(word: String, eligible: Bool, clash: String?,
                      plans: [DictionaryBackfill.Plan]) {
        self.plans = plans
        advice.stringValue = adviceText(word: word, eligible: eligible, clash: clash)
        advice.isHidden = false
        preview.isHidden = false

        if plans.isEmpty {
            preview.stringValue = "Nothing in your transcripts changes."
            // Off and out of reach, because the checkbox now has a definite
            // answer: there is nothing for it to do. Left enabled it would
            // promise a pass that rewrites nothing. The title goes back too, or
            // a count from the previous keystroke outlives the plan it counted.
            backfillBox.state = .off
            backfillBox.isEnabled = false
            backfillBox.title = "Also fix transcripts you already have"
        } else {
            var lines = ["Would fix " + DictionaryBackfill.summary(plans) + ":"]
            for change in plans.flatMap(\.changes).prefix(2) {
                lines.append("    " + DictionaryBackfill.excerpt(change, width: 30))
            }
            preview.stringValue = lines.joined(separator: "\n")
            backfillBox.isEnabled = true
            let n = plans.reduce(0) { $0 + $1.changes.count }
            backfillBox.title = n == 1 ? "Also fix that one sentence now"
                                       : "Also fix those \(n) sentences now"
        }
        resize()
    }

    /// Which mechanism will carry this word, in a sentence.
    ///
    /// The three answers are the three things somebody cannot work out for
    /// themselves, and each of them has cost somebody a week of a word staying
    /// wrong:
    ///
    /// - Long enough and distinctive: mishearings are caught without being
    ///   listed.
    /// - Too short: the sounds-like half will never fire, so the spellings are
    ///   the whole rule.
    /// - Sounds like an English word: the net refuses to swap a real word, so
    ///   again the spellings are the whole rule. This is the one that looks
    ///   like a bug, because the term is *there* and does nothing.
    private func adviceText(word: String, eligible: Bool, clash: String?) -> String {
        if !eligible {
            return "\"\(word)\" is too short to be matched by sound: that needs five "
                + "letters, or eight across a phrase. Only the spellings you list are "
                + "fixed, and the word is still given to the polisher when you dictate."
        }
        if let clash {
            // Precisely what the guard does, and not a word more. The term still
            // catches mishearings that are not words; what it will never do is
            // rewrite this one, so the spelling to list is that one.
            return "Anything that sounds like \"\(word)\" is corrected automatically, "
                + "except \"\(clash)\": that is an English word, and Listen never rewrites "
                + "ordinary English. Add it above if you see it written that way."
        }
        return "\"\(word)\" is long enough and is not an English word, so anything that "
            + "sounds like it is corrected automatically, whether or not you list it."
    }

    // -----------------------------------------------------------------------
    // Saving
    // -----------------------------------------------------------------------

    @objc private func cancel() { dismiss(self) }

    @objc private func save() {
        let entries = candidates()
        guard !entries.isEmpty else { NSSound.beep(); return }
        // The plans are the ones the preview showed. Recomputing them here
        // against the same entries would give the same answer more slowly, and
        // a Save that quietly did more than the sheet said it would is the one
        // outcome this design is against.
        onSave(Result(entries: entries,
                      backfill: backfillBox.isEnabled && backfillBox.state == .on,
                      plans: plans))
        dismiss(self)
    }

    /// The checkbox needs a target to stay clickable; its state is read on save.
    @objc private func nothing() {}
}
