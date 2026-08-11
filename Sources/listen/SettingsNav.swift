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

    /// Where the first group heading starts, measured from the top of the
    /// sidebar.
    ///
    /// The heading and the way out are both in the title bar now, so this list
    /// begins where the other collections' segmented control does: 42 points
    /// down, clear of the traffic lights. There is no search field over it,
    /// because nine sections in four groups is a list you scan, and a field
    /// there would be a control that exists to be symmetrical with the other
    /// sidebar.
    private static let listTop: CGFloat = 42

    override func loadView() {
        let container = NSView()

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

        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor,
                                        constant: Self.listTop),
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

    /// Redraw the rows, for the badge.
    ///
    /// The selection is put back by hand: `reloadData` drops it, and a settings
    /// sidebar that deselects itself while somebody is reading the pane it
    /// selected looks like the window lost its place.
    func refreshBadges() {
        guard isViewLoaded, !reloading else { return }
        // **Only when the answer changed, and this is what makes it safe.**
        //
        // The `reloading` flag below is not enough on its own: restoring the
        // selection posts `tableViewSelectionDidChange`, AppKit does not
        // guarantee to post it synchronously, and one that arrives after the
        // flag has been cleared calls `onSelect`, which shows the pane, which
        // calls `refresh`, which asks for the badges again. That loop hung the
        // app on the first draw with no window and no output, and it survived
        // the flag.
        //
        // Comparing state terminates it whatever the notification does: the
        // second time round nothing has changed, so there is no second reload.
        let blocked = PermissionsSummary.blocked
        guard blocked != lastBadge else { return }
        lastBadge = blocked

        reloading = true
        defer { reloading = false }
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0 {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
    }

    /// Set while `refreshBadges` is putting the selection back.
    ///
    /// Without it this hangs the app on the first draw, and the loop is short
    /// enough to be worth spelling out: restoring the selection posts
    /// `tableViewSelectionDidChange`, which calls `onSelect`, which shows the
    /// pane, which calls `refresh`, which asks for the badges again. Measured by
    /// a preview launch that produced no window and no output at all.
    ///
    /// Guarding the notification rather than skipping the reselect, because the
    /// selection genuinely has to come back: `reloadData` drops it, and a
    /// settings sidebar that deselects itself while somebody reads the pane it
    /// selected looks like the window lost its place.
    private var reloading = false

    /// What the badge last showed. nil until the first row is built, so the
    /// first `refreshBadges` after launch does not redraw a table that already
    /// drew the right thing.
    private var lastBadge: Bool?

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
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            // A warning on the Permissions row when something switched on does
            // not work.
            //
            // The pane says so too, but only once you are in it, and the state
            // this exists for is the one nobody goes looking for: dictation
            // enabled with no Accessibility grant, where the shortcut is silent
            // and there is nothing anywhere to say why. A permissions screen you
            // have to think to open is a permissions screen that answers the
            // question too late.
            //
            // Only on Permissions, and only for a real fault. `blocked` excludes
            // the calendar and excludes Accessibility while dictation is off,
            // because a dot that means "you declined something optional" is a
            // dot people learn to ignore, and then it cannot mean anything else.
            let blocked = tab == .permissions ? PermissionsSummary.blocked : false
            if tab == .permissions { lastBadge = blocked }
            if blocked {
                let badge = NSImageView()
                badge.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                      accessibilityDescription: "Needs attention")
                badge.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
                badge.contentTintColor = .systemOrange
                badge.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(badge)
                NSLayoutConstraint.activate([
                    badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor,
                                                    constant: -8),
                    badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor,
                                                    constant: -6),
                ])
            } else {
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor,
                                                constant: -6).isActive = true
            }
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // A reload putting the selection back is not somebody choosing a
        // section. See `reloading`.
        guard !reloading else { return }
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
