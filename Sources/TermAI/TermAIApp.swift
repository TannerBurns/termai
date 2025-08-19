import SwiftUI
import AppKit

@main
struct TermAIApp: App {
    @StateObject private var tabsStore = TabsStore()
    // PTY now used; CommandRunner retained for reference but not injected
    @State private var showSettings: Bool = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tabsStore)
                .focusedSceneValue(\.newTabAction, { tabsStore.addTab(copyFrom: tabsStore.selected) })
                
                .onAppear {
                    tabsStore.selected?.selectedChat.loadSettings()
                    tabsStore.selected?.selectedChat.loadMessages()
                    Task { await tabsStore.selected?.selectedChat.initializeModelsOnStartup() }
                    appDelegate.chat = tabsStore.selected?.selectedChat
                }
        }
        .windowStyle(.titleBar)
        .commands { AppCommands(addNewTab: { tabsStore.addTab(copyFrom: tabsStore.selected) }) }

        Settings {
            SettingsView(showAdvanced: false)
                .environmentObject(tabsStore.selected?.selectedChat ?? ChatViewModel())
                .onDisappear {
                    tabsStore.selected?.selectedChat.persistSettings()
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var tabsStore: TabsStore
    @State private var showChat: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                let desiredChatWidth = totalWidth / 3.0
                let chatWidth = showChat ? max(desiredChatWidth, 420) : 0
                let terminalWidth = showChat ? max(totalWidth - chatWidth, 0) : totalWidth

                HStack(spacing: 0) {
                    Group {
                        if let currentTab = tabsStore.selected {
                            TerminalPane(onAddToChat: { text, meta in
                                var enriched = meta
                                enriched?.cwd = currentTab.ptyModel.currentWorkingDirectory
                                currentTab.selectedChat.setPendingTerminalContext(text, meta: enriched)
                            }, onToggleChat: { showChat.toggle() })
                            .environmentObject(currentTab.ptyModel)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: terminalWidth)

                    if showChat, let currentTab = tabsStore.selected {
                        Divider()
                        VStack(spacing: 0) {
                            ChatPane()
                                .id(currentTab.selectedChat.id)
                                .environmentObject(currentTab.selectedChat)
                                .environmentObject(currentTab)
                                .environmentObject(tabsStore)
                        }
                        .frame(width: chatWidth)
                    }
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onChange(of: tabsStore.selectedId) { _ in
            // Keep status menu in sync with current tab
            NSApp.delegate.flatMap { $0 as? AppDelegate }?.chat = tabsStore.selected?.selectedChat
        }
        // No-op: keyboard shortcut calls tabsStore.addTab directly via menu command
    }
}

// Chat sessions strip is now rendered inside ChatPane

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    weak var chat: ChatViewModel?
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
        guard let chat else { return }
        if let providerItem = menu.items.first(where: { $0.tag == 1001 }) {
            providerItem.title = "Provider: \(chat.providerName)"
        }
        if let modelItem = menu.items.first(where: { $0.tag == 1002 }) {
            modelItem.title = "Model: \(chat.model)"
        }
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


