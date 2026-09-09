import Foundation

/// The dictionary applied to transcripts that already exist.
///
/// ## Why this is the one exception to "the dictionary rewrites what goes into
/// the library"
///
/// That sentence is still the rule for everything automatic: `Pipeline.run` is
/// the only place the list runs unasked, and a bare `listen transcribe` still
/// prints what the model actually said. This is the one deliberate pass over
/// what is *already* in the library, and it is a pass somebody asks for by name,
/// looks at first, and then applies. Never at launch, never as a side effect of
/// adding a rule.
///
/// The reason it earns the exception is that the alternative was worse. A rule
/// added today fixes the meeting you record tomorrow and leaves every meeting
/// where you first noticed the mistake spelled wrong for ever, so the archive
/// disagrees with itself, and search for the right spelling misses exactly the
/// conversations that made you add the rule.
///
/// ## What it deliberately does not touch
///
/// Notes, chats and saved answers. Those are the user's own writing, and a
/// dictionary that edited them would be rewriting a person rather than a model.
///
/// ## The two properties that make it safe to run twice
///
/// **Nothing is written where nothing changed.** A plan with no changes is not
/// applied at all, so 65 of 75 recordings keep their file stamps, which keeps
/// their `ContextSource` fingerprints valid and keeps them out of the next sync
/// pass. Measured on the real library: the corrections alone touch 10 of 75.
///
/// **Only real changes are counted.** `CustomDictionary.apply` reports what a
/// rule matched, which is not the same as what it altered: a case-insensitive
/// correction whose replacement still matches its own pattern matches on every
/// pass for ever. So the counts a backfill adds to `StoredTranscript.dictionary`
/// come from comparing the segment before and after, and a second run over an
/// unchanged library adds nothing to any total.
enum DictionaryBackfill {

    /// One rewritten sentence.
    struct Change {
        /// Position in `StoredTranscript.segments`, which is how the write
        /// names it, and what makes the write a compare-and-swap.
        var index: Int
        var before: String
        var after: String
    }

    /// What one recording would gain, or has gained.
    struct Plan {
        var recording: Recording
        var changes: [Change]
        /// Only the rules that actually altered text, counted per rule.
        var fired: [String: Int]

        var isEmpty: Bool { changes.isEmpty }
    }

    // -----------------------------------------------------------------------
    // Planning
    // -----------------------------------------------------------------------

    /// What `entries` would do to one recording, without writing anything.
    ///
    /// Per segment, not over the transcript joined up, because that is the unit
    /// `Pipeline` applies the list to: a segment is one ASR sentence, so every
    /// real term sits inside one, and matching over a join would let a rule
    /// close a gap across a sentence boundary that was never spoken as a phrase.
    ///
    /// The whole entry list is passed in by the caller rather than loaded here,
    /// for the reason `Pipeline` loads once: a thousand-segment transcript would
    /// otherwise be a thousand reads of the same file, and the sheet's preview
    /// deliberately passes only the rule being added so the number it shows is
    /// that rule's own work rather than the whole dictionary's.
    static func plan(for recording: Recording,
                     entries: [CustomDictionary.Entry]) -> Plan {
        guard !entries.isEmpty, let transcript = recording.storedTranscript else {
            return Plan(recording: recording, changes: [], fired: [:])
        }

        var changes: [Change] = []
        var fired: [String: Int] = [:]
        for (index, segment) in transcript.segments.enumerated() {
            let applied = CustomDictionary.apply(to: segment.text, entries: entries)
            guard applied.text != segment.text else { continue }
            changes.append(Change(index: index, before: segment.text, after: applied.text))
            CustomDictionary.combine(applied.fired, into: &fired)
        }
        return Plan(recording: recording, changes: changes, fired: fired)
    }

