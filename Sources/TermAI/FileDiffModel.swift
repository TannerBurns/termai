import Foundation

// MARK: - File Operation Type

/// Types of file operations that can be previewed
enum FileOperationType: String, Codable, Equatable {
    case create = "Create"
    case edit = "Edit"
    case insert = "Insert"
    case delete = "Delete"
    case overwrite = "Overwrite"
    
    var icon: String {
        switch self {
        case .create: return "doc.badge.plus"
        case .edit: return "pencil"
        case .insert: return "text.insert"
        case .delete: return "trash"
        case .overwrite: return "arrow.triangle.2.circlepath"
        }
    }
    
    var color: String {
        switch self {
        case .create: return "green"
        case .edit: return "blue"
        case .insert: return "cyan"
        case .delete: return "red"
        case .overwrite: return "orange"
        }
    }
    
    var description: String {
        switch self {
        case .create: return "New file"
        case .edit: return "Edit file"
        case .insert: return "Insert lines"
        case .delete: return "Delete lines"
        case .overwrite: return "Overwrite file"
        }
    }
}

// MARK: - File Change

/// Represents a pending or completed file change with before/after content
struct FileChange: Identifiable, Codable, Equatable {
    let id: UUID
    let filePath: String
    let operationType: FileOperationType
    let beforeContent: String?
    let afterContent: String?
    let timestamp: Date
    
    /// For edit operations - the specific text being replaced
    var oldText: String?
    /// For edit operations - the replacement text
    var newText: String?
    /// For line operations - starting line number
    var startLine: Int?
    /// For line operations - ending line number
    var endLine: Int?
    
    init(
        id: UUID = UUID(),
        filePath: String,
        operationType: FileOperationType,
        beforeContent: String? = nil,
        afterContent: String? = nil,
        oldText: String? = nil,
        newText: String? = nil,
        startLine: Int? = nil,
        endLine: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.filePath = filePath
        self.operationType = operationType
        self.beforeContent = beforeContent
        self.afterContent = afterContent
        self.oldText = oldText
        self.newText = newText
        self.startLine = startLine
        self.endLine = endLine
        self.timestamp = timestamp
    }
    
    /// Get the file extension for syntax highlighting
    var fileExtension: String? {
        let url = URL(fileURLWithPath: filePath)
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
    
    /// Get the filename without path
    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
    
    /// Get the language identifier for syntax highlighting
    var language: String? {
        guard let ext = fileExtension else { return nil }
        switch ext {
        case "swift": return "swift"
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "jsx", "tsx": return "javascript"
        case "rs": return "rust"
        case "go": return "go"
        case "c", "h": return "c"
        case "cpp", "hpp", "cc", "cxx": return "cpp"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "html", "htm": return "html"
        case "xml": return "xml"
        case "css": return "css"
        case "scss", "sass": return "css"
        case "sh", "bash", "zsh": return "bash"
        case "md", "markdown": return "markdown"
        case "sql": return "sql"
        case "rb": return "ruby"
        case "php": return "php"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        default: return nil
        }
    }
}

// MARK: - Diff Line

/// Represents a single line in a diff view
struct DiffLine: Identifiable, Equatable {
    let id = UUID()
    let lineNumber: Int?
    let content: String
    let type: DiffLineType
    
    enum DiffLineType: Equatable {
        case unchanged
        case added
        case removed
        case context
        case header
    }
}

// MARK: - File Diff

/// Computed diff between before and after content
struct FileDiff: Equatable {
    let fileChange: FileChange
    let lines: [DiffLine]
    let addedCount: Int
    let removedCount: Int
    let unchangedCount: Int
    
    init(fileChange: FileChange) {
        self.fileChange = fileChange
        
        let beforeLines = fileChange.beforeContent?.components(separatedBy: "\n") ?? []
        let afterLines = fileChange.afterContent?.components(separatedBy: "\n") ?? []
        
        // Compute the diff
        let (diffLines, added, removed, unchanged) = Self.computeDiff(before: beforeLines, after: afterLines)
        
        self.lines = diffLines
        self.addedCount = added
        self.removedCount = removed
        self.unchangedCount = unchanged
    }
    
