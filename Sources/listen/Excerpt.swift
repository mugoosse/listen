import AppKit

/// A window of text around a search match, for a row in a list.
///
/// Nothing in this app did this before. `ReferencePopover.snippet` truncates
/// the head of a note and takes no query, `Chat.shorten` is head-anchored and
/// one-sided, and `MCP.search_transcripts` hands back the whole matching turn
/// and leaves the trimming to whoever asked. A result row has neither the width
/// for a whole paragraph nor any use for its first sentence, so this is the
/// first thing here that cuts around a match rather than off the front.
enum Excerpt {
    /// Roughly two lines of 11pt in a 280 point sidebar, measured on the
    /// development library rather than picked: the rows that matched ran
    /// between 74 and 103 characters over two lines, so 90 fills the second
    /// line on most and overflows it on none.
    static let width = 90

    /// The ellipsis both ends use. A real one, not three dots: the row's font
    /// kerns it as a single glyph and three periods eat three characters of
    /// context.
    private static let ellipsis = "…"

    /// A window of `text` around `range`, elided on word boundaries, with the
    /// matched run marked.
    ///
    /// **The match sits in the left third rather than the middle.** What
    /// follows a term is far more often the answer than what precedes it: "the
    /// deadline is" before a date is worth nothing, and the date after it is
    /// the whole reason somebody searched. Centring the window spends half of a
    /// narrow row on the run-up.
    static func around(_ range: NSRange, in text: String,
                       width: Int = Excerpt.width,
                       font: NSFont, colour: NSColor) -> NSAttributedString {
        let full = text as NSString
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        guard range.location != NSNotFound, NSMaxRange(range) <= full.length else {
            return NSAttributedString(string: shorten(text, to: width), attributes: plain)
        }

        // A third of the room in front, the rest behind.
        let before = max(0, width / 3)
        var start = max(0, range.location - before)
        var end = min(full.length, start + width)
        // Ran off the end, so take the slack back off the front rather than
        // returning a window shorter than it needed to be.
        if end == full.length { start = max(0, end - width) }

        start = wordBoundary(in: full, near: start, forward: true)
        end = wordBoundary(in: full, near: end, forward: false)
        // A boundary search that crossed the match itself would cut the thing
        // being shown, which is the one character this must never lose.
        start = min(start, range.location)
        end = max(end, NSMaxRange(range))
        guard start < end else {
            return NSAttributedString(string: shorten(text, to: width), attributes: plain)
        }

        let window = NSRange(location: start, length: end - start)
        let head = start > 0 ? ellipsis : ""
        let tail = end < full.length ? ellipsis : ""
        let out = NSMutableAttributedString(
            string: head + full.substring(with: window) + tail, attributes: plain)
        // Shifted by whatever the leading ellipsis added, and by where the
        // window starts. Getting this wrong marks the wrong word, which looks
        // exactly like a search that matched something else.
        let marked = NSRange(location: range.location - start + (head as NSString).length,
                             length: range.length)
        if NSMaxRange(marked) <= out.length {
            out.addAttribute(.foregroundColor, value: NSColor.labelColor, range: marked)
            out.addAttribute(.font,
                             value: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                             range: marked)
        }
        return out
    }

    /// The nearest space to `index`, within a few characters of it.
    ///
    /// Bounded rather than unbounded: a transcript of a fast talker can run
    /// hundreds of characters without one, and walking to the next space then
    /// throws away most of the window. Past the bound it cuts mid-word, which
    /// the ellipsis already says it did.
    private static func wordBoundary(in text: NSString, near index: Int,
                                     forward: Bool) -> Int {
        guard index > 0, index < text.length else { return index }
        let reach = 12
        for step in 0...reach {
            let at = forward ? index + step : index - step
            guard at > 0, at < text.length else { break }
            let character = text.character(at: at - 1)
            if let scalar = Unicode.Scalar(character),
               CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return at
            }
        }
        return index
    }

    private static func shorten(_ text: String, to width: Int) -> String {
        let flat = text as NSString
        guard flat.length > width else { return text }
        return flat.substring(to: width) + ellipsis
    }
}
