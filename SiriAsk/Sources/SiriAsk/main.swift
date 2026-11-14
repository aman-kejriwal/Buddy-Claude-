import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AskModel()
    private var panelController: SiriPanelController?
    private var hotKey: HotKey?
    private let caretAssistant = CaretAssistant()
    private var caretHotKey: HotKey?
    private var fnMonitor: FnHoldMonitor?
    private var statusItem: NSStatusItem?
    private var modelMenu: NSMenu?
    private var modelItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no app menu.
        NSApp.setActivationPolicy(.accessory)
        setupEditMenu()

        let controller = SiriPanelController(model: model)
        panelController = controller

        // Option + Space toggles the panel from anywhere.
        hotKey = HotKey(action: { [weak controller] in controller?.toggle() })
        if hotKey == nil {
            NSLog("SiriAsk: could not register the Option+Space shortcut (another app may own it).")
        }

        // Option + Shift + Space opens a prompt at the text cursor and types the answer there.
        caretHotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey),
                             action: { [weak self] in self?.caretAssistant.trigger() })
        if caretHotKey == nil {
            NSLog("SiriAsk: could not register the Option+Shift+Space shortcut (another app may own it).")
        }

        // Holding fn (Globe) opens the panel straight into voice mode.
        fnMonitor = FnHoldMonitor(onHold: { [weak controller] in controller?.showInVoiceMode() })

        setupStatusItem()

        // Start Claude Code now, in the background, so the first question is fast.
        model.warmUp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// Accessory apps have no visible menu bar, but ⌘C/⌘V/⌘X/⌘A/⌘Z are routed through
    /// the main menu's key equivalents. Without this, paste does nothing in the text field.
    private func setupEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Buddy")

        let menu = NSMenu()
        let askItem = NSMenuItem(title: "Ask…   ⌥Space", action: #selector(showPanel), keyEquivalent: "")
        askItem.target = self
        menu.addItem(askItem)
        let writeItem = NSMenuItem(title: "Write at Cursor   ⌥⇧Space", action: nil, keyEquivalent: "")
        writeItem.isEnabled = false   // informational: the shortcut needs the text cursor in another app
        menu.addItem(writeItem)
        let newItem = NSMenuItem(title: "New Conversation", action: #selector(newConversation), keyEquivalent: "")
        newItem.target = self
        menu.addItem(newItem)
        menu.addItem(.separator())

        // Model picker: a checkmark shows the current one.
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for option in ClaudeModel.allCases {
            let item = NSMenuItem(title: "\(option.displayName)  —  \(option.detail)",
                                  action: #selector(chooseModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            modelMenu.addItem(item)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)
        self.modelMenu = modelMenu
        self.modelItem = modelItem
        refreshModelMenu()
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    @objc private func showPanel() {
        panelController?.show()
    }

    @objc private func newConversation() {
        model.newConversation()
    }

    @objc private func chooseModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = ClaudeModel(rawValue: raw) else { return }
        model.setModel(choice)
        refreshModelMenu()
    }

    /// Puts the checkmark on the current model and shows its name in the parent item.
    private func refreshModelMenu() {
        let current = model.selectedModel
        modelItem?.title = "Model: \(current.displayName)"
        modelMenu?.items.forEach { item in
            item.state = (item.representedObject as? String) == current.rawValue ? .on : .off
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
