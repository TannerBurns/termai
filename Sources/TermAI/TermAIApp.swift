import SwiftUI
import AppKit

// Global configuration for verbose agent logging
struct AgentDebugConfig {
    static var verboseLogging: Bool = {
        // Check for --verbose flag in command line arguments
        return CommandLine.arguments.contains("--verbose") || 
               ProcessInfo.processInfo.environment["TERMAI_VERBOSE"] != nil
    }()
    
    static func log(_ message: String) {
        #if DEBUG
        if verboseLogging {
            print(message)
        }
        #endif
    }
}

@main
struct TermAIApp: App {
    @StateObject private var tabsStore = TabsStore()
    @State private var showSettings: Bool = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(tabsStore)
                .onAppear {
                    // Connect TabsStore to AppDelegate for cleanup
                    appDelegate.tabsStore = tabsStore
                    
                    // Setup notification observers (stored in AppDelegate for cleanup)
                    appDelegate.setupNotificationObservers(tabsStore: tabsStore)
                }
        }
        .windowStyle(.titleBar)
        .commands {
            AppCommands(tabsStore: tabsStore)
        }

        Settings {
            if let selectedTab = tabsStore.selected,
               let selectedSession = selectedTab.chatTabsManager.selectedSession {
                SettingsRootView(
                    selectedSession: selectedSession,
                    ptyModel: selectedTab.ptyModel
                )
            } else {
                Text("No tab selected")
                    .frame(width: 400, height: 300)
            }
        }
    }
}

// MARK: - Main Content View
struct MainContentView: View {
    @EnvironmentObject var tabsStore: TabsStore
    
    var body: some View {
        VStack(spacing: 0) {
            // Top-level app tab bar
            AppTabBar()
            
            Divider()
            
            // Keep ALL tab content views alive, only show selected one
            // This preserves terminal state (running processes) when switching tabs
            ZStack {
                ForEach(tabsStore.tabs) { tab in
                    AppTabContentView(tab: tab)
                        .opacity(tab.id == tabsStore.selectedId ? 1 : 0)
                        .allowsHitTesting(tab.id == tabsStore.selectedId)
                }
            }
        }
        .frame(minWidth: 1024, minHeight: 680)
    }
}

// MARK: - App Tab Bar (Top-Level)
struct AppTabBar: View {
    @EnvironmentObject var tabsStore: TabsStore
    @State private var hoveredTabId: UUID?
    
