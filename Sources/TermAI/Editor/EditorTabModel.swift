import Foundation
import SwiftUI
import Combine

// MARK: - Editor Tab Type

/// Represents the type of content in an editor tab
enum EditorTabType: Equatable, Hashable {
    case terminal
    case file(path: String)
    case plan(id: UUID)  // Implementation plan from Navigator mode
    
    var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }
    
    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
    
    var isPlan: Bool {
        if case .plan = self { return true }
        return false
    }
    
    var filePath: String? {
        switch self {
        case .file(let path):
            return path
        case .plan(let id):
            // Get the plan file path using global helper (doesn't need MainActor)
            return planFilePath(for: id)
        default:
            return nil
        }
    }
    
    var planId: UUID? {
        if case .plan(let id) = self { return id }
        return nil
    }
}

// MARK: - Editor Tab

/// Represents a single tab in the editor pane
final class EditorTab: Identifiable, ObservableObject, Equatable {
    let id: UUID
    let type: EditorTabType
    
    @Published var title: String
    @Published var isPreview: Bool  // Preview tabs get replaced when opening another file
    @Published var isDirty: Bool = false
    @Published var scrollPosition: CGFloat = 0
    @Published var searchQuery: String = ""
    
    // File-specific properties
    let filePath: String?
    let language: String?
    let fileExtension: String?
    
    init(type: EditorTabType, title: String? = nil, isPreview: Bool = false) {
        self.id = UUID()
        self.type = type
        self.isPreview = isPreview
        
        switch type {
        case .terminal:
            self.title = title ?? "Terminal"
            self.filePath = nil
            self.language = nil
            self.fileExtension = nil
            
        case .file(let path):
            let url = URL(fileURLWithPath: path)
            self.filePath = path
            self.title = title ?? url.lastPathComponent
            self.fileExtension = url.pathExtension.lowercased()
            self.language = Self.detectLanguage(from: fileExtension)
            
        case .plan(let planId):
            // Use provided title or default - plan details loaded lazily
            self.title = title ?? "Implementation Plan"
            self.filePath = planFilePath(for: planId)
            self.fileExtension = "md"
            self.language = "markdown"
        }
    }
    
    static func == (lhs: EditorTab, rhs: EditorTab) -> Bool {
        lhs.id == rhs.id
    }
    
    // MARK: - Icons
    
    var icon: String {
        switch type {
        case .terminal:
            return "terminal"
        case .plan:
            return "map.fill"
        case .file:
            guard let ext = fileExtension else { return "doc.text" }
            switch ext {
            case "swift": return "swift"
            case "py": return "chevron.left.forwardslash.chevron.right"
            case "js", "ts", "jsx", "tsx": return "curlybraces"
            case "json", "yaml", "yml", "toml": return "doc.badge.gearshape"
            case "html", "htm", "xml": return "chevron.left.forwardslash.chevron.right"
            case "css", "scss", "sass": return "paintbrush"
            case "md", "markdown": return "text.document"
            case "sh", "bash", "zsh": return "terminal"
            case "rs": return "gearshape.2"
            case "go": return "g.circle"
            case "c", "h", "cpp", "hpp": return "c.circle"
            default: return "doc.text"
            }
        }
    }
    
    var iconColor: Color {
        switch type {
        case .terminal:
            return .green
        case .plan:
            return Color(red: 0.7, green: 0.4, blue: 0.9)  // Navigator purple
        case .file:
            guard let ext = fileExtension else { return .secondary }
            switch ext {
            case "swift": return .orange
            case "py": return Color(red: 0.3, green: 0.6, blue: 0.9)
            case "js", "jsx": return .yellow
            case "ts", "tsx": return Color(red: 0.2, green: 0.5, blue: 0.8)
            case "json": return .green
            case "yaml", "yml": return .pink
            case "html", "htm": return .orange
            case "css", "scss", "sass": return .blue
            case "md", "markdown": return .purple
            case "sh", "bash", "zsh": return .green
            case "rs": return Color(red: 0.85, green: 0.4, blue: 0.2)
            case "go": return .cyan
            case "c", "h", "cpp", "hpp": return Color(red: 0.4, green: 0.5, blue: 0.8)
            default: return .secondary
            }
        }
    }
    
    // MARK: - Language Detection
    
    private static func detectLanguage(from ext: String?) -> String? {
        guard let ext = ext else { return nil }
        switch ext {
        case "swift": return "swift"
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "jsx", "tsx": return ext
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "html", "htm": return "html"
        case "css", "scss", "sass": return "css"
        case "rs": return "rust"
        case "go": return "go"
        case "c", "h": return "c"
        case "cpp", "hpp", "cc", "cxx": return "cpp"
        case "md", "markdown": return "markdown"
        case "sh", "bash", "zsh": return "shell"
        case "rb": return "ruby"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "toml": return "toml"
        case "xml": return "xml"
        case "sql": return "sql"
        default: return nil
        }
    }
}

// MARK: - Editor Tabs Manager

/// Manages the collection of open editor tabs
@MainActor
final class EditorTabsManager: ObservableObject {
    @Published var tabs: [EditorTab] = []
    @Published var selectedTabId: UUID?
    
    /// The terminal tab (always present, always first)
    private(set) var terminalTab: EditorTab
    
