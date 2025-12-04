import Foundation
import Combine
import os.log

private let filePickerLogger = Logger(subsystem: "com.termai", category: "FilePickerService")

// MARK: - File Entry

/// Represents a file entry for the file picker
struct FileEntry: Identifiable, Equatable, Hashable {
    let id: String  // Full path as ID
    let path: String
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let fileExtension: String?
    let language: String?
    
    init(path: String, relativeTo basePath: String, isDirectory: Bool = false) {
        self.id = path
        self.path = path
        self.isDirectory = isDirectory
        
        let url = URL(fileURLWithPath: path)
        self.name = url.lastPathComponent
        self.fileExtension = isDirectory ? nil : url.pathExtension.lowercased()
        
        // Compute relative path
        if path.hasPrefix(basePath) {
            var relative = String(path.dropFirst(basePath.count))
            if relative.hasPrefix("/") {
                relative = String(relative.dropFirst())
            }
            self.relativePath = relative
        } else {
            self.relativePath = path
        }
        
        // Detect language from extension
        self.language = Self.detectLanguage(from: fileExtension)
    }
    
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
        case "txt", "log": return "text"
        default: return nil
        }
    }
    
    /// Icon for the file type
    var icon: String {
        if isDirectory { return "folder.fill" }
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
        default: return "doc.text"
        }
    }
    
    /// Check if this is a code/text file worth indexing
    var isTextFile: Bool {
        language != nil || fileExtension == "txt" || fileExtension == "log"
    }
}

// MARK: - File Picker Service

/// Service for indexing and searching files in the current working directory
@MainActor
final class FilePickerService: ObservableObject {
    static let shared = FilePickerService()
    
    /// Indexed files in the current directory
    @Published private(set) var indexedFiles: [FileEntry] = []
    
    /// Current working directory being indexed
    @Published private(set) var currentCwd: String = ""
    
    /// Whether indexing is in progress
    @Published private(set) var isIndexing: Bool = false
    
    /// Common code file extensions to index
    private let codeExtensions: Set<String> = [
        "swift", "py", "js", "ts", "jsx", "tsx", "json", "yaml", "yml",
        "html", "htm", "css", "scss", "sass", "less", "rs", "go", "c", "h",
        "cpp", "hpp", "cc", "cxx", "md", "markdown", "sh", "bash", "zsh",
        "rb", "java", "kt", "kts", "toml", "xml", "sql", "txt", "log",
        "makefile", "dockerfile", "gitignore", "env", "lock", "gradle",
        "graphql", "vue", "svelte", "astro", "php", "scala", "clj", "ex", "exs"
    ]
    
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
    
    /// Maximum file size to consider (1MB)
    private let maxFileSize: Int = 1_000_000
    
    /// Maximum number of files to index
    private let maxFiles: Int = 5000
    
    private var indexTask: Task<Void, Never>?
    
    private init() {}
    
    /// Index files in the given directory
    func indexDirectory(_ path: String) {
        // Skip if already indexing the same directory
        guard path != currentCwd || indexedFiles.isEmpty else { return }
        
        // Cancel any existing indexing task
        indexTask?.cancel()
        
        currentCwd = path
        isIndexing = true
        
        indexTask = Task { [weak self] in
            guard let self = self else { return }
            
            filePickerLogger.info("Starting file index for: \(path, privacy: .public)")
            let startTime = Date()
            
            // Parse .gitignore patterns
            let gitignorePatterns = await self.parseGitignore(in: path)
            
            // Index files
            let files = await self.scanDirectory(path, basePath: path, gitignorePatterns: gitignorePatterns)
            
            // Sort by relative path
            let sortedFiles = files.sorted { $0.relativePath < $1.relativePath }
            
            let elapsed = Date().timeIntervalSince(startTime)
            filePickerLogger.info("Indexed \(sortedFiles.count) files in \(String(format: "%.2f", elapsed))s")
            
            await MainActor.run {
                self.indexedFiles = sortedFiles
                self.isIndexing = false
            }
        }
    }
    
    /// Search for files matching the query
    func search(query: String) -> [FileEntry] {
        let lowercaseQuery = query.lowercased()
        
        // Empty query returns nothing
        guard !lowercaseQuery.isEmpty else { return [] }
        
        // Filter and score files
        var results: [(file: FileEntry, score: Int)] = []
        
        for file in indexedFiles {
            let lowercaseName = file.name.lowercased()
            let lowercaseRelative = file.relativePath.lowercased()
            
            var score = 0
            
            // Exact name match (highest priority)
            if lowercaseName == lowercaseQuery {
                score = 1000
            }
            // Name starts with query
            else if lowercaseName.hasPrefix(lowercaseQuery) {
                score = 500 + (100 - min(lowercaseName.count, 100))
            }
            // Name contains query
            else if lowercaseName.contains(lowercaseQuery) {
                score = 200 + (100 - min(lowercaseName.count, 100))
            }
            // Path contains query
            else if lowercaseRelative.contains(lowercaseQuery) {
                score = 100 + (100 - min(lowercaseRelative.count, 100))
            }
            // Fuzzy match on name
            else if fuzzyMatch(lowercaseQuery, in: lowercaseName) {
                score = 50 + (100 - min(lowercaseName.count, 100))
            }
            
            if score > 0 {
                results.append((file, score))
            }
        }
        
        // Sort by score (descending) and limit results
        return results
            .sorted { $0.score > $1.score }
            .prefix(20)
            .map { $0.file }
    }
    