    /// Every recording `entries` would change, in library order.
    ///
    /// Recordings with nothing to change are dropped rather than returned empty,
    /// so a caller counting plans is counting recordings it would touch.
    static func preview(_ entries: [CustomDictionary.Entry],
                        in library: [Recording]? = nil) -> [Plan] {
        let enabled = entries.filter(\.enabled)
        guard !enabled.isEmpty else { return [] }
        return (library ?? Recording.all())
            .filter(\.hasTranscript)
            .map { plan(for: $0, entries: enabled) }
            .filter { !$0.isEmpty }
    }

    // -----------------------------------------------------------------------
    // Writing
    // -----------------------------------------------------------------------

    /// Apply one plan, or refuse it whole.
    ///
    /// Through `TranscriptEditor`, which is what rebuilds `turns.json` from the
    /// segments, keeps the two writes atomic and in the right order, and settles
    /// the recording's state and title afterwards. A second writer here would
    /// agree with that one right up until it did not.
    ///
    /// **`backup: false`, and it is a decision rather than an omission.** The
    /// `.raw.json.bak` is how `Recording.hasHumanEdits` knows a person corrected
    /// this transcript, which is what makes Transcribe Again ask before throwing
    /// the corrections away. A dictionary rewrite is not a human correction: it
    /// is what the pipeline would have written if the rule had existed then, and
    /// re-transcribing re-applies the list anyway, so nothing is lost by not
    /// warning about it. Backing up here would make every recording a backfill
    /// touched warn for ever about work nobody did, which is the same mistake
    /// `VoiceBank.autoAssign` avoids by passing the same flag.
    ///
    /// What stands in for the backup is the dry run: this is only reached after
    /// somebody has read the `before -> after` lines it came from.
    @discardableResult
    static func apply(_ plan: Plan) -> Bool {
        guard !plan.isEmpty else { return false }
        let edits = plan.changes.map { (index: $0.index, was: $0.before, to: $0.after) }
        return TranscriptEditor.apply(.rewrite(edits, counts: plan.fired),
                                      to: plan.recording, backup: false)
    }

    // -----------------------------------------------------------------------
    // Saying what it would do
    // -----------------------------------------------------------------------

    /// "18 sentences in 4 recordings", the phrase both the CLI and the sheet
    /// use so they cannot describe the same plan differently.
    static func summary(_ plans: [Plan]) -> String {
        let sentences = plans.reduce(0) { $0 + $1.changes.count }
        return "\(sentences) \(sentences == 1 ? "sentence" : "sentences") in "
            + "\(plans.count) \(plans.count == 1 ? "recording" : "recordings")"
    }

    /// One change as a line, with just enough of the sentence around the edit to
    /// recognise it.
    ///
    /// The window rather than the whole sentence, because a dry run over a
    /// library prints one of these per rewritten sentence and a meeting sentence
    /// runs to three lines of terminal. The changed words are found by walking in
    /// from both ends, which is the same thing a reader does.
    static func excerpt(_ change: Change, width: Int = 36) -> String {
        let before = Array(change.before)
        let after = Array(change.after)
        var head = 0
        while head < before.count, head < after.count, before[head] == after[head] {
            head += 1
        }
        var tail = 0
        while tail < before.count - head, tail < after.count - head,
              before[before.count - 1 - tail] == after[after.count - 1 - tail] {
            tail += 1
        }
        // Back up to a word boundary on the left, so the excerpt does not start
        // in the middle of the word that changed.
        while head > 0, before[head - 1] != " " { head -= 1 }
        while tail > 0, tail < before.count - head,
              before[before.count - tail] != " " { tail -= 1 }

        func window(_ s: [Character]) -> String {
            let lead = max(0, head - width / 2)
            let trail = min(s.count, s.count - tail + width / 2)
            guard lead < trail else { return String(s) }
            return (lead > 0 ? "…" : "") + String(s[lead..<trail])
                + (trail < s.count ? "…" : "")
        }
        return window(before) + "  ->  " + window(after)
    }
}
