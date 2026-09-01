import AppKit

/// One hit on the page, and where it is.
///
/// The three surfaces a page is made of address text differently: the title is
/// a range in a label, a note is a range in an `NSTextView`, and a paragraph is
/// a turn index plus a range inside that turn's own string. A single struct
/// covering all three would carry a nil for two thirds of every match, so the
/// address is an enum and the ordering is a property of the array rather than
/// of the value.
struct FindMatch: Equatable {
    enum Place: Equatable {
        /// Into `titleLabel.stringValue`.
        case title(NSRange)
        /// Into the string of the note on screen.
        case note(slug: String, NSRange)
        /// Into `turns[index].text`.
        case turn(index: Int, NSRange)
    }

    var place: Place

    /// When this match is spoken, for the waveform's ticks. nil for the title
    /// and the note, which are not on the clock.
    ///
    /// Taken once, when the list is built, and never re-derived. The same rule
    /// `loadWaveform` follows for `spans`: a tick and the paragraph it points
    /// at cannot then name two different seconds.
    var time: TimeInterval?
}

/// Somewhere a `FindBar` can search. Both panes that carry one conform.
///
/// A protocol rather than a reference to `DetailView`, because the note page is
/// one `NSTextView` and the recording page is a title, a note and two hundred
/// paragraphs, and the bar has no business knowing which it is over.
@MainActor
protocol FindHost: AnyObject {
    /// Rebuild the match list for this query and say how many there are.
    func findMatches(for query: String) -> Int
    /// Highlight and scroll to the match at this index.
    func goToMatch(_ index: Int)
    /// Take every find highlight off the page.
    func clearFind()
}

/// The find bar: a field, a counter, two chevrons and a way out.
///
/// It owns nothing but its own controls. The query goes out through `onQuery`,
/// stepping through `onStep`, and the host reports back with `report(_:of:)`,
/// so the bar never holds a match list and cannot disagree with the page about
/// what is on it.
@MainActor
final class FindBar: NSView {
    /// Its height when open. The collapsed pair on the pane holds 0.
    static let height: CGFloat = 30

    var onQuery: ((String) -> Void)?
    /// +1 for next, -1 for previous.
    var onStep: ((Int) -> Void)?
    var onDone: (() -> Void)?

    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let previous = HoverButton(.ink)
    private let next = HoverButton(.ink)
    private let done = HoverButton(.ink)

    var query: String { field.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = "Find in page"
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        // **Its own delegate, never the pane's.** `DetailView` is an
        // `NSTextFieldDelegate` and its `controlTextDidEndEditing` does not
        // check which field sent it: it renames the recording to the title
        // label's contents unconditionally, because the title used to be the
        // only field delegating there. Pointing this one at the pane renames
        // the meeting to whatever was being searched for, the moment the field
        // gives up focus.
        field.delegate = self

        // Monospaced digits, because "9 of 12" going to "10 of 12" must not
        // shift the two chevrons beside it. The same reason the transcript's
        // timestamps have them.
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        chevron(previous, "chevron.up", "Previous match", #selector(pressPrevious))
        chevron(next, "chevron.down", "Next match", #selector(pressNext))

        done.title = "Done"
        done.font = .systemFont(ofSize: 12)
        done.target = self
        done.action = #selector(pressDone)
        done.setAccessibilityLabel("Done")
        done.setContentHuggingPriority(.required, for: .horizontal)

        for v in [field, count, previous, next, done] as [NSView] { addSubview(v) }

        // A field that grows with the pane up to a point, rather than one fixed
        // width: the pane is 620 points on a narrow window and most of the
        // screen on a wide one, and a 160 point field in the second case reads
        // as a control that failed to lay out.
        let width = field.widthAnchor.constraint(equalToConstant: 320)
        width.priority = .defaultHigh

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            width,

            count.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 10),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),

            previous.leadingAnchor.constraint(greaterThanOrEqualTo: count.trailingAnchor,
                                              constant: 8),
            previous.centerYAnchor.constraint(equalTo: centerYAnchor),
            next.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 4),
            next.centerYAnchor.constraint(equalTo: centerYAnchor),

            done.leadingAnchor.constraint(equalTo: next.trailingAnchor, constant: 12),
            done.trailingAnchor.constraint(equalTo: trailingAnchor),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        report(nil, of: 0)
    }

    /// A chevron, as a button rather than as an image view.
    ///
    /// `HoverButton` because a borderless control in this app is silent until
    /// pressed without it, and because it is an `NSButton` and so answers to
    /// accessibility: `HoverRow` does not, which is what makes every popover
    /// list row in this app untestable. This bar has to be drivable.
    private func chevron(_ button: HoverButton, _ symbol: String,
                         _ label: String, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    // MARK: - Driving it

    /// Say where the page is in its matches. `at` is nil when there are none.
    func report(_ at: Int?, of total: Int) {
        // Nothing at all rather than "0 of 0" on an empty field: the bar opens
        // before anything is typed, and a zero is a result where there was no
        // question.
        if field.stringValue.isEmpty {
            count.stringValue = ""
        } else if total == 0 {
            count.stringValue = "Not found"
        } else {
            count.stringValue = "\((at ?? 0) + 1) of \(total)"
        }
        previous.isEnabled = total > 0
        next.isEnabled = total > 0
    }

    /// Put the caret in the field with everything selected.
    ///
    /// The same two lines the title's editor uses. Cmd-F with the bar already
    /// up lands here rather than closing it, which is what every Mac app does.
    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func setQuery(_ text: String) {
        field.stringValue = text
    }

    @objc private func pressPrevious() { onStep?(-1) }
    @objc private func pressNext() { onStep?(1) }
    @objc private func pressDone() { onDone?() }
}

extension FindBar: NSSearchFieldDelegate {
    /// **`controlTextDidChange`, never the field's action.** The action fires on
    /// Return and on the field's own delay, which is far too late for a bar
    /// that is meant to count as you type. The sidebar's field records the same
    /// thing for the same reason.
    func controlTextDidChange(_ note: Notification) {
        onQuery?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.cancelOperation(_:)):
            onDone?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            onStep?(1)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            onStep?(-1)
            return true
        default:
            return false
        }
    }
}

// MARK: - Finding text

enum Find {
    /// Every range in `text` matching `query`, left to right.
    ///
    /// Case and diacritic insensitive, which is what somebody typing "cafe"
    /// into a bar means. **The returned range is what advances the cursor, not
    /// the needle's length**: a diacritic-insensitive match can be a different
    /// number of characters from the thing that was typed, and stepping by the
    /// needle either rescans a character or skips one.
    static func ranges(of query: String, in text: String) -> [NSRange] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, !text.isEmpty else { return [] }
        let haystack = text as NSString
        var out: [NSRange] = []
        var from = 0
        while from < haystack.length {
            let rest = NSRange(location: from, length: haystack.length - from)
            let found = haystack.range(of: wanted,
                                       options: [.caseInsensitive, .diacriticInsensitive],
                                       range: rest)
            guard found.location != NSNotFound else { break }
            out.append(found)
            // A zero-length match cannot happen with a non-empty needle, but a
            // loop that could not advance would hang the app rather than
            // misdraw it, so the step is at least one.
            from = max(NSMaxRange(found), found.location + 1)
        }
        return out
    }
}