    var body: some View {
        HStack(spacing: 0) {
            // Tab pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabsStore.tabs) { tab in
                        AppTabPill(
                            tab: tab,
                            isSelected: tab.id == tabsStore.selectedId,
                            isHovered: tab.id == hoveredTabId,
                            onSelect: { tabsStore.selectTab(id: tab.id) },
                            onClose: { tabsStore.closeTab(id: tab.id) }
                        )
                        .onHover { hovering in
                            hoveredTabId = hovering ? tab.id : nil
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            
            Spacer()
            
            // New tab button
            Button(action: { tabsStore.addTab(copySettingsFrom: tabsStore.selected) }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            .padding(.trailing, 8)
        }
        .frame(height: 36)
        .background(.bar)
    }
}

// MARK: - App Tab Pill
struct AppTabPill: View {
    @ObservedObject var tab: AppTab
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    
    @State private var closeHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 4) {
            // Tab icon
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundColor(isSelected ? .accentColor : .secondary)
            
            // Tab title
            Text(displayTitle)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .foregroundColor(isSelected ? .primary : .secondary)
            
            // Close button (visible on hover or selection)
            if isSelected || isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(closeHovered ? .primary : .secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(closeHovered ? Color.primary.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { closeHovered = $0 }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
    
    private var displayTitle: String {
        // Use the chat session title if available, otherwise use tab title
        if let chatTitle = tab.selectedChatSession?.sessionTitle, !chatTitle.isEmpty {
            return chatTitle
        }
        return tab.title
    }
}

// MARK: - Per-Tab Content View
struct AppTabContentView: View {
    @ObservedObject var tab: AppTab
    @State private var showChat: Bool = true
    @State private var chatWidthRatio: CGFloat = 0.35  // Chat takes 35% by default
    @State private var isDragging: Bool = false
    
    private let minChatWidth: CGFloat = 380
    private let minTerminalWidth: CGFloat = 400
    
    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let chatWidth = showChat ? max(totalWidth * chatWidthRatio, minChatWidth) : 0
            let terminalWidth = showChat ? max(totalWidth - chatWidth, minTerminalWidth) : totalWidth
            
            HStack(spacing: 0) {
                // Terminal pane (owned by this tab)
                TerminalPane(
                    onAddToChat: { text, meta in
                        var enriched = meta
                        enriched?.cwd = tab.ptyModel.currentWorkingDirectory
                        tab.chatTabsManager.selectedSession?.setPendingTerminalContext(text, meta: enriched)
                    },
                    onToggleChat: { showChat.toggle() }
                )
                .environmentObject(tab.ptyModel)
                .frame(width: terminalWidth)
                
                // Resizable divider and chat pane
                if showChat {
                    // Draggable divider
                    ResizableDivider(isDragging: $isDragging)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    isDragging = true
                                    let newChatWidth = totalWidth - value.location.x
                                    let clampedWidth = max(minChatWidth, min(newChatWidth, totalWidth - minTerminalWidth))
                                    chatWidthRatio = clampedWidth / totalWidth
                                }
                                .onEnded { _ in
                                    isDragging = false
                                }
                        )
                    
                    ChatContainerView(ptyModel: tab.ptyModel)
                        .environmentObject(tab.chatTabsManager)
                        .frame(width: chatWidth)
                }
            }
        }
    }
}

// MARK: - Resizable Divider
struct ResizableDivider: View {
    @Binding var isDragging: Bool
    @State private var isHovered: Bool = false
    
