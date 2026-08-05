import AppKit

/// The settings section list, which stands in for the recording list while the
/// window is in settings mode.
///
/// Built the same way as `SidebarViewController` on purpose: same table style,
/// same clear background, same group-row treatment, and a header at the same
/// 44 points from the top as the search field it replaces. Two sidebars that
/// share a shape read as one component swapping its contents; two that do not
/// read as two applications, and the whole point of folding settings into this
/// window was to stop it looking like a second application.
@MainActor
final class SettingsNavViewController: NSViewController {
    private var table: NSTableView!

    /// Group headings and sections in one list, because that is what the table
    /// draws. `isGroupRow` picks them apart, exactly as the day headings do.
    private enum Row {
        case group(SettingsGroup)
        case section(SettingsTab)
    }

    private let rows: [Row] = SettingsGroup.allCases.flatMap { group in
        [Row.group(group)] + group.tabs.map { Row.section($0) }
    }

    var onSelect: ((SettingsTab) -> Void)?

    private(set) var selectedTab: SettingsTab = .general

    override func loadView() {
        let container = NSView()

        // A label rather than a search field. Nine sections in four groups is a
        // list you scan, and a search field over it would be a control that
        // exists to be symmetrical with the other sidebar.
        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 28
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.delegate = self
        table.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            // Clear of the traffic lights, and level with the search field on
            // the other side of the swap.
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                            constant: -10),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        select(selectedTab)
    }

    /// Select a section, without calling back. The caller is the one asking.
    func select(_ tab: SettingsTab) {
        loadViewIfNeeded()
        selectedTab = tab
        guard let row = rows.firstIndex(where: {
            if case .section(let t) = $0 { return t == tab }
            return false
        }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// Put the keyboard on the list, so the arrow keys move between sections
    /// rather than doing nothing.
    func focusList() {
        view.window?.makeFirstResponder(table)
    }
}

// MARK: - The table

extension SettingsNavViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return 30 }
        return 28
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .group = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        switch rows[row] {
        case .group(let group):
            // The same treatment as the library's day headings, because they
            // are the same thing: a word that organises the rows under it.
            let label = NSTextField(labelWithString: group.title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            let holder = NSView()
            holder.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -4),
            ])
            return holder

        case .section(let tab):
            // A real `NSTableCellView`, unlike the library's bare-view rows.
            // It tracks `backgroundStyle`, which is what turns the symbol and
            // the label white on the selected row without anyone maintaining a
            // second set of colours that only looks right in one appearance.
            let cell = NSTableCellView()

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: tab.symbol,
                                 accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: tab.title)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor,
                                                constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard case .section(let tab) = rows[safe: table.selectedRow] else { return }
        selectedTab = tab
        onSelect?(tab)
    }
}

private extension Array {
    /// `selectedRow` is -1 when nothing is selected, which is a valid answer and
    /// not a reason to trap.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