    init() {
        let terminal = EditorTab(type: .terminal)
        self.terminalTab = terminal
        self.tabs = [terminal]
        self.selectedTabId = terminal.id
    }
    
    var selectedTab: EditorTab? {
        tabs.first { $0.id == selectedTabId }
    }
    
    var selectedIndex: Int {
        tabs.firstIndex { $0.id == selectedTabId } ?? 0
    }
    
    // MARK: - Tab Operations
    
    /// Open a file in a new tab or focus existing tab
    func openFile(at path: String, asPreview: Bool = false) {
        // Check if file is already open
        if let existing = tabs.first(where: { $0.type == .file(path: path) }) {
            // If it was a preview and we're opening permanently, mark it as non-preview
            if existing.isPreview && !asPreview {
                existing.isPreview = false
            }
            selectedTabId = existing.id
            return
        }
        
        // Create new tab (don't replace preview tabs - allows multiple files to be open)
        let newTab = EditorTab(type: .file(path: path), isPreview: asPreview)
        tabs.append(newTab)
        selectedTabId = newTab.id
    }
    
    /// Open a plan in a new tab or focus existing tab
    func openPlan(id: UUID) {
        // Check if plan is already open
        if let existing = tabs.first(where: { $0.type == .plan(id: id) }) {
            selectedTabId = existing.id
            return
        }
        
        // Ensure the plan file exists (using global helper)
        guard planFilePath(for: id) != nil else { return }
        
        // Try to get the plan title from PlanManager (on MainActor)
        let planTitle: String?
        if let plan = PlanManager.shared.getPlan(id: id) {
            planTitle = "📋 \(plan.title)"
        } else {
            planTitle = nil
        }
        
        // Create new tab for the plan
        let newTab = EditorTab(type: .plan(id: id), title: planTitle, isPreview: false)
        tabs.append(newTab)
        selectedTabId = newTab.id
    }
    
    /// Close a tab by ID
    func closeTab(id: UUID) {
        // Can't close terminal tab
        guard id != terminalTab.id else { return }
        
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        
        // If closing selected tab, select adjacent
        if selectedTabId == id {
            if index > 0 {
                selectedTabId = tabs[index - 1].id
            } else if tabs.count > 1 {
                selectedTabId = tabs[1].id
            }
        }
        
        tabs.remove(at: index)
    }
    
    /// Close all file tabs
    func closeAllFileTabs() {
        tabs.removeAll { $0.type.isFile }
        selectedTabId = terminalTab.id
    }
    
    /// Close all tabs except the given one
    func closeOtherTabs(except id: UUID) {
        tabs.removeAll { $0.id != id && $0.type.isFile }
        if tabs.first(where: { $0.id == selectedTabId }) == nil {
            selectedTabId = tabs.first?.id
        }
    }
    
    /// Select tab by ID
    func selectTab(id: UUID) {
        if tabs.contains(where: { $0.id == id }) {
            selectedTabId = id
        }
    }
    
    /// Select terminal tab
    func selectTerminal() {
        selectedTabId = terminalTab.id
    }
    
    /// Move tab from one position to another
    func moveTab(from source: Int, to destination: Int) {
        // Can't move terminal tab (index 0)
        guard source > 0 && destination > 0 else { return }
        guard source < tabs.count && destination <= tabs.count else { return }
        
        let tab = tabs.remove(at: source)
        let adjustedDestination = destination > source ? destination - 1 : destination
        tabs.insert(tab, at: adjustedDestination)
    }
    
    /// Get file tabs only (includes plan tabs since they're also file-based)
    var fileTabs: [EditorTab] {
        tabs.filter { $0.type.isFile || $0.type.isPlan }
    }
    
    /// Check if a file is open
    func isFileOpen(_ path: String) -> Bool {
        tabs.contains { $0.type == .file(path: path) }
    }
    
    /// Check if a plan is open
    func isPlanOpen(_ id: UUID) -> Bool {
        tabs.contains { $0.type == .plan(id: id) }
    }
    
    /// Pin a preview tab (make it permanent)
    func pinTab(id: UUID) {
        if let tab = tabs.first(where: { $0.id == id }) {
            tab.isPreview = false
        }
    }
}

// MARK: - Persistence

extension EditorTabsManager {
    struct TabsState: Codable {
        let openFilePaths: [String]
        let selectedFilePath: String?
        let isTerminalSelected: Bool
    }
    
    func saveState() -> TabsState {
        let openPaths = fileTabs.map { $0.filePath ?? "" }.filter { !$0.isEmpty }
        let selectedPath = selectedTab?.filePath
        let isTerminal = selectedTab?.type.isTerminal ?? true
        
        return TabsState(
            openFilePaths: openPaths,
            selectedFilePath: selectedPath,
            isTerminalSelected: isTerminal
        )
    }
    
    func restoreState(_ state: TabsState) {
        // Open saved files
        for path in state.openFilePaths {
            // Verify file still exists
            if FileManager.default.fileExists(atPath: path) {
                openFile(at: path, asPreview: false)
            }
        }
        
        // Restore selection
        if state.isTerminalSelected {
            selectTerminal()
        } else if let selectedPath = state.selectedFilePath,
                  let tab = tabs.first(where: { $0.filePath == selectedPath }) {
            selectedTabId = tab.id
        }
    }
}