    var body: some View {
        Rectangle()
            .fill(isDragging || isHovered ? Color.accentColor.opacity(0.6) : Color.clear)
            .frame(width: isDragging || isHovered ? 4 : 1)
            .background(Color.primary.opacity(0.1))
            .overlay(
                // Drag handle indicator
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(Color.secondary.opacity(isDragging || isHovered ? 0.8 : 0.3))
                            .frame(width: 4, height: 4)
                    }
                }
                .opacity(isDragging || isHovered ? 1 : 0)
            )
            .contentShape(Rectangle().size(width: 12, height: .infinity))
            .onHover { isHovered = $0 }
            .cursor(NSCursor.resizeLeftRight)
            .animation(.easeInOut(duration: 0.15), value: isDragging)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// Helper to change cursor
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    weak var tabsStore: TabsStore?
    private var notificationObservers: [NSObjectProtocol] = []
    
    func setupNotificationObservers(tabsStore: TabsStore) {
        // Remove any existing observers
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        
        // Gate caret blinking based on app active state
        let activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak tabsStore] _ in
            Task { @MainActor in
                tabsStore?.selected?.ptyModel.setCaretBlinkingEnabled(true)
            }
        }
        notificationObservers.append(activeObserver)
        
        let resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak tabsStore] _ in
            Task { @MainActor in
                tabsStore?.selected?.ptyModel.setCaretBlinkingEnabled(false)
            }
        }
        notificationObservers.append(resignObserver)
        
        // Observe agent command execution requests
        let commandObserver = NotificationCenter.default.addObserver(
            forName: .TermAIExecuteCommand,
            object: nil,
            queue: .main
        ) { [weak tabsStore] note in
            Task { @MainActor in
                guard let cmd = note.userInfo?["command"] as? String,
                      let ptyModel = tabsStore?.selected?.ptyModel else { return }
                // Emit exit code and true physical cwd so agent always knows final location
                let wrapped = "{ \(cmd) ; RC=$?; echo __TERMAI_RC__=$RC; printf '__TERMAI_CWD__=%s\\n' \"$(pwd -P)\"; }"
                // Store the original command for echo trimming, not the wrapped version
                ptyModel.lastSentCommandForCapture = cmd
                // Mark capture active during command execution
                ptyModel.captureActive = true
                ptyModel.markNextOutputStart?()
                ptyModel.sendInput?(wrapped + "\n")
            }
        }
        notificationObservers.append(commandObserver)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        // Set Dock/app icon with proper macOS-style rounded rect background
        let dockIcon: NSImage? = {
            // Load the original icon
            let originalIcon: NSImage? = {
                if let url = Bundle.module.url(forResource: "termAIDock", withExtension: "png", subdirectory: "Resources"),
                   let img = NSImage(contentsOf: url) {
                    return img
                }
                if let url = Bundle.main.url(forResource: "termAIDock", withExtension: "png"),
                   let img = NSImage(contentsOf: url) {
                    return img
                }
                return nil
            }()
            
            guard let original = originalIcon else { return nil }
            
            // Standard macOS app icon canvas size
            let canvasSize: CGFloat = 1024
            let iconSize = NSSize(width: canvasSize, height: canvasSize)
            
            // macOS icons have ~10% padding on each side (icon is ~80% of canvas)
            let padding: CGFloat = canvasSize * 0.10
            let visibleSize = canvasSize - (padding * 2)
            let iconRect = NSRect(x: padding, y: padding, width: visibleSize, height: visibleSize)
            
            // macOS uses ~22.37% corner radius relative to the visible icon size
            let cornerRadius = visibleSize * 0.2237
            
            let finalIcon = NSImage(size: iconSize, flipped: false) { fullRect in
                // Create the rounded rect path for the visible icon area
                let path = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
                
                // Fill with white background
                NSColor.white.setFill()
                path.fill()
                
                // Clip to the rounded rect and draw the icon
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                original.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
                
                return true
            }
            
            return finalIcon
        }()
        
        if let icon = dockIcon {
            NSApp.applicationIconImage = icon
        }
        setupStatusItem()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Remove notification observers
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        
        // Save all sessions before app quits
        tabsStore?.saveAllSessions()
        
        // Cleanup all tabs
        tabsStore?.tabs.forEach { $0.cleanup() }
    }

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.title = ""
            // Use termAIDock icon as monochrome template for menu bar
            let originalIcon: NSImage? = {
                // Try termAIDock.png from module bundle
                if let url = Bundle.module.url(forResource: "termAIDock", withExtension: "png", subdirectory: "Resources"),
                   let img = NSImage(contentsOf: url) {
                    return img
                }
                // Try from main bundle
                if let url = Bundle.main.url(forResource: "termAIDock", withExtension: "png"),
                   let img = NSImage(contentsOf: url) {
                    return img
                }
                return nil
            }()
            
            if let original = originalIcon {
                // Create a monochrome template version at menu bar size
                let size = NSSize(width: 18, height: 18)
                let templateIcon = NSImage(size: size, flipped: false) { rect in
                    original.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                    return true
                }
                templateIcon.isTemplate = true
                btn.image = templateIcon
                btn.imagePosition = .imageOnly
            }
        }
        
        // Setup menu
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
    
    private func findIcon(named name: String) -> NSImage? {
        // Try SPM module bundle with Resources subdirectory
        if let url = Bundle.module.url(forResource: name, withExtension: "icns", subdirectory: "Resources"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        // Try main bundle
        if let url = Bundle.main.url(forResource: name, withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        // Try main bundle Resources subdirectory
        if let url = Bundle.main.url(forResource: name, withExtension: "icns", subdirectory: "Resources"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }
    
    private func findPNG(named name: String) -> NSImage? {
        if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Update provider and model info from selected tab's session
        if let session = tabsStore?.selected?.chatTabsManager.selectedSession {
            menu.item(withTag: 1001)?.title = "Provider: \(session.providerName)"
            menu.item(withTag: 1002)?.title = "Model: \(session.model)"
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
