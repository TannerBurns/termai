import SwiftUI
import AppKit

// Global configuration for verbose agent logging
struct AgentDebugConfig {
    static var verboseLogging: Bool {
        // Check settings, command line flag, or environment variable
        return AgentSettings.shared.verboseLogging ||
               CommandLine.arguments.contains("--verbose") || 
               ProcessInfo.processInfo.environment["TERMAI_VERBOSE"] != nil
    }
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    private static var logFileHandle: FileHandle?
    private static var logFilePath: URL?
    
    /// Get the path to the current log file
    static var currentLogPath: String? {
        logFilePath?.path
    }
    
    /// Initialize logging to a file
    static func initializeLogging() {
        guard verboseLogging else { return }
        
        let fileManager = FileManager.default
        let logsDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TermAI/Logs", isDirectory: true)
        
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        // Cleanup old log files (older than 7 days)
        cleanupOldLogs(in: logsDir, olderThanDays: 7)
        
        let dateString = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let logFile = logsDir.appendingPathComponent("agent-\(dateString).log")
        
        fileManager.createFile(atPath: logFile.path, contents: nil)
        logFileHandle = try? FileHandle(forWritingTo: logFile)
        logFilePath = logFile
        
        log("=== TermAI Agent Log Started ===")
        log("Log file: \(logFile.path)")
        log("Settings: maxIterations=\(AgentSettings.shared.maxIterations), enablePlanning=\(AgentSettings.shared.enablePlanning), enableReflection=\(AgentSettings.shared.enableReflection)")
    }
    
    /// Delete log files older than the specified number of days
    private static func cleanupOldLogs(in directory: URL, olderThanDays days: Int) {
        let fileManager = FileManager.default
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        
        for file in files where file.pathExtension == "log" {
            guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                  let creationDate = attributes[.creationDate] as? Date else { continue }
            
            if creationDate < cutoffDate {
                try? fileManager.removeItem(at: file)
            }
        }
    }
    
    static func log(_ message: String) {
        guard verboseLogging else { return }
        
        let timestamp = dateFormatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"
        
        // Print to console
        print(logLine, terminator: "")
        
        // Write to file
        if let data = logLine.data(using: .utf8) {
            logFileHandle?.write(data)
            try? logFileHandle?.synchronize()
        }
    }
    
