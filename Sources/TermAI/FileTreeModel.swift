import Foundation
import SwiftUI
import Combine
import os.log

private let fileTreeLogger = Logger(subsystem: "com.termai.app", category: "FileTree")

// MARK: - File Tree Node

/// Represents a node in the file tree (file or directory)
final class FileTreeNode: Identifiable, ObservableObject, Hashable {
    let id: String  // Full path as ID
    let path: String
    let name: String
    let isDirectory: Bool
    let fileExtension: String?
    let language: String?
    
    @Published var children: [FileTreeNode]?
    @Published var isExpanded: Bool = false
    @Published var isLoading: Bool = false
    
    weak var parent: FileTreeNode?
    
    init(path: String, name: String, isDirectory: Bool, parent: FileTreeNode? = nil) {
        self.id = path
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.parent = parent
        
        let url = URL(fileURLWithPath: path)
        self.fileExtension = isDirectory ? nil : url.pathExtension.lowercased()
        self.language = isDirectory ? nil : Self.detectLanguage(from: fileExtension)
        
        // Directories start with nil children (not loaded yet)
        // Files have empty children array
        self.children = isDirectory ? nil : []
    }
    
    // MARK: - Hashable
    
    static func == (lhs: FileTreeNode, rhs: FileTreeNode) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // MARK: - Icon
    
    var icon: String {
        if isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }
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
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "rs": return "gearshape.2"
        case "go": return "g.circle"
        case "c", "h", "cpp", "hpp": return "c.circle"
        case "rb": return "diamond"
        case "java", "kt": return "cup.and.saucer"
        default: return "doc.text"
        }
    }
    
    var iconColor: Color {
        if isDirectory { return .accentColor }
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
    
    /// Depth in the tree (0 = root)
    var depth: Int {
        var d = 0
        var node = parent
        while node != nil {
            d += 1
            node = node?.parent
        }
        return d
    }
}

// MARK: - File Tree Model

/// Model for managing the file tree state
@MainActor
final class FileTreeModel: ObservableObject {
    @Published var rootNode: FileTreeNode?
    @Published var currentPath: String = ""
    @Published var isLoading: Bool = false
    @Published var selectedNode: FileTreeNode?
    @Published var isVisible: Bool = false
    
