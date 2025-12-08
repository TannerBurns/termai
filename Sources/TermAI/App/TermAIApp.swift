import SwiftUI
import AppKit

// MARK: - Focused Store Tracker
/// Observable object to track the focused TabsStore for Settings scene reactivity
@MainActor
final class FocusedStoreTracker: ObservableObject {
    static let shared = FocusedStoreTracker()
    
    /// Weak wrapper to avoid retain cycles
    private struct WeakStore {
        weak var store: TabsStore?
    }
    
    private var _weakStore = WeakStore() {
        didSet { objectWillChange.send() }
    }
    
    var focusedStore: TabsStore? {
        get { _weakStore.store }
        set { _weakStore = WeakStore(store: newValue) }
    }
    
    private init() {}
}

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

/// Helper to open new windows from non-SwiftUI contexts (like AppDelegate)
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    
    /// The openWindow action from SwiftUI environment
    private var openWindowAction: (() -> Void)?
    
    /// Pending directory for new window to open at (thread-safe)
    private static let pendingDirectoryLock = NSLock()
    private static var _pendingNewWindowDirectory: String?
    
    static var pendingNewWindowDirectory: String? {
        get {
            pendingDirectoryLock.lock()
            defer { pendingDirectoryLock.unlock() }
            return _pendingNewWindowDirectory
        }
        set {
            pendingDirectoryLock.lock()
            _pendingNewWindowDirectory = newValue
            pendingDirectoryLock.unlock()
        }
    }
    
    /// Consume the pending directory (returns it and clears it)
    static func consumePendingDirectory() -> String? {
        pendingDirectoryLock.lock()
        defer { pendingDirectoryLock.unlock() }
        let dir = _pendingNewWindowDirectory
        _pendingNewWindowDirectory = nil
        return dir
    }
    
    private init() {}
    
    /// Register the openWindow action (called from SwiftUI view)
    func register(openWindow: @escaping () -> Void) {
        openWindowAction = openWindow
    }
    
    /// Open a new window, optionally at a specific directory
    func openNewWindow(atDirectory directory: String? = nil) {
        // Store the directory for the new window to pick up
        Self.pendingNewWindowDirectory = directory
        
        // Trigger new window via the registered action
        openWindowAction?()
    }
}

@main
struct TermAIApp: App {
    @ObservedObject private var settings = AgentSettings.shared
    @State private var showSettings: Bool = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            WindowContentWrapper(appDelegate: appDelegate, openWindowAction: { openWindow(id: "main") })
                .preferredColorScheme(settings.appAppearance.colorScheme)
        }
        .windowStyle(.titleBar)
        .commands {
            // AppCommands observes FocusedStoreTracker directly
            AppCommands()
        }

        Settings {
            SettingsSceneContent()
                .preferredColorScheme(settings.appAppearance.colorScheme)
        }
    }
}

// MARK: - Settings Scene Content
/// Wrapper view that observes FocusedStoreTracker for reactive Settings updates
struct SettingsSceneContent: View {
    @ObservedObject private var focusedTracker = FocusedStoreTracker.shared
    
    var body: some View {
        if let focusedStore = focusedTracker.focusedStore,
           let selectedTab = focusedStore.selected,
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


// MARK: - Window Content Wrapper
/// Each window gets its own TabsStore for independent tab management
struct WindowContentWrapper: View {
    @StateObject private var tabsStore: TabsStore
    let appDelegate: AppDelegate
    let openWindowAction: () -> Void
    
    init(appDelegate: AppDelegate, openWindowAction: @escaping () -> Void) {
        self.appDelegate = appDelegate
        self.openWindowAction = openWindowAction
        
        // Check if there's a pending directory for this new window
        // Both methods atomically consume (read and clear) the pending directory
        let initialDirectory = WindowOpener.consumePendingDirectory()
            ?? AppDelegate.consumePendingServiceDirectory()
        
        // Create TabsStore with initial directory if provided
        _tabsStore = StateObject(wrappedValue: TabsStore(initialDirectory: initialDirectory))
    }
    
    var body: some View {
        MainContentView()
            .environmentObject(tabsStore)
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
                
                // Track this as the focused TabsStore
                AppDelegate.focusedTabsStore = tabsStore
                
                // Setup notification observers (stored in AppDelegate for cleanup)
                appDelegate.setupNotificationObservers(tabsStore: tabsStore)
                
                // Activate app if launched via Services (window is now visible)
                AppDelegate.activateIfNeeded()
                
                // Register the openWindow action for dock menu to use
                WindowOpener.shared.register(openWindow: openWindowAction)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                // Track focused window's TabsStore for menu commands
                if let window = notification.object as? NSWindow,
                   window.contentView?.subviews.first != nil {
                    AppDelegate.focusedTabsStore = tabsStore
                }
            }
    }
}

// MARK: - Main Content View
struct MainContentView: View {
    @EnvironmentObject var tabsStore: TabsStore
    @Environment(\.colorScheme) var colorScheme
    
