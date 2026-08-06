import AppKit

/// Markdown, drawn.
///
/// Hand-rolled at the block level and Foundation's at the inline level, which is
/// the split that matters. `NSAttributedString(markdown:)` on a whole document
/// parses the structure and then throws it away: headings come back as plain
/// paragraphs, list items lose their bullets, and a table comes back as its
/// cells run together. A note whose headings and bullets have gone is less
/// readable than the raw file, and the raw file is the thing on disk, so
/// rendering has to earn its place by being better than showing the source.
///
/// So blocks are handled here, line by line, and every line's inline markup goes
/// through Foundation with `.inlineOnlyPreservingWhitespace`. That keeps bold,
/// italic, code and links exactly right without a second parser to be wrong in
/// its own way, and it means this file only knows about headings, bullets,
/// tables and rules.
///
/// Not a general markdown renderer, and it should not become one. It renders
/// what notes contain.
enum MarkdownText {
    /// `without` drops a leading top-level heading that repeats it.
    ///
    /// An agent asked for "Decisions" writes `# Decisions` as the first line,
    /// which is correct in a markdown file somebody may open in an editor and
    /// wrong on a pane whose own title is two lines above it. The file keeps
    /// the heading; the reader does not see it twice. Only the *first* block,
    /// and only when it matches: a note whose second section happens to share
    /// the title still shows it.
    static func attributed(_ markdown: String, without title: String? = nil,
                           width base: CGFloat = 13) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var lines = markdown.components(separatedBy: "\n")
        var index = 0

        if let title {
            let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            while let first = lines.first,
                  first.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
            if let first = lines.first {
                let bare = first.trimmingCharacters(in: .whitespaces)
                if bare.hasPrefix("# "),
                   bare.dropFirst(2).trimmingCharacters(in: .whitespaces)
                       .lowercased() == wanted {
                    lines.removeFirst()
                }
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { index += 1; continue }

            // A run of table lines is one block, so it has to be collected
            // before anything else looks at the line.
            if trimmed.hasPrefix("|") {
                var rows: [String] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                out.append(table(rows, size: base))
                continue
            }
            index += 1

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                let text = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                // Only three sizes, because a note with an h4 in it is a note
                // that wants to be a document and this is a pane.
                let size = [base + 7, base + 2, base][min(hashes, 3) - 1]
                out.append(paragraph(text,
                                     font: .systemFont(ofSize: size, weight: .semibold),
                                     colour: .labelColor,
                                     spacingBefore: out.length == 0 ? 0 : 14,
                                     spacingAfter: 6))
                continue
            }

            // A rule becomes space rather than a line. There is no honest way to
            // draw a full-width rule in a text view whose width is not known
            // here, and a short one reads as a typo.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                out.append(NSAttributedString(string: "\n"))
                continue
            }

