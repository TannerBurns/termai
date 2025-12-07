import SwiftUI
import AppKit

// MARK: - Safe Resource Bundle Access
// SPM's auto-generated Bundle.module fatalErrors if bundle not found.
// This provides a safe accessor that works in both app bundles and swift run.
private enum ResourceBundle {
    /// Safely get the resource bundle without crashing
    static var bundle: Bundle? {
        // For app bundles: resources are in Contents/Resources/
        // First try the main bundle directly
        if Bundle.main.url(forResource: "termAIDock", withExtension: "png") != nil {
            return Bundle.main
        }
        
        // Try to find SPM module bundle manually (for swift run)
        // SPM puts it next to the executable or in .build directory
        let bundleName = "TermAI_TermAI.bundle"
        
        // Check next to executable
        if let execURL = Bundle.main.executableURL {
            let siblingBundle = execURL.deletingLastPathComponent().appendingPathComponent(bundleName)
            if let bundle = Bundle(url: siblingBundle) {
                return bundle
            }
        }
        
        // Check in app bundle root (for symlink/copy workaround)
        if let bundleURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName) as URL?,
           let bundle = Bundle(url: bundleURL) {
            return bundle
        }
        
        return nil
    }
    
    /// Get URL for a resource, checking main bundle first then SPM bundle
    static func url(forResource name: String, withExtension ext: String, subdirectory: String? = nil) -> URL? {
        // Try main bundle first (app bundle)
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        if let subdir = subdirectory,
           let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdir) {
            return url
        }
        
        // Try SPM module bundle (swift run)
        if let bundle = bundle {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
            if let subdir = subdirectory,
               let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdir) {
                return url
            }
        }
        
        return nil
    }
}

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
    @ObservedObject private var settings = AgentSettings.shared
    @State private var showSettings: Bool = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(tabsStore)
                .preferredColorScheme(settings.appAppearance.colorScheme)
                .onAppear {
                    // Preload system info on background thread to avoid blocking later
                    SystemInfo.preloadCache()
                    
                    // Initialize agent logging if enabled
                    AgentDebugConfig.initializeLogging()
                    
                    // Request notification permissions if approval notifications are enabled
                    if AgentSettings.shared.enableApprovalNotifications {
                        SystemNotificationService.shared.requestAuthorization()
                    }
                    
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
                .preferredColorScheme(settings.appAppearance.colorScheme)
            } else {
                SettingsEmptyStateView()
                    .preferredColorScheme(settings.appAppearance.colorScheme)
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
    @State private var showFileTree: Bool = true  // Default to open
    @State private var editorWidth: CGFloat = 0
    @State private var chatWidth: CGFloat = 0  // 0 means use minimum (default)
    @State private var fileTreeWidth: CGFloat = 200
    @State private var isDraggingChat: Bool = false
    @State private var isDraggingFileTree: Bool = false
    @State private var dragStartWidth: CGFloat = 0
    
    private let minChatWidth: CGFloat = 380
    private let minEditorWidth: CGFloat = 400
    private let minFileTreeWidth: CGFloat = 150
    private let maxFileTreeWidth: CGFloat = 400
    private let defaultFileTreeWidth: CGFloat = 200
    private let dividerWidth: CGFloat = 16
    
    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            
            // Calculate widths
            let effectiveFileTreeWidth = showFileTree ? min(fileTreeWidth, maxFileTreeWidth) : 0
            
            // Chat width: use stored width if set, otherwise minimum
            let effectiveChatWidth: CGFloat = showChat ? (chatWidth > 0 ? chatWidth : minChatWidth) : 0
            
            let effectiveEditorWidth: CGFloat = {
                if editorWidth == 0 {
                    // Default: editor takes all remaining space, chat gets its width
                    let dividers = (showFileTree ? dividerWidth : 0) + (showChat ? dividerWidth : 0)
                    return max(minEditorWidth, totalWidth - effectiveFileTreeWidth - effectiveChatWidth - dividers)
                }
                return editorWidth
            }()
            
            let actualEditorWidth = max(minEditorWidth, totalWidth - effectiveFileTreeWidth - effectiveChatWidth - (showFileTree ? dividerWidth : 0) - (showChat ? dividerWidth : 0))
            
            HStack(spacing: 0) {
                // File Tree Sidebar (left)
                if showFileTree {
                    FileTreeSidebar(
                        model: tab.fileTreeModel,
                        onFileSelected: { node in
                            // Preview file on single click
                            if !node.isDirectory {
                                tab.editorTabsManager.openFile(at: node.path, asPreview: true)
                            }
                        },
                        onFileDoubleClicked: { node in
                            // Open file permanently on double click
                            if !node.isDirectory {
                                tab.editorTabsManager.openFile(at: node.path, asPreview: false)
                            }
                        },
                        onFolderGoTo: { node in
                            // Change terminal directory to selected folder
                            if node.isDirectory {
                                // Escape path for shell
                                let escapedPath = node.path
                                    .replacingOccurrences(of: "\\", with: "\\\\")
                                    .replacingOccurrences(of: "\"", with: "\\\"")
                                    .replacingOccurrences(of: " ", with: "\\ ")
                                tab.ptyModel.sendInput?("cd \(escapedPath)\n")
                                
                                // Directly navigate file tree (with lock to ignore OSC 7)
                                let targetPath = node.path
                                if FileManager.default.fileExists(atPath: targetPath) {
                                    tab.fileTreeModel.navigateTo(path: targetPath)
                                    tab.ptyModel.currentWorkingDirectory = targetPath
                                }
                            }
                        },
                        onNavigateUp: {
                            // Go up one directory
                            let currentCWD = tab.ptyModel.currentWorkingDirectory
                            let newPath = (currentCWD as NSString).deletingLastPathComponent
                            
                            tab.ptyModel.sendInput?("cd ..\n")
                            
                            // Directly navigate file tree (with lock to ignore OSC 7)
                            if FileManager.default.fileExists(atPath: newPath) {
                                tab.fileTreeModel.navigateTo(path: newPath)
                                tab.ptyModel.currentWorkingDirectory = newPath
                            }
                        },
                        onNavigateHome: {
                            // Go to home directory
                            let homePath = FileManager.default.homeDirectoryForCurrentUser.path
                            
                            tab.ptyModel.sendInput?("cd ~\n")
                            
                            // Directly navigate file tree (with lock to ignore OSC 7)
                            tab.fileTreeModel.navigateTo(path: homePath)
                            tab.ptyModel.currentWorkingDirectory = homePath
                        }
                    )
                    .frame(width: effectiveFileTreeWidth)
                    
                    // File tree resize handle
                    ResizableDivider(isDragging: $isDraggingFileTree)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { value in
                                    if !isDraggingFileTree {
                                        isDraggingFileTree = true
                                        dragStartWidth = fileTreeWidth
                                    }
                                    let newWidth = dragStartWidth + value.translation.width
                                    fileTreeWidth = max(minFileTreeWidth, min(newWidth, maxFileTreeWidth))
                                }
                                .onEnded { _ in
                                    isDraggingFileTree = false
                                }
                        )
                }
                
                // Editor Pane (center - contains terminal + file tabs)
                EditorPaneView(
                    tabsManager: tab.editorTabsManager,
                    onAddToChat: { text, meta in
                        var enriched = meta
                        enriched?.cwd = tab.ptyModel.currentWorkingDirectory
                        tab.chatTabsManager.selectedSession?.setPendingTerminalContext(text, meta: enriched)
                    },
                    onToggleChat: { showChat.toggle() },
                    onToggleFileTree: { 
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showFileTree.toggle()
                        }
                    },
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
                    },
                    onAddFileToChat: { content, filePath, lineRanges in
                        // Add file content using the proper PinnedContext system
                        if let path = filePath {
                            // Read full file content for later range editing
                            let fullContent = FilePickerService.shared.readFile(at: path) ?? content
                            tab.chatTabsManager.selectedSession?.attachFileWithRanges(
                                path: path,
                                selectedContent: content,
                                fullContent: fullContent,
                                lineRanges: lineRanges ?? []
                            )
                        }
                    },
                    isFileTreeVisible: showFileTree,
                    isChatVisible: showChat
                )
                .environmentObject(tab.ptyModel)
                .environmentObject(tab.suggestionService)
                .environmentObject(tab.editorTabsManager)
                .frame(width: actualEditorWidth)
                
                // Resizable divider and chat pane (right)
                if showChat {
                    // Draggable divider
                    ResizableDivider(isDragging: $isDraggingChat)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { value in
                                    if !isDraggingChat {
                                        isDraggingChat = true
                                        dragStartWidth = effectiveChatWidth
                                    }
                                    // Dragging left = positive translation = smaller chat
                                    let newChatWidth = dragStartWidth - value.translation.width
                                    let maxChatWidth = totalWidth - effectiveFileTreeWidth - minEditorWidth - (showFileTree ? dividerWidth : 0) - dividerWidth
                                    chatWidth = max(minChatWidth, min(newChatWidth, maxChatWidth))
                                }
                                .onEnded { _ in
                                    isDraggingChat = false
                                }
                        )
                    
                    ChatContainerView(ptyModel: tab.ptyModel)
                        .environmentObject(tab.chatTabsManager)
                        .frame(width: effectiveChatWidth)
                }
            }
            .onAppear {
                // Chat starts at minimum width by default (chatWidth = 0 means use minChatWidth)
            }
            .onChange(of: geometry.size.width) { newWidth in
                // Adjust chat width proportionally when window resizes
                if !isDraggingChat && !isDraggingFileTree && chatWidth > 0 {
                    let ratio = chatWidth / totalWidth
                    let maxChatWidth = newWidth - (showFileTree ? fileTreeWidth : 0) - minEditorWidth - (showFileTree ? dividerWidth : 0) - dividerWidth
                    chatWidth = max(minChatWidth, min(newWidth * ratio, maxChatWidth))
                }
            }
            // Keyboard shortcut to toggle file tree (Cmd+B)
            .background(
                Button("") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFileTree.toggle()
                    }
                }
                .keyboardShortcut("b", modifiers: .command)
                .opacity(0)
            )
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
                // Send the original command as-is (no wrapping)
                // Exit code and CWD will be captured transparently after command completes
                ptyModel.lastSentCommandForCapture = cmd
                // Mark capture active during command execution
                ptyModel.captureActive = true
                ptyModel.markNextOutputStart?()
                ptyModel.sendInput?(cmd + "\n")
            }
        }
        notificationObservers.append(commandObserver)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        // Set Dock/app icon with proper macOS-style rounded rect background
        let dockIcon: NSImage? = {
            // Load the original icon using safe resource bundle accessor
            let originalIcon: NSImage? = {
                if let url = ResourceBundle.url(forResource: "termAIDock", withExtension: "png", subdirectory: "Resources"),
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
                if let url = ResourceBundle.url(forResource: "termAIDock", withExtension: "png", subdirectory: "Resources"),
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
        if let url = ResourceBundle.url(forResource: name, withExtension: "icns", subdirectory: "Resources"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }
    
    private func findPNG(named name: String) -> NSImage? {
        if let url = ResourceBundle.url(forResource: name, withExtension: "png", subdirectory: "Resources"),
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
