import Foundation
import TermAIModels

// Re-export types from TermAIModels for convenience
// These are the core types that are now defined in the testable TermAIModels module:
// - TokenEstimator
// - TaskStatus, TaskChecklistItem, TaskChecklist
// - LineRange
// - PinnedContextType

// MARK: - Chat Message Types (types with dependencies on other app modules)

struct AgentEvent: Codable, Equatable {
    var kind: String // "status", "step", "summary", "checklist", "file_change", "plan_created"
    var title: String
    var details: String? = nil
    var command: String? = nil
    var output: String? = nil
    var collapsed: Bool? = true
    var checklistItems: [TaskChecklistItem]? = nil
    var fileChange: FileChange? = nil
    /// For pending approvals - the approval ID to respond to
    var pendingApprovalId: UUID? = nil
    /// Tool name for the pending approval
    var pendingToolName: String? = nil
    /// For tool calls - track the tool call ID to update this event later
    var toolCallId: String? = nil
    /// Tool execution status: "running", "succeeded", "failed"
    var toolStatus: String? = nil
    /// Whether this is an internal/low-value event (hidden unless verbose mode)
    var isInternal: Bool? = nil
    /// Category for grouping: "tool", "profile", "progress", etc. Events with a category can be grouped together.
    var eventCategory: String? = nil
    /// For plan_created events - the ID of the created plan
    var planId: UUID? = nil
}

// MARK: - Pinned Context (File Attachments)
// Note: PinnedContextType and LineRange are imported from TermAIModels

/// Represents an attached context (file, terminal output, etc.) for a chat message
struct PinnedContext: Codable, Identifiable, Equatable {
    let id: UUID
    let type: PinnedContextType
    let path: String        // file path, or "terminal" for terminal context
    let displayName: String // short name for display (e.g., filename)
    let content: String     // selected content (from ranges)
    let fullContent: String? // full file content (for viewer highlighting)
    let lineRanges: [LineRange]? // multiple line ranges
    var summary: String?    // for large content (LLM-generated summary)
    let timestamp: Date
    
    // Legacy support
    var startLine: Int? { lineRanges?.first?.start }
    var endLine: Int? { lineRanges?.last?.end }
    
    init(
        id: UUID = UUID(),
        type: PinnedContextType,
        path: String,
        displayName: String? = nil,
        content: String,
        fullContent: String? = nil,
        lineRanges: [LineRange]? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.type = type
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.content = content
        self.fullContent = fullContent
        self.lineRanges = lineRanges
        self.summary = summary
        self.timestamp = Date()
    }
    
    /// Create a file context with optional line ranges
    static func file(path: String, content: String, fullContent: String? = nil, lineRanges: [LineRange]? = nil) -> PinnedContext {
        PinnedContext(type: .file, path: path, content: content, fullContent: fullContent, lineRanges: lineRanges)
    }
    
    /// Create a file context with a single range (legacy support)
    static func file(path: String, content: String, startLine: Int? = nil, endLine: Int? = nil) -> PinnedContext {
        let ranges: [LineRange]?
        if let start = startLine {
            ranges = [LineRange(start: start, end: endLine ?? start)]
        } else {
            ranges = nil
        }
        return PinnedContext(type: .file, path: path, content: content, lineRanges: ranges)
    }
    
    /// Create a terminal context
    static func terminal(content: String, cwd: String? = nil) -> PinnedContext {
        PinnedContext(type: .terminal, path: cwd ?? "terminal", displayName: "Terminal Output", content: content)
    }
    
    /// Check if content is large (>5000 tokens estimated)
    var isLargeContent: Bool {
        TokenEstimator.estimateTokens(content) > 5000
    }
    
    /// Check if this is a partial file (has line ranges)
    var isPartialFile: Bool {
        lineRanges != nil && !lineRanges!.isEmpty
    }
    
    /// Get line range description if applicable
    var lineRangeDescription: String? {
        guard let ranges = lineRanges, !ranges.isEmpty else { return nil }
        if ranges.count == 1 {
            let r = ranges[0]
            return r.start == r.end ? "line \(r.start)" : "lines \(r.start)-\(r.end)"
        } else {
            // Multiple ranges: "L10-50, L80-100"
            return ranges.map { $0.description }.joined(separator: ", ")
        }
    }
    
    /// Check if a line number is within any of the selected ranges
    func isLineSelected(_ lineNumber: Int) -> Bool {
        guard let ranges = lineRanges else { return false }
        return ranges.contains { $0.contains(lineNumber) }
    }
    
    /// Icon for the context type
    var icon: String {
        switch type {
        case .file: return "doc.text.fill"
        case .terminal: return "terminal.fill"
        case .snippet: return "text.quote"
        }
    }
    
    /// Detected language for syntax highlighting
    var language: String? {
        guard type == .file else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
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
        case "cpp", "hpp", "cc": return "cpp"
        case "md", "markdown": return "markdown"
        case "sh", "bash", "zsh": return "shell"
        default: return nil
        }
    }
}

// MARK: - Chat Message

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var role: String
    var content: String
    var timestamp: Date = Date()  // Timezone-aware timestamp for when message was created
    var terminalContext: String? = nil
    var terminalContextMeta: TerminalContextMeta? = nil
    var agentEvent: AgentEvent? = nil
    var attachedContexts: [PinnedContext]? = nil  // Pinned files/contexts attached to this message
}
