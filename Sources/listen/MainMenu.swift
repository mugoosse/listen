import AppKit

/// The menu bar menus.
///
/// An app built without a nib gets **no main menu at all**, and the gap is not
/// obvious because the window looks finished. What is missing is every standard
/// keystroke: Cmd-Q does not quit, and Cmd-A, Cmd-C and Cmd-V do nothing in a
/// text field, because those are implemented by menu items with key
/// equivalents rather than by the fields themselves. Renaming a recording was
/// unusable for exactly that reason.
///
/// Everything here targets `nil`, so it goes to the responder chain and lands
/// on whatever is focused. That is what makes Copy work in the search field and
/// the title field without either of them knowing about it.
@MainActor
enum MainMenu {
    /// The one row Ask owns, held so it can be hidden without rebuilding the
    /// menu it is in. See the note where it is built.
    private static weak var chatsItem: NSMenuItem?

    /// Show or hide the Ask row, after `Settings.askEnabled` has changed.
    static func refreshAsk() { chatsItem?.isHidden = !Settings.askEnabled }

    static func install() {
        let main = NSMenu()

        main.addItem(appMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())
        main.addItem(helpMenu())

        NSApp.mainMenu = main
    }

    private static func submenu(_ title: String) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return (item, menu)
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?,
                            _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        return item
    }

    private static func appMenu() -> NSMenuItem {
        let (item, menu) = submenu("Listen")
        add(menu, "About Listen", #selector(MenuActions.showAbout))
            .target = MenuActions.shared
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(MenuActions.openSettings), ",")
            .target = MenuActions.shared
        menu.addItem(.separator())
        add(menu, "Hide Listen", #selector(NSApplication.hide(_:)), "h")
        add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
            [.command, .option])
        add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "Quit Listen", #selector(NSApplication.terminate(_:)), "q")
        return item
    }

    private static func fileMenu() -> NSMenuItem {
        let (item, menu) = submenu("File")
        add(menu, "New Recording", #selector(MenuActions.newRecording), "n")
            .target = MenuActions.shared
        menu.addItem(.separator())
        // Cmd-W, which nothing in this app had. It was survivable while the
        // library window was the only one; About is a second window, and a
        // window that can only be closed by aiming at its corner is a window
        // people leave open. Targets nil so it lands on whatever is key.
        add(menu, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        menu.addItem(.separator())
        // Above Export, because it is the one people go looking for and the
        // one that ends with the meeting somewhere useful. Export is still
        // here: it is the verb that asks *where*, which a share sheet cannot.
        //
        // No key equivalent, and that is the standard: macOS gives Share none
        // anywhere, and the two keys near it here are already taken by Export
        // and Show in Finder.
        add(menu, "Share…", #selector(LibraryWindow.shareSelected))
            .target = LibraryWindow.shared
        // ⇧⌘C rather than ⌘C. Edit's Copy is the responder chain's, and it has
        // to keep working in the title field and the search field; this copies
        // the whole meeting whatever is focused.
        add(menu, "Copy as Markdown", #selector(LibraryWindow.copyMarkdownSelected), "c",
            [.command, .shift])
            .target = LibraryWindow.shared
        add(menu, "Export…", #selector(LibraryWindow.exportSelected), "e")
            .target = LibraryWindow.shared
        add(menu, "Show in Finder", #selector(LibraryWindow.revealSelected), "r")
            .target = LibraryWindow.shared
        menu.addItem(.separator())
        add(menu, "Rename", #selector(LibraryWindow.renameSelected))
            .target = LibraryWindow.shared
        // The keyboard way in, and the only one: a key equivalent is dispatched
        // from the main menu bar, so the copies of this item in the toolbar's
        // ellipsis and the sidebar's right-click menu cannot carry one.
        add(menu, "Tags…", #selector(LibraryWindow.tagSelected), "t")
            .target = LibraryWindow.shared
        let again = add(menu, "Transcribe Again",
                        #selector(LibraryWindow.retranscribeSelected))
        again.target = LibraryWindow.shared
        // The same model list the toolbar's ellipsis and the sidebar's
        // right-click menu carry, and the same instance every time this item is
        // shown, because this item is built once at launch. `LibraryWindow`
        // refills it on open, so the tick follows the selection.
        again.submenu = LibraryWindow.shared.modelMenu
        menu.addItem(.separator())
        // No key equivalent. Delete is irreversible and this is a list people
        // navigate with the keyboard.
        add(menu, "Delete Recording", #selector(LibraryWindow.deleteSelected))
            .target = LibraryWindow.shared
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let (item, menu) = submenu("Edit")
        add(menu, "Undo", Selector(("undo:")), "z")
        add(menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Cut", #selector(NSText.cut(_:)), "x")
        add(menu, "Copy", #selector(NSText.copy(_:)), "c")
        add(menu, "Paste", #selector(NSText.paste(_:)), "v")
        add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())
        // **Cmd-F is the page, not the library.** Every other Mac app spends it
        // on the document in front of you, and the library's field is on screen
        // permanently and one click away, so it is the one that can afford to
        // give up the chord. The pair is Xcode's: this file, and this project.
        //
        // Targeted at `LibraryWindow.shared` explicitly rather than left nil,
        // the way the File menu's recording items are. `LibraryWindow` is an
        // `NSObject` and not an `NSResponder`, so a nil-targeted item reaches it
        // as the window's *delegate* rather than through the view responder
        // chain, and naming the target is what routes these through
        // `validateMenuItem` as well.
        add(menu, "Find in Page…", #selector(LibraryWindow.findInPageSelected), "f")
            .target = LibraryWindow.shared
        add(menu, "Find Next", #selector(LibraryWindow.findNextSelected), "g")
            .target = LibraryWindow.shared
        add(menu, "Find Previous", #selector(LibraryWindow.findPreviousSelected), "g",
            [.command, .shift])
            .target = LibraryWindow.shared
        menu.addItem(.separator())
        // Keeps its `MenuActions` target, because it opens the window when
        // there is not one and a responder chain has nothing in it to reach
        // then.
        add(menu, "Search Library", #selector(MenuActions.focusSearch), "f",
            [.command, .shift])
            .target = MenuActions.shared
        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let (item, menu) = submenu("View")
        // The standard selector, so NSSplitViewController handles it and the
        // toolbar button and this item stay in agreement for free.
        add(menu, "Hide Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)),
            "s", [.command, .control])
        menu.addItem(.separator())
        // Targets nil, so it travels the responder chain to the library window
        // the way the recording items already do. The row above the sidebar's
        // list is the discoverable way in and it is gone once the work is done,
        // which leaves a library with nothing outstanding unable to ask the
        // question at all.
        add(menu, "Recordings Needing a Speaker",
            #selector(LibraryWindow.showUnnamedSpeakers(_:)), "u")
        // The other lens worth a keystroke, and the only route to the roster
        // that is one. See `LibraryWindow.showPeople`.
        add(menu, "People", #selector(LibraryWindow.showPeople(_:)), "p",
            [.command, .shift])
        menu.addItem(.separator())
        // The toolbar's Chats button is on the home page only, and the History
        // menu it shares the slot with is scoped to whatever page you are on, so
        // the Notes collection has no route into the conversations at all. This
        // is that route, and it is the one that works from every mode.
        //
        // A shared target rather than nil, for `openLibrary`'s reason: it opens
        // the window when there is not one, and a responder chain has nothing in
        // it to reach then.
        // Built once and hidden when Ask is off, rather than left out.
        //
        // **`install` may not be called twice.** Rebuilding the row with the
        // feature was the obvious way to do this and it is not safe: measured
        // on the setup card's Not now button, a second `install` either never
        // returned or aborted the process outright, depending only on whether
        // it was called inside the action or deferred to the next turn of the
        // run loop. `NSApp.mainMenu` is replaced here and `NSApp.windowsMenu`
        // with it, and AppKit has been keeping its own window rows in the old
        // one since launch.
        //
        // Hidden rather than disabled, for the reason a greyed row is worse
        // than no row: it promises something would happen under a condition it
        // does not name, and the condition is a checkbox in another window. A
        // hidden item's key equivalent is inert too, and `openChats` guards
        // itself in any case. See `refreshAsk` and `Settings.askEnabled`.
        chatsItem = add(menu, "Chats", #selector(MenuActions.openChats), "0",
                        [.command, .shift])
        chatsItem?.target = MenuActions.shared
        refreshAsk()
        add(menu, "Open Listen", #selector(MenuActions.openLibrary), "0")
            .target = MenuActions.shared
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let (item, menu) = submenu("Window")
        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = menu
        return item
    }

    /// Where a Mac user looks for the website, and where there was nothing.
    ///
    /// The report that produced this menu was somebody unable to find a link to
    /// send to a friend. Help is the first place they looked, and Listen had no
    /// Help menu at all: the menu bar went Listen, File, Edit, View, Window and
    /// stopped. Every item here opens a page except the last, which is the
    /// share sheet, and that is the point of the menu.
    ///
    /// `NSApp.helpMenu` is set so macOS treats it as the Help menu proper,
    /// which is what puts the search field at the top of it.
    private static func helpMenu() -> NSMenuItem {
        let (item, menu) = submenu("Help")
        // First, and on its own. The other five items are about Listen in
        // general; this one is about the copy in front of you, and it is the
        // only answer in the app to what the last update changed.
        add(menu, "Release Notes", #selector(MenuActions.showChangelog))
            .target = MenuActions.shared
        menu.addItem(.separator())
        add(menu, "Listen Documentation", #selector(MenuActions.openDocs))
            .target = MenuActions.shared
        add(menu, "Listen Website", #selector(MenuActions.openWebsite))
            .target = MenuActions.shared
        menu.addItem(.separator())
        add(menu, "Listen on GitHub", #selector(MenuActions.openSource))
            .target = MenuActions.shared
        add(menu, "Report an Issue", #selector(MenuActions.reportIssue))
            .target = MenuActions.shared
        menu.addItem(.separator())
        add(menu, "Share Listen…", #selector(MenuActions.shareListen))
            .target = MenuActions.shared
        NSApp.helpMenu = menu
        return item
    }
}

/// Menu targets that are not the library window's own.
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func openSettings() { LibraryWindow.shared.showSettings() }
    @objc func openLibrary() { LibraryWindow.shared.show() }
    @objc func openChats() { LibraryWindow.shared.openChats() }
    /// The window, not the settings section. See `AboutWindow`.
    @objc func showAbout() { AboutWindow.show() }
    /// The notes that shipped with this build, not the ones on GitHub. See
    /// `Changelog`.
    @objc func showChangelog() { ChangelogWindow.show() }

    @objc func openDocs() { Links.open(Links.docs) }
    @objc func openWebsite() { Links.open(Links.website) }
    @objc func openSource() { Links.open(Links.source) }
    @objc func reportIssue() { Links.open(Links.issues) }
    @objc func shareListen() { Sharing.presentFromMenu() }

    @objc func newRecording() {
        if Capture.shared.isRecording {
            NSApp.sendAction(#selector(App.stopRecordingFromUI), to: nil, from: self)
        } else {
            NSApp.sendAction(#selector(App.startRecordingFromUI), to: nil, from: self)
        }
    }

    @objc func focusSearch() { LibraryWindow.shared.focusSearch() }
}