            // A list item runs on the same way a paragraph does. Everything
            // that writes these notes hard-wraps, so a two-line bullet arrives
            // as `- text` followed by an indented continuation, and rendering
            // that continuation as its own paragraph put the second half of a
            // sentence back at the left margin under the bullet.
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                out.append(item(marker: "•",
                                runOn(String(trimmed.dropFirst(2)), lines, &index),
                                size: base))
                continue
            }

            if let dot = orderedMarker(trimmed) {
                out.append(item(marker: String(trimmed.prefix(dot)),
                                runOn(String(trimmed.dropFirst(dot + 1))
                                          .trimmingCharacters(in: .whitespaces),
                                      lines, &index),
                                size: base))
                continue
            }

            if trimmed.hasPrefix("> ") {
                out.append(paragraph(runOn(String(trimmed.dropFirst(2)), lines, &index),
                                     font: .systemFont(ofSize: base),
                                     colour: .secondaryLabelColor,
                                     spacingBefore: 0, spacingAfter: 8, indent: 14))
                continue
            }

            // A paragraph runs to the next blank line or the next block, which
            // is markdown's own rule and not a nicety: everything that writes
            // these notes hard-wraps its prose, and rendering each source line
            // as its own paragraph turned one sentence into two half-sentences
            // with a gap down the middle of it.
            out.append(paragraph(runOn(trimmed, lines, &index),
                                 font: .systemFont(ofSize: base),
                                 colour: .labelColor,
                                 spacingBefore: 0, spacingAfter: 8))
        }
        return out
    }

    /// Take the following wrapped lines into this block.
    ///
    /// One rule for paragraphs, list items and quotes, because markdown has one
    /// rule: a block runs to the next blank line or the next block. Having it
    /// only for paragraphs is what left half a bullet stranded at the margin.
    private static func runOn(_ first: String, _ lines: [String],
                              _ index: inout Int) -> String {
        var body = [first]
        while index < lines.count {
            let next = lines[index].trimmingCharacters(in: .whitespaces)
            guard !next.isEmpty, !startsBlock(next) else { break }
            body.append(next)
            index += 1
        }
        return body.joined(separator: " ")
    }

    /// Does this line begin a block of its own, and therefore end a paragraph?
    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("* ")
            || line.hasPrefix("> ") || line.hasPrefix("|")
            || line == "---" || line == "***" || line == "___"
            || orderedMarker(line) != nil
    }

    /// The length of a `1.` or `1)` marker, or nil when the line is not one.
    private static func orderedMarker(_ line: String) -> Int? {
        let digits = line.prefix(while: \.isNumber).count
        guard digits > 0, digits < line.count else { return nil }
        let after = line.index(line.startIndex, offsetBy: digits)
        guard line[after] == "." || line[after] == ")" else { return nil }
        let rest = line.index(after: after)
        guard rest < line.endIndex, line[rest] == " " else { return nil }
        return digits + 1
    }

    // MARK: - Blocks

    private static func paragraph(_ text: String, font: NSFont, colour: NSColor,
                                  spacingBefore: CGFloat, spacingAfter: CGFloat,
                                  indent: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.lineSpacing = 2
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        let out = NSMutableAttributedString(attributedString: inline(text, font: font,
                                                                    colour: colour))
        out.append(NSAttributedString(string: "\n"))
        out.addAttribute(.paragraphStyle, value: style,
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    /// One list item, bulleted or numbered.
    ///
    /// Numbered items keep the number they were written with rather than being
    /// counted here. A note is markdown on disk that somebody may edit in
    /// another editor, and renumbering it on screen would mean the file and the
    /// pane disagree about what item 3 is.
    private static func item(marker: String, _ text: String,
                             size: CGFloat) -> NSAttributedString {
        let indent: CGFloat = marker.count > 1 ? 22 : 16
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 5
        style.lineSpacing = 2
        style.firstLineHeadIndent = 2
        // The hanging indent is the whole point of doing this by hand. Without
        // it the second line of an item starts under the marker, and a list of
        // two-line items stops looking like a list.
        style.headIndent = indent
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]

        let out = NSMutableAttributedString(string: marker + "\t")
        out.addAttributes([.font: NSFont.systemFont(ofSize: size),
                           .foregroundColor: NSColor.secondaryLabelColor],
                          range: NSRange(location: 0, length: out.length))
        out.append(inline(text, font: .systemFont(ofSize: size), colour: .labelColor))
        out.append(NSAttributedString(string: "\n"))
        out.addAttribute(.paragraphStyle, value: style,
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    /// A pipe table, as aligned monospaced text.
    ///
    /// Monospaced and padded rather than laid out with tab stops, because the
    /// column widths are known here and the pane's width is not: a tab stop set
    /// from a guess is a table that comes apart when somebody drags the
    /// divider. This is what a terminal does with the same data.
    private static func table(_ rows: [String], size: CGFloat) -> NSAttributedString {
        let parsed: [[String]] = rows.compactMap { row in
            var cells = row.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // A pipe table is fenced on both sides, so the split leaves an empty
            // cell at each end that is not a column.
            if cells.first?.isEmpty == true { cells.removeFirst() }
            if cells.last?.isEmpty == true { cells.removeLast() }
            // The alignment row is punctuation, not data.
            let isRule = !cells.isEmpty && cells.allSatisfy {
                !$0.isEmpty && $0.allSatisfy { c in c == "-" || c == ":" }
            }
            return isRule || cells.isEmpty ? nil : cells
        }
        guard !parsed.isEmpty else { return NSAttributedString() }

        let columns = parsed.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columns)
        for row in parsed {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }

        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 2
        let out = NSMutableAttributedString()
        for (index, row) in parsed.enumerated() {
            var text = ""
            for (i, cell) in row.enumerated() {
                text += cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
                if i < row.count - 1 { text += "   " }
            }
            let font = NSFont.monospacedSystemFont(
                ofSize: size - 1, weight: index == 0 ? .semibold : .regular)
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font,
                .foregroundColor: index == 0 ? NSColor.secondaryLabelColor
                                             : NSColor.labelColor,
                .paragraphStyle: style,
            ]))
        }
        out.append(NSAttributedString(string: "\n"))
        return out
    }

    // MARK: - Inline

    /// Bold, italic, code and links, from Foundation's own parser.
    ///
    /// The intents come back as an attribute rather than as fonts, which is what
    /// makes this composable: the caller's font is applied first and the traits
    /// are added on top, so a bold word inside a heading is a bold heading
    /// rather than body text.
    private static func inline(_ text: String, font: NSFont,
                               colour: NSColor) -> NSAttributedString {
        let source = (try? NSAttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? NSAttributedString(string: text)
        let out = NSMutableAttributedString(attributedString: source)
        let whole = NSRange(location: 0, length: out.length)
        out.addAttributes([.font: font, .foregroundColor: colour], range: whole)

        out.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            // Stored as an NSNumber of the option set's raw value, which is
            // UInt. Reading it as Int and converting is what keeps this working
            // whichever way the bridge hands it over.
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                out.addAttribute(.font, value: NSFont.monospacedSystemFont(
                    ofSize: font.pointSize - 1, weight: .regular), range: range)
                out.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                 range: range)
                return
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            guard !traits.isEmpty else { return }
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
            if let styled = NSFont(descriptor: descriptor, size: font.pointSize) {
                out.addAttribute(.font, value: styled, range: range)
            }
        }
        return out
    }
}