    private var dividerColor: Color {
        colorScheme == .dark
            ? Color(red: 0.24, green: 0.27, blue: 0.32)  // #3e4451 - Atom One Dark divider
            : Color(red: 0.82, green: 0.82, blue: 0.82)  // #d1d1d1 - Atom One Light divider
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top-level app tab bar
            AppTabBar()
            
            // Themed divider
            Rectangle()
                .fill(dividerColor)
                .frame(height: 1)
            
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
        .frame(minWidth: 1100, minHeight: 680)
    }
}

// MARK: - App Tab Bar (Top-Level)
struct AppTabBar: View {
    @EnvironmentObject var tabsStore: TabsStore
    @State private var hoveredTabId: UUID?
    @Environment(\.colorScheme) var colorScheme
    
    // Atom One themed colors
    private var barBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.13, green: 0.14, blue: 0.17)  // #21252b - Atom One Dark header
            : Color(red: 0.91, green: 0.91, blue: 0.91)  // #e8e8e8 - Atom One Light header
    }
    
    private var buttonBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.24, green: 0.27, blue: 0.32)  // #3e4451 - Atom One Dark accent
            : Color(red: 0.82, green: 0.82, blue: 0.82)  // #d1d1d1 - Atom One Light accent
    }
    
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
                            .fill(buttonBackground.opacity(0.5))
                    )
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            .padding(.trailing, 8)
        }
        .frame(height: 36)
        .background(barBackground)
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
    @Environment(\.colorScheme) var colorScheme
    
    // Atom One themed colors
    private var accentColor: Color {
        colorScheme == .dark
            ? Color(red: 0.38, green: 0.65, blue: 0.93)  // #61afef - Atom One Dark blue
            : Color(red: 0.30, green: 0.52, blue: 0.79)  // #4d84c9 - Atom One Light blue
    }
    
    private var selectedBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.17, green: 0.19, blue: 0.23)  // #2c313a - Atom One Dark elevated
            : Color(red: 0.98, green: 0.98, blue: 0.98)  // #fafafa - Atom One Light elevated
    }
    
    private var hoverBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.24, green: 0.27, blue: 0.32).opacity(0.5)  // #3e4451
            : Color(red: 0.85, green: 0.85, blue: 0.85).opacity(0.5)  // Light hover
    }
    
    var body: some View {
        HStack(spacing: 4) {
            // Tab icon
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundColor(isSelected ? accentColor : .secondary)
            
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
                .fill(isSelected ? selectedBackground : (isHovered ? hoverBackground : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
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
    
    private let minChatWidth: CGFloat = 450
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
    @Environment(\.colorScheme) var colorScheme
    
    // Wide hit area for easy grabbing
    private let hitAreaWidth: CGFloat = 16
    
    private var isActive: Bool { isDragging || isHovered }
    
    // Atom One themed colors
    private var accentColor: Color {
        colorScheme == .dark
            ? Color(red: 0.38, green: 0.65, blue: 0.93)  // #61afef - Atom One Dark blue
            : Color(red: 0.30, green: 0.52, blue: 0.79)  // #4d84c9 - Atom One Light blue
    }
    
    private var dividerColor: Color {
        colorScheme == .dark
            ? Color(red: 0.24, green: 0.27, blue: 0.32)  // #3e4451 - Atom One Dark divider
            : Color(red: 0.82, green: 0.82, blue: 0.82)  // #d1d1d1 - Atom One Light divider
    }
    
    var body: some View {
        ZStack {
            // Invisible hit area (wide, easy to grab)
            Color.clear
                .frame(width: hitAreaWidth)
                .contentShape(Rectangle())
            
            // Visible divider line
            Rectangle()
                .fill(isActive ? accentColor : dividerColor)
                .frame(width: isActive ? 3 : 1)
            
            // Drag handle indicator (dots)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(isActive ? accentColor : Color.secondary.opacity(0.4))
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
        .background(
            colorScheme == .dark
                ? Color(red: 0.16, green: 0.17, blue: 0.20)  // #282c34 - Atom One Dark background
                : Color(red: 0.98, green: 0.98, blue: 0.98)  // #fafafa - Atom One Light background
        )
    }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    weak var tabsStore: TabsStore?
    private var notificationObservers: [NSObjectProtocol] = []
    
    /// Pending directory from Services - picked up when app launches (thread-safe)
    private static let pendingServiceDirectoryLock = NSLock()
    private static var _pendingServiceDirectory: String?
    
    static var pendingServiceDirectory: String? {
        get {
            pendingServiceDirectoryLock.lock()
            defer { pendingServiceDirectoryLock.unlock() }
            return _pendingServiceDirectory
        }
        set {
            pendingServiceDirectoryLock.lock()
            _pendingServiceDirectory = newValue
            pendingServiceDirectoryLock.unlock()
        }
    }
    
    /// Consume the pending service directory (returns it and clears it atomically)
    static func consumePendingServiceDirectory() -> String? {
        pendingServiceDirectoryLock.lock()
        defer { pendingServiceDirectoryLock.unlock() }
        let dir = _pendingServiceDirectory
        _pendingServiceDirectory = nil
        return dir
    }
    
    /// Track the focused window's TabsStore for menu commands (legacy static access)
    @MainActor static var focusedTabsStore: TabsStore? {
        get { FocusedStoreTracker.shared.focusedStore }
        set { FocusedStoreTracker.shared.focusedStore = newValue }
    }
    
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
        
        // Register as services provider for "New TermAI at Folder" Finder integration
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }
    
    // MARK: - macOS Services Handler
    
    /// Handle "New TermAI at Folder" service from Finder's right-click menu
    /// This is called when user right-clicks a folder in Finder and selects Services > New TermAI at Folder
    @objc func openTerminalAtFolder(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // Try to get file paths from the pasteboard (NSFilenamesPboardType)
        var folderPath: String?
        
        // Method 1: Try reading as filenames (array of paths)
        if let filenames = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
           let firstPath = filenames.first {
            folderPath = firstPath
        }
        // Method 2: Try reading as file URLs
        else if let fileURLs = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                let firstURL = fileURLs.first {
            folderPath = firstURL.path
        }
        
        guard let path = folderPath else {
            error.pointee = "No folder path received" as NSString
            return
        }
        
        // Verify it's a directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            error.pointee = "Selected item is not a folder" as NSString
            return
        }
        
        // Record to recent projects for dock menu
        Task { @MainActor in
            RecentProjectsStore.shared.addProject(path: path)
        }
        
        // Store the pending directory - this will be picked up by the first tab
        AppDelegate.pendingServiceDirectory = path
        
        // Bring app to foreground - need multiple attempts as window may not be ready yet
        Self.bringAppToForeground()
    }
    
    /// Flag to indicate we need to bring app to foreground when window appears
    static var needsForegroundActivation = false
    
    /// Force the app to show with its window visible
    private static func bringAppToForeground() {
        needsForegroundActivation = true
        
        // Use NSWorkspace to open the app - this often works better than activate
        if let bundleURL = Bundle.main.bundleURL as URL? {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.hidesOthers = false
            
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
                if let error = error {
                    print("Failed to activate via NSWorkspace: \(error)")
                }
            }
        }
        
        // Also try standard activation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where !window.isMiniaturized {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
    
    /// Called when main window appears - activate if launched via Services
    static func activateIfNeeded() {
        guard needsForegroundActivation else { return }
        needsForegroundActivation = false
        
        // Additional activation when window appears (backup for NSWorkspace approach)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
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
    
    /// Handle dock icon click when app has no windows
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // No visible windows - show the main window
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
    
    /// Called when app becomes active
    func applicationDidBecomeActive(_ notification: Notification) {
        // Make sure we have a key window
        if NSApp.keyWindow == nil {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
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
    
    // MARK: - Dock Menu
    
    /// Provide a custom menu when right-clicking the dock icon
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        
        // New Window at Home
        let homeItem = NSMenuItem(title: "New Window at Home", action: #selector(openNewWindowAtHome), keyEquivalent: "")
        homeItem.target = self
        menu.addItem(homeItem)
        
        menu.addItem(.separator())
        
        // Recent Projects section (use cached projects for synchronous access)
        let recentProjects = RecentProjectsStore.cachedProjects
        if !recentProjects.isEmpty {
            let headerItem = NSMenuItem(title: "Recent Projects", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            
            for project in recentProjects.prefix(10) {
                let item = NSMenuItem(title: project.displayName, action: #selector(openRecentProject(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = project.path
                item.toolTip = project.path
                menu.addItem(item)
            }
            
            menu.addItem(.separator())
            
            let clearItem = NSMenuItem(title: "Clear Recent Projects", action: #selector(clearRecentProjects), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }
        
        return menu
    }
    
    /// Open a new window at the home directory
    @objc private func openNewWindowAtHome() {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            
            let homePath = FileManager.default.homeDirectoryForCurrentUser.path
            WindowOpener.shared.openNewWindow(atDirectory: homePath)
        }
    }
    
    /// Open a new window at a recent project directory
    @objc private func openRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        
        // Verify the directory still exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            // Directory no longer exists - remove from recent projects
            Task { @MainActor in
                if let project = RecentProjectsStore.shared.projects.first(where: { $0.path == path }) {
                    RecentProjectsStore.shared.removeProject(id: project.id)
                }
            }
            return
        }
        
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            WindowOpener.shared.openNewWindow(atDirectory: path)
        }
    }
    
    /// Clear all recent projects
    @objc private func clearRecentProjects() {
        Task { @MainActor in
            RecentProjectsStore.shared.clearAll()
        }
    }
}
