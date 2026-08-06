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
    static func install() {
        let main = NSMenu()

        main.addItem(appMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())

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
        add(menu, "Find", #selector(MenuActions.focusSearch), "f")
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
}

/// Menu targets that are not the library window's own.
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func openSettings() { LibraryWindow.shared.showSettings() }
    @objc func openLibrary() { LibraryWindow.shared.show() }
    @objc func showAbout() { LibraryWindow.shared.showSettings(.about) }

    @objc func newRecording() {
        if Capture.shared.isRecording {
            NSApp.sendAction(#selector(App.stopRecordingFromUI), to: nil, from: self)
        } else {
            NSApp.sendAction(#selector(App.startRecordingFromUI), to: nil, from: self)
        }
    }

    @objc func focusSearch() { LibraryWindow.shared.focusSearch() }
}
