import SwiftUI
import AppKit

@main
struct TermAIApp: App {
    @StateObject private var globalTabsManager = ChatTabsManager()
    @StateObject private var ptyModel = PTYModel()
    @State private var showSettings: Bool = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            SimplifiedContentView(globalTabsManager: globalTabsManager)
                .environmentObject(ptyModel)
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsRootView(
                selectedSession: globalTabsManager.selectedSession,
                ptyModel: ptyModel
            )
        }
    }
}

struct SimplifiedContentView: View {
    @EnvironmentObject var ptyModel: PTYModel
    @ObservedObject var globalTabsManager: ChatTabsManager
    @State private var showChat: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                let desiredChatWidth = totalWidth / 3.0
                let chatWidth = showChat ? max(desiredChatWidth, 420) : 0
                let terminalWidth = showChat ? max(totalWidth - chatWidth, 0) : totalWidth

                HStack(spacing: 0) {
                    // Terminal pane
                    TerminalPane(
                        onAddToChat: { text, meta in
                            var enriched = meta
                            enriched?.cwd = ptyModel.currentWorkingDirectory
                            globalTabsManager.selectedSession?.setPendingTerminalContext(text, meta: enriched)
                        },
                        onToggleChat: { showChat.toggle() }
                    )
                    .environmentObject(ptyModel)
                    .frame(width: terminalWidth)

                    // Chat pane
                    if showChat {
                        Divider()
                        ChatContainerView(ptyModel: ptyModel)
                            .environmentObject(globalTabsManager)
                            .frame(width: chatWidth)
                    }
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }
}

// Chat sessions strip is now rendered inside ChatPane

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    @objc func newGlobalTab(_ sender: Any?) { }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Remove automatic window tabbing adjustments (conflicting API on this SDK)
        // Set Dock/app icon to dedicated Dock asset if available
        if let dockURL = Bundle.main.url(forResource: "termAIDock", withExtension: "icns"),
           let dockIcon = NSImage(contentsOf: dockURL) {
            NSApp.applicationIconImage = dockIcon
        }
        setupStatusItem()
    }

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.title = ""
            // Prefer dedicated toolbar icns, then dock/app icon, then legacy assets
            var iconImage: NSImage? = nil
            if let url = Bundle.main.url(forResource: "termAIToolbar", withExtension: "icns"),
               let img = NSImage(contentsOf: url) {
                iconImage = img
            } else if let url = Bundle.main.url(forResource: "termAIDock", withExtension: "icns"),
                      let img = NSImage(contentsOf: url) {
                iconImage = img
            } else if let url = Bundle.main.url(forResource: "TermAI", withExtension: "icns"),
                      let img = NSImage(contentsOf: url) {
                iconImage = img
            } else if let url = Bundle.main.url(forResource: "termai", withExtension: "png"),
                      let img = NSImage(contentsOf: url) {
                iconImage = img
            } else {
                iconImage = NSApp.applicationIconImage
            }
            if let icon = iconImage {
                icon.isTemplate = false
                icon.size = NSSize(width: 18, height: 18)
                btn.image = icon
                btn.imagePosition = .imageOnly
                btn.imageScaling = .scaleProportionallyDown
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Show TermAI", action: #selector(showApp), keyEquivalent: "")
        menu.addItem(.separator())
        let providerItem = NSMenuItem(title: "Provider: -", action: nil, keyEquivalent: "")
        providerItem.tag = 1001
        providerItem.isEnabled = false
        menu.addItem(providerItem)
        let modelItem = NSMenuItem(title: "Model: -", action: nil, keyEquivalent: "")
        modelItem.tag = 1002
        modelItem.isEnabled = false
        menu.addItem(modelItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        item.menu = menu
        statusMenu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Provider and model info now managed per chat session
    }

    @objc private func showApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        // Open the SwiftUI Settings scene
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            if window.title.contains("Settings") {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        // Fallback: present settings scene by toggling the menu command
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}