    /// Close the log file
    static func closeLogging() {
        log("=== TermAI Agent Log Ended ===")
        try? logFileHandle?.close()
        logFileHandle = nil
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
                    // Initialize agent logging if enabled
                    AgentDebugConfig.initializeLogging()
                    
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
                SettingsEmptyStateView()
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
    @State private var terminalWidth: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var dragStartWidth: CGFloat = 0
    
    private let minChatWidth: CGFloat = 380
    private let minTerminalWidth: CGFloat = 400
    private let dividerWidth: CGFloat = 16
    
    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            
            // Initialize terminal width if not set
            let effectiveTerminalWidth: CGFloat = {
                if terminalWidth == 0 {
                    // Default: terminal takes 65% of space
                    return max(minTerminalWidth, (totalWidth - dividerWidth) * 0.65)
                }
                return terminalWidth
            }()
            
            let chatWidth = showChat ? max(minChatWidth, totalWidth - effectiveTerminalWidth - dividerWidth) : 0
            let actualTerminalWidth = showChat ? max(minTerminalWidth, totalWidth - chatWidth - dividerWidth) : totalWidth
            
            HStack(spacing: 0) {
                // Terminal pane (owned by this tab)
                TerminalPane(
                    onAddToChat: { text, meta in
                        var enriched = meta
                        enriched?.cwd = tab.ptyModel.currentWorkingDirectory
                        tab.chatTabsManager.selectedSession?.setPendingTerminalContext(text, meta: enriched)
                    },
                    onToggleChat: { showChat.toggle() },
                    onOpenSettings: {
                        // Open settings via keyboard shortcut simulation
                        if let event = NSEvent.keyEvent(
                            with: .keyDown,
                            location: .zero,
                            modifierFlags: .command,
                            timestamp: 0,
                            windowNumber: 0,
                            context: nil,
                            characters: ",",
                            charactersIgnoringModifiers: ",",
                            isARepeat: false,
                            keyCode: 43
                        ) {
                            NSApp.sendEvent(event)
                        }
                    }
                )
                .environmentObject(tab.ptyModel)
                .environmentObject(tab.suggestionService)
                .frame(width: actualTerminalWidth)
                
                // Resizable divider and chat pane
                if showChat {
                    // Draggable divider
                    ResizableDivider(isDragging: $isDragging)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { value in
                                    if !isDragging {
                                        // Capture starting width when drag begins
                                        isDragging = true
                                        dragStartWidth = actualTerminalWidth
                                    }
                                    // Calculate new terminal width based on drag translation
                                    let newWidth = dragStartWidth + value.translation.width
                                    let maxTerminalWidth = totalWidth - minChatWidth - dividerWidth
                                    terminalWidth = max(minTerminalWidth, min(newWidth, maxTerminalWidth))
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
            .onAppear {
                // Set initial terminal width
                if terminalWidth == 0 {
                    terminalWidth = max(minTerminalWidth, (totalWidth - dividerWidth) * 0.65)
                }
            }
            .onChange(of: geometry.size.width) { newWidth in
                // Adjust terminal width proportionally when window resizes
                if !isDragging && terminalWidth > 0 {
                    let ratio = terminalWidth / totalWidth
                    let maxTerminalWidth = newWidth - minChatWidth - dividerWidth
                    terminalWidth = max(minTerminalWidth, min(newWidth * ratio, maxTerminalWidth))
                }
            }
        }
    }
}

// MARK: - Resizable Divider
struct ResizableDivider: View {
    @Binding var isDragging: Bool
    @State private var isHovered: Bool = false
    
    // Wide hit area for easy grabbing
    private let hitAreaWidth: CGFloat = 16
    
    private var isActive: Bool { isDragging || isHovered }
    
    var body: some View {
        ZStack {
            // Invisible hit area (wide, easy to grab)
            Color.clear
                .frame(width: hitAreaWidth)
                .contentShape(Rectangle())
            
            // Visible divider line
            Rectangle()
                .fill(isActive ? Color.accentColor : Color.primary.opacity(0.15))
                .frame(width: isActive ? 3 : 1)
            
            // Drag handle indicator (dots)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .frame(width: hitAreaWidth)
        .onHover { isHovered = $0 }
        .cursor(NSCursor.resizeLeftRight)
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

// MARK: - Settings Empty State View
struct SettingsEmptyStateView: View {
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "gearshape.2")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.secondary.opacity(0.5))
            
            // Title
            Text("Settings Unavailable")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.primary)
            
            // Description
            VStack(spacing: 8) {
                Text("No active terminal tab is available.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                
                Text("Create a new tab or select an existing one to access settings.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            
            // Hint
            VStack(spacing: 6) {
                Divider()
                    .frame(width: 200)
                    .padding(.vertical, 8)
                
                HStack(spacing: 6) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("Press ")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.7))
                    + Text("⌘T")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    + Text(" to create a new tab")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
        .frame(width: 500, height: 400)
        .background(colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.98))
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
            // Load the original icon - check multiple bundle locations
            let originalIcon: NSImage? = {
                // SPM module bundle (swift run)
                if let url = Bundle.module.url(forResource: "termAIDock", withExtension: "png", subdirectory: "Resources"),
                   let img = NSImage(contentsOf: url) {
                    return img
                }
                // Main bundle directly (app bundle)
                if let url = Bundle.main.url(forResource: "termAIDock", withExtension: "png"),
                   let img = NSImage(contentsOf: url) {
                    return img
                }
                // Main bundle Resources subdirectory
                if let url = Bundle.main.url(forResource: "termAIDock", withExtension: "png", subdirectory: "Resources"),
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
        
        // Force save command history (bypass debounce since app is terminating)
        CommandHistoryStore.shared.forceSave()
        
        // Close agent logging
        AgentDebugConfig.closeLogging()
        
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
                // SPM module bundle (swift run)
                if let url = Bundle.module.url(forResource: "termAIDock", withExtension: "png", subdirectory: "Resources"),
                   let img = NSImage(contentsOf: url) {
                    return img
                }
                // Main bundle directly (app bundle)
                if let url = Bundle.main.url(forResource: "termAIDock", withExtension: "png"),
                   let img = NSImage(contentsOf: url) {
                    return img
                }
                // Main bundle Resources subdirectory
                if let url = Bundle.main.url(forResource: "termAIDock", withExtension: "png", subdirectory: "Resources"),
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
        // Activate the app first
        NSApp.activate(ignoringOtherApps: true)
        
        // Try to find and show existing settings window
        for window in NSApp.windows {
            // Check various ways the settings window might be identified
            let title = window.title.lowercased()
            let identifier = window.identifier?.rawValue.lowercased() ?? ""
            if title.contains("settings") || title.contains("preferences") ||
               identifier.contains("settings") || identifier.contains("preferences") ||
               window.contentViewController?.className.contains("Settings") == true {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        
        // Simulate Cmd+, keyboard shortcut to open settings
        // This is the most reliable way to trigger the Settings scene
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: ",",
            charactersIgnoringModifiers: ",",
            isARepeat: false,
            keyCode: 43  // keyCode for comma
        )
        if let event = event {
            NSApp.sendEvent(event)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
