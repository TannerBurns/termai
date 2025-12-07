import Foundation

// MARK: - File Operation Type

/// Types of file operations that can be previewed
enum FileOperationType: String, Codable, Equatable {
    case create = "Create"
    case edit = "Edit"
    case insert = "Insert"
    case delete = "Delete"
    case overwrite = "Overwrite"
    case deleteFile = "DeleteFile"
    
    var icon: String {
        switch self {
        case .create: return "doc.badge.plus"
        case .edit: return "pencil"
        case .insert: return "text.insert"
        case .delete: return "trash"
        case .deleteFile: return "trash.fill"
        case .overwrite: return "arrow.triangle.2.circlepath"
        }
    }
    
    var color: String {
        switch self {
        case .create: return "green"
        case .edit: return "blue"
        case .insert: return "cyan"
        case .delete: return "red"
        case .deleteFile: return "red"
        case .overwrite: return "orange"
        }
    }
    
    var description: String {
        switch self {
        case .create: return "New file"
        case .edit: return "Edit file"
        case .insert: return "Insert lines"
        case .delete: return "Delete lines"
        case .deleteFile: return "Delete file"
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

// MARK: - Hunk Decision

/// Tracks the user's decision for a specific hunk during approval
enum HunkDecision: Equatable {
    case pending
    case accepted
    case rejected
}

// MARK: - Diff Hunk

/// Represents a contiguous block of changes in a diff (like git hunks)
/// Groups consecutive added/removed lines with surrounding context
struct DiffHunk: Identifiable, Equatable {
    let id: UUID
    
    /// Line range in the original (before) file
    let oldStartLine: Int
    let oldLineCount: Int
    
    /// Line range in the new (after) file
    let newStartLine: Int
    let newLineCount: Int
    
    /// The diff lines that make up this hunk (context + changes)
    let lines: [DiffLine]
    
    /// Index range into the parent FileDiff.lines array
    let lineIndexRange: Range<Int>
    
    init(
        id: UUID = UUID(),
        oldStartLine: Int,
        oldLineCount: Int,
        newStartLine: Int,
        newLineCount: Int,
        lines: [DiffLine],
        lineIndexRange: Range<Int>
    ) {
        self.id = id
        self.oldStartLine = oldStartLine
        self.oldLineCount = oldLineCount
        self.newStartLine = newStartLine
        self.newLineCount = newLineCount
        self.lines = lines
        self.lineIndexRange = lineIndexRange
    }
    
    /// Git-style hunk header (e.g., "@@ -10,5 +12,8 @@")
    var header: String {
        let oldPart = oldLineCount == 1 ? "\(oldStartLine)" : "\(oldStartLine),\(oldLineCount)"
        let newPart = newLineCount == 1 ? "\(newStartLine)" : "\(newStartLine),\(newLineCount)"
        return "@@ -\(oldPart) +\(newPart) @@"
    }
    
    /// Number of added lines in this hunk
    var addedCount: Int {
        lines.filter { $0.type == .added }.count
    }
    
    /// Number of removed lines in this hunk
    var removedCount: Int {
        lines.filter { $0.type == .removed }.count
    }
    
    /// Whether this hunk has any actual changes (not just context)
    var hasChanges: Bool {
        lines.contains { $0.type == .added || $0.type == .removed }
    }
}

// MARK: - FileDiff Hunk Extension

extension FileDiff {
    /// Number of context lines to include around each change block
    static let contextLines = 3
    
    /// Group diff lines into hunks with context
    var hunks: [DiffHunk] {
        guard !lines.isEmpty else { return [] }
        
        var result: [DiffHunk] = []
        var currentHunkLines: [DiffLine] = []
        var hunkStartIndex = 0
        var oldLineNum = 1
        var newLineNum = 1
        var hunkOldStart = 1
        var hunkNewStart = 1
        var lastChangeIndex = -1
        
        for (index, line) in lines.enumerated() {
            let isChange = line.type == .added || line.type == .removed
            
            if isChange {
                // Start a new hunk if we're too far from the last change
                if lastChangeIndex >= 0 && index - lastChangeIndex > Self.contextLines * 2 {
                    // Finalize the current hunk
                    if !currentHunkLines.isEmpty {
                        // Trim trailing context to contextLines
                        let trailingContextCount = currentHunkLines.reversed().prefix(while: { $0.type == .unchanged }).count
                        let trimCount = max(0, trailingContextCount - Self.contextLines)
                        if trimCount > 0 {
                            currentHunkLines.removeLast(trimCount)
                        }
                        
                        let oldCount = currentHunkLines.filter { $0.type == .removed || $0.type == .unchanged }.count
                        let newCount = currentHunkLines.filter { $0.type == .added || $0.type == .unchanged }.count
                        
                        result.append(DiffHunk(
                            oldStartLine: hunkOldStart,
                            oldLineCount: oldCount,
                            newStartLine: hunkNewStart,
                            newLineCount: newCount,
                            lines: currentHunkLines,
                            lineIndexRange: hunkStartIndex..<(hunkStartIndex + currentHunkLines.count)
                        ))
                    }
                    
                    // Start new hunk with leading context
                    currentHunkLines = []
                    hunkStartIndex = max(0, index - Self.contextLines)
                    
                    // Add leading context
                    let contextStart = max(0, index - Self.contextLines)
                    for i in contextStart..<index {
                        currentHunkLines.append(lines[i])
                    }
                    
                    // Update start line numbers
                    hunkOldStart = oldLineNum - currentHunkLines.filter { $0.type == .unchanged || $0.type == .removed }.count
                    hunkNewStart = newLineNum - currentHunkLines.filter { $0.type == .unchanged || $0.type == .added }.count
                }
                
                // If this is the first change, start the hunk
                if currentHunkLines.isEmpty {
                    hunkStartIndex = max(0, index - Self.contextLines)
                    
                    // Add leading context
                    let contextStart = max(0, index - Self.contextLines)
                    for i in contextStart..<index {
                        currentHunkLines.append(lines[i])
                    }
                    
                    hunkOldStart = oldLineNum - currentHunkLines.filter { $0.type == .unchanged || $0.type == .removed }.count
                    hunkNewStart = newLineNum - currentHunkLines.filter { $0.type == .unchanged || $0.type == .added }.count
                }
                
                lastChangeIndex = index
            }
            
            // Add line to current hunk if we're building one
            if lastChangeIndex >= 0 && index >= hunkStartIndex {
                if !currentHunkLines.contains(where: { $0.id == line.id }) {
                    currentHunkLines.append(line)
                }
            }
            
            // Track line numbers
            switch line.type {
            case .unchanged:
                oldLineNum += 1
                newLineNum += 1
            case .removed:
                oldLineNum += 1
            case .added:
                newLineNum += 1
            default:
                break
            }
        }
        
        // Finalize last hunk
        if !currentHunkLines.isEmpty {
            // Trim trailing context to contextLines
            let trailingContextCount = currentHunkLines.reversed().prefix(while: { $0.type == .unchanged }).count
            let trimCount = max(0, trailingContextCount - Self.contextLines)
            if trimCount > 0 {
                currentHunkLines.removeLast(trimCount)
            }
            
            let oldCount = currentHunkLines.filter { $0.type == .removed || $0.type == .unchanged }.count
            let newCount = currentHunkLines.filter { $0.type == .added || $0.type == .unchanged }.count
            
            result.append(DiffHunk(
                oldStartLine: hunkOldStart,
                oldLineCount: oldCount,
                newStartLine: hunkNewStart,
                newLineCount: newCount,
                lines: currentHunkLines,
                lineIndexRange: hunkStartIndex..<(hunkStartIndex + currentHunkLines.count)
            ))
        }
        
        return result
    }
    
    /// Apply only the accepted hunks and return the resulting content
    /// - Parameter decisions: Map of hunk ID to decision
    /// - Returns: The file content with only accepted hunks applied
    func applyPartialHunks(decisions: [UUID: HunkDecision]) -> String {
        let beforeLines = fileChange.beforeContent?.components(separatedBy: "\n") ?? []
        var resultLines = beforeLines
        
        // Sort hunks by their position in the file (reverse order for safe modification)
        let sortedHunks = hunks.sorted { $0.oldStartLine > $1.oldStartLine }
        
        for hunk in sortedHunks {
            let decision = decisions[hunk.id] ?? .pending
            
            // Only apply accepted hunks
            guard decision == .accepted else { continue }
            
            // Calculate the lines to remove and add
            let removedLines = hunk.lines.filter { $0.type == .removed }
            let addedLines = hunk.lines.filter { $0.type == .added }
            
            // Find the range in resultLines to replace
            let startIdx = max(0, hunk.oldStartLine - 1)
            let endIdx = min(resultLines.count, startIdx + removedLines.count)
            
            // Replace the old lines with new lines
            let newContent = addedLines.map { $0.content }
            if startIdx < resultLines.count {
                resultLines.replaceSubrange(startIdx..<endIdx, with: newContent)
            } else {
                resultLines.append(contentsOf: newContent)
            }
        }
        
        return resultLines.joined(separator: "\n")
    }
}

// MARK: - Diff History Entry

/// Represents a file change in the session history for navigation
struct DiffHistoryEntry: Identifiable, Equatable {
    let id: UUID
    let fileChange: FileChange
    let checkpointId: UUID?
    let sequenceNumber: Int
    
    init(
        id: UUID = UUID(),
        fileChange: FileChange,
        checkpointId: UUID? = nil,
        sequenceNumber: Int
    ) {
        self.id = id
        self.fileChange = fileChange
        self.checkpointId = checkpointId
        self.sequenceNumber = sequenceNumber
    }
    
    /// Display title for the history entry
    var title: String {
        "\(fileChange.operationType.description): \(fileChange.fileName)"
    }
    
    /// Formatted timestamp
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: fileChange.timestamp)
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