    /// Read file content with optional line range
    /// Read file content with optional line range (legacy support)
    func readFile(at path: String, startLine: Int? = nil, endLine: Int? = nil) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            
            // If no line range specified, return full content
            guard let start = startLine else { return content }
            
            // Extract line range
            let lines = content.components(separatedBy: .newlines)
            let startIdx = max(0, start - 1)
            let endIdx = min(lines.count, endLine ?? lines.count)
            
            guard startIdx < lines.count else { return nil }
            
            return Array(lines[startIdx..<endIdx]).joined(separator: "\n")
        } catch {
            filePickerLogger.error("Failed to read file: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Read file with multiple line ranges, returns (selectedContent, fullContent)
    func readFileWithRanges(at path: String, ranges: [LineRange]) -> (selected: String, full: String)? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            
            // If no ranges specified, return full content
            guard !ranges.isEmpty else { return (content, content) }
            
            // Extract lines for each range
            let lines = content.components(separatedBy: .newlines)
            var selectedLines: [String] = []
            
            for range in ranges.sorted(by: { $0.start < $1.start }) {
                let startIdx = max(0, range.start - 1)
                let endIdx = min(lines.count, range.end)
                
                guard startIdx < lines.count else { continue }
                
                // Add a separator comment between ranges if there's already content
                if !selectedLines.isEmpty {
                    selectedLines.append("")
                    selectedLines.append("// ... (lines \(ranges.last { $0.end < range.start }?.end ?? 0 + 1)-\(range.start - 1) omitted) ...")
                    selectedLines.append("")
                }
                
                selectedLines.append(contentsOf: lines[startIdx..<endIdx])
            }
            
            return (selectedLines.joined(separator: "\n"), content)
        } catch {
            filePickerLogger.error("Failed to read file: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Clear the index
    func clearIndex() {
        indexTask?.cancel()
        indexedFiles.removeAll()
        currentCwd = ""
        isIndexing = false
    }
    
    // MARK: - Private Helpers
    
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
    
    private func scanDirectory(_ path: String, basePath: String, gitignorePatterns: [String], depth: Int = 0) async -> [FileEntry] {
        // Limit recursion depth
        guard depth < 15 else { return [] }
        
        // Check for cancellation
        if Task.isCancelled { return [] }
        
        let fm = FileManager.default
        var results: [FileEntry] = []
        
        do {
            let contents = try fm.contentsOfDirectory(atPath: path)
            
            for item in contents {
                // Check for cancellation
                if Task.isCancelled { return results }
                
                // Skip hidden files/directories
                if item.hasPrefix(".") && ![".", ".."].contains(item) {
                    // Allow certain dotfiles
                    if !["gitignore", "env", "dockerignore", "prettierrc", "eslintrc", "babelrc"].contains(where: { item.contains($0) }) {
                        continue
                    }
                }
                
                let fullPath = (path as NSString).appendingPathComponent(item)
                
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
                
                if isDir.boolValue {
                    // Skip ignored directories
                    if ignoredDirectories.contains(item) { continue }
                    if shouldIgnore(path: item, patterns: gitignorePatterns) { continue }
                    
                    // Recurse into directory
                    let subResults = await scanDirectory(fullPath, basePath: basePath, gitignorePatterns: gitignorePatterns, depth: depth + 1)
                    results.append(contentsOf: subResults)
                    
                    // Check if we've exceeded the limit
                    if results.count >= maxFiles { return results }
                } else {
                    // Skip ignored files
                    if ignoredFiles.contains(item) { continue }
                    if shouldIgnore(path: item, patterns: gitignorePatterns) { continue }
                    
                    // Check file extension
                    let ext = (item as NSString).pathExtension.lowercased()
                    let nameWithoutExt = (item as NSString).deletingPathExtension.lowercased()
                    
                    // Include files with known extensions or certain special files
                    let hasKnownExtension = codeExtensions.contains(ext)
                    let isSpecialFile = ["makefile", "dockerfile", "gemfile", "rakefile", "procfile", "cmakelists"].contains(nameWithoutExt)
                    
                    guard hasKnownExtension || isSpecialFile else { continue }
                    
                    // Check file size
                    if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                       let size = attrs[.size] as? Int,
                       size > maxFileSize {
                        continue
                    }
                    
                    let entry = FileEntry(path: fullPath, relativeTo: basePath, isDirectory: false)
                    results.append(entry)
                    
                    // Check if we've exceeded the limit
                    if results.count >= maxFiles { return results }
                }
            }
        } catch {
            filePickerLogger.error("Error scanning directory: \(error.localizedDescription)")
        }
        
        return results
    }
    
    private func shouldIgnore(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            // Simple pattern matching
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
    
    private func fuzzyMatch(_ query: String, in target: String) -> Bool {
        var queryIndex = query.startIndex
        var targetIndex = target.startIndex
        
        while queryIndex < query.endIndex && targetIndex < target.endIndex {
            if query[queryIndex] == target[targetIndex] {
                queryIndex = query.index(after: queryIndex)
            }
            targetIndex = target.index(after: targetIndex)
        }
        
        return queryIndex == query.endIndex
    }
}