    /// Directories to always ignore
    private let ignoredDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "__pycache__", ".venv", "venv",
        ".build", "build", "dist", "target", ".next", ".nuxt", ".cache",
        "Pods", "DerivedData", ".gradle", ".idea", ".vscode", ".cursor",
        "vendor", "packages", ".npm", ".yarn", "coverage", ".nyc_output"
    ]
    
    /// Files to always ignore
    private let ignoredFiles: Set<String> = [
        ".DS_Store", "Thumbs.db", ".gitkeep"
    ]
    
    private var loadTask: Task<Void, Never>?
    private var gitignorePatterns: [String] = []
    
    init() {}
    
    // MARK: - Public Methods
    
    /// Update the tree root when CWD changes
    func updateRoot(to path: String) {
        guard path != currentPath, !path.isEmpty else { return }
        
        fileTreeLogger.info("Updating file tree root to: \(path, privacy: .public)")
        currentPath = path
        
        // Cancel any existing load
        loadTask?.cancel()
        
        isLoading = true
        
        loadTask = Task {
            // Parse gitignore
            gitignorePatterns = await parseGitignore(in: path)
            
            // Create root node
            let rootName = (path as NSString).lastPathComponent
            let root = FileTreeNode(path: path, name: rootName, isDirectory: true)
            root.isExpanded = true
            
            // Load immediate children
            await loadChildren(for: root)
            
            await MainActor.run {
                self.rootNode = root
                self.isLoading = false
            }
        }
    }
    
    /// Toggle expansion of a directory node
    func toggleExpansion(_ node: FileTreeNode) {
        guard node.isDirectory else { return }
        
        if node.isExpanded {
            // Collapse
            node.isExpanded = false
        } else {
            // Expand and load children if needed
            node.isExpanded = true
            if node.children == nil {
                Task {
                    await loadChildren(for: node)
                }
            }
        }
    }
    
    /// Refresh the current tree
    func refresh() {
        guard !currentPath.isEmpty else { return }
        let path = currentPath
        currentPath = ""
        updateRoot(to: path)
    }
    
    /// Expand to and select a specific file
    func revealFile(at path: String) {
        guard let root = rootNode else { return }
        
        // Build path components from root to target
        let rootPath = root.path
        guard path.hasPrefix(rootPath) else { return }
        
        let relativePath = String(path.dropFirst(rootPath.count))
        let components = relativePath.split(separator: "/").map(String.init)
        
        Task {
            var currentNode = root
            
            for component in components {
                // Ensure children are loaded
                if currentNode.children == nil {
                    await loadChildren(for: currentNode)
                }
                
                // Find child with matching name
                guard let child = currentNode.children?.first(where: { $0.name == component }) else {
                    break
                }
                
                // Expand if directory
                if child.isDirectory {
                    await MainActor.run {
                        child.isExpanded = true
                    }
                }
                
                currentNode = child
            }
            
            await MainActor.run {
                self.selectedNode = currentNode
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func loadChildren(for node: FileTreeNode) async {
        guard node.isDirectory else { return }
        
        await MainActor.run {
            node.isLoading = true
        }
        
        let children = await scanDirectory(node.path, parent: node)
        
        await MainActor.run {
            node.children = children
            node.isLoading = false
        }
    }
    
    private func scanDirectory(_ path: String, parent: FileTreeNode) async -> [FileTreeNode] {
        let fm = FileManager.default
        var results: [FileTreeNode] = []
        
        do {
            let contents = try fm.contentsOfDirectory(atPath: path)
            
            for item in contents {
                // Check for cancellation
                if Task.isCancelled { return results }
                
                // Skip ignored files
                if ignoredFiles.contains(item) { continue }
                
                // Skip most hidden files (but allow some dotfiles)
                if item.hasPrefix(".") {
                    let allowedDotfiles = ["gitignore", "env", "dockerignore", "prettierrc", "eslintrc", "babelrc", "editorconfig"]
                    if !allowedDotfiles.contains(where: { item.contains($0) }) {
                        continue
                    }
                }
                
                let fullPath = (path as NSString).appendingPathComponent(item)
                
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
                
                // Skip ignored directories
                if isDir.boolValue && ignoredDirectories.contains(item) { continue }
                
                // Skip gitignored items
                if shouldIgnore(path: item, patterns: gitignorePatterns) { continue }
                
                let node = FileTreeNode(path: fullPath, name: item, isDirectory: isDir.boolValue, parent: parent)
                results.append(node)
            }
            
            // Sort: directories first, then alphabetically
            results.sort { a, b in
                if a.isDirectory != b.isDirectory {
                    return a.isDirectory
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            
        } catch {
            fileTreeLogger.error("Error scanning directory: \(error.localizedDescription)")
        }
        
        return results
    }
    
    private func parseGitignore(in directory: String) async -> [String] {
        let gitignorePath = (directory as NSString).appendingPathComponent(".gitignore")
        guard FileManager.default.fileExists(atPath: gitignorePath) else { return [] }
        
        do {
            let content = try String(contentsOfFile: gitignorePath, encoding: .utf8)
            return content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        } catch {
            return []
        }
    }
    
    private func shouldIgnore(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            let cleanPattern = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path == cleanPattern || path.hasPrefix(cleanPattern + "/") {
                return true
            }
            // Glob-like matching for *
            if pattern.contains("*") {
                let regex = pattern
                    .replacingOccurrences(of: ".", with: "\\.")
                    .replacingOccurrences(of: "*", with: ".*")
                if (try? NSRegularExpression(pattern: "^\(regex)$", options: .caseInsensitive))?.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - Flattened Tree for List Display

extension FileTreeModel {
    /// Returns a flattened list of visible nodes for rendering
    func flattenedNodes() -> [FileTreeNode] {
        guard let root = rootNode else { return [] }
        var result: [FileTreeNode] = []
        flattenNode(root, into: &result, skipRoot: true)
        return result
    }
    
    private func flattenNode(_ node: FileTreeNode, into result: inout [FileTreeNode], skipRoot: Bool = false) {
        if !skipRoot {
            result.append(node)
        }
        
        if node.isDirectory && node.isExpanded, let children = node.children {
            for child in children {
                flattenNode(child, into: &result)
            }
        }
    }
}