    /// Compute a simple line-by-line diff
    private static func computeDiff(before: [String], after: [String]) -> ([DiffLine], Int, Int, Int) {
        var lines: [DiffLine] = []
        var added = 0
        var removed = 0
        var unchanged = 0
        
        // Use a simple LCS-based diff algorithm
        let lcs = longestCommonSubsequence(before, after)
        
        var beforeIdx = 0
        var afterIdx = 0
        var lcsIdx = 0
        var lineNumber = 1
        
        while beforeIdx < before.count || afterIdx < after.count {
            if lcsIdx < lcs.count {
                // Check if current lines match the LCS
                let lcsLine = lcs[lcsIdx]
                
                // Output removed lines (in before but not at LCS position)
                while beforeIdx < before.count && before[beforeIdx] != lcsLine {
                    lines.append(DiffLine(lineNumber: nil, content: before[beforeIdx], type: .removed))
                    removed += 1
                    beforeIdx += 1
                }
                
                // Output added lines (in after but not at LCS position)
                while afterIdx < after.count && after[afterIdx] != lcsLine {
                    lines.append(DiffLine(lineNumber: lineNumber, content: after[afterIdx], type: .added))
                    added += 1
                    afterIdx += 1
                    lineNumber += 1
                }
                
                // Output the common line
                if beforeIdx < before.count && afterIdx < after.count {
                    lines.append(DiffLine(lineNumber: lineNumber, content: lcsLine, type: .unchanged))
                    unchanged += 1
                    beforeIdx += 1
                    afterIdx += 1
                    lcsIdx += 1
                    lineNumber += 1
                }
            } else {
                // No more LCS - output remaining as removed/added
                while beforeIdx < before.count {
                    lines.append(DiffLine(lineNumber: nil, content: before[beforeIdx], type: .removed))
                    removed += 1
                    beforeIdx += 1
                }
                while afterIdx < after.count {
                    lines.append(DiffLine(lineNumber: lineNumber, content: after[afterIdx], type: .added))
                    added += 1
                    afterIdx += 1
                    lineNumber += 1
                }
            }
        }
        
        return (lines, added, removed, unchanged)
    }
    
    /// Compute longest common subsequence of two string arrays
    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count
        let n = b.count
        
        guard m > 0 && n > 0 else { return [] }
        
        // Build LCS length table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        
        // Backtrack to find the actual LCS
        var result: [String] = []
        var i = m, j = n
        
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                result.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        
        return result.reversed()
    }
    
    /// Summary string for the diff
    var summary: String {
        var parts: [String] = []
        if addedCount > 0 {
            parts.append("+\(addedCount)")
        }
        if removedCount > 0 {
            parts.append("-\(removedCount)")
        }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " ")
    }
}

// MARK: - Pending File Change Approval

/// Model for a file change awaiting user approval
struct PendingFileChangeApproval: Identifiable {
    let id: UUID
    let sessionId: UUID
    let fileChange: FileChange
    let toolName: String
    let toolArgs: [String: String]
    
    init(
        id: UUID = UUID(),
        sessionId: UUID,
        fileChange: FileChange,
        toolName: String,
        toolArgs: [String: String]
    ) {
        self.id = id
        self.sessionId = sessionId
        self.fileChange = fileChange
        self.toolName = toolName
        self.toolArgs = toolArgs
    }
}

// MARK: - File Change Result

/// Result of a file change operation
struct FileChangeResult {
    let success: Bool
    let fileChange: FileChange
    let message: String
    let error: String?
    
    static func success(_ fileChange: FileChange, message: String) -> FileChangeResult {
        FileChangeResult(success: true, fileChange: fileChange, message: message, error: nil)
    }
    
    static func failure(_ fileChange: FileChange, error: String) -> FileChangeResult {
        FileChangeResult(success: false, fileChange: fileChange, message: "", error: error)
    }
}

