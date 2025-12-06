import Foundation
import SwiftUI

// MARK: - Token Estimation

/// Utility for estimating token counts from text
enum TokenEstimator {
    /// Default characters per token (conservative estimate for English text)
    private static let defaultCharsPerToken: Double = 3.8
    
    /// Get model-specific characters per token ratio for more accurate estimation
    static func charsPerToken(for model: String) -> Double {
        let lowercased = model.lowercased()
        
        // Claude models use a more aggressive tokenizer (~3.5 chars/token)
        if lowercased.contains("claude") {
            return 3.5
        }
        
        // GPT-4, GPT-5, and o-series models average ~4 chars/token
        if lowercased.contains("gpt-4") || lowercased.contains("gpt-5") ||
           lowercased.hasPrefix("o1") || lowercased.hasPrefix("o3") || lowercased.hasPrefix("o4") {
            return 4.0
        }
        
        // LLaMA/Mistral/local models often have similar tokenization to GPT
        if lowercased.contains("llama") || lowercased.contains("mistral") ||
           lowercased.contains("qwen") || lowercased.contains("gemma") {
            return 4.0
        }
        
        // Default fallback
        return defaultCharsPerToken
    }
    
    /// Estimate token count from text using model-specific ratio
    static func estimateTokens(_ text: String, model: String = "") -> Int {
        let ratio = model.isEmpty ? defaultCharsPerToken : charsPerToken(for: model)
        return Int(ceil(Double(text.count) / ratio))
    }
    
    /// Estimate tokens from a collection of strings using model-specific ratio
    static func estimateTokens(_ texts: [String], model: String = "") -> Int {
        texts.reduce(0) { $0 + estimateTokens($1, model: model) }
    }
    
    /// Get the context window limit for a model (in tokens)
    static func contextLimit(for modelId: String) -> Int {
        // GPT-5 series
        if modelId.contains("gpt-5") { return 128_000 }
        
        // GPT-4 series
        if modelId.contains("gpt-4o") || modelId.contains("gpt-4.1") { return 128_000 }
        if modelId.contains("gpt-4-turbo") { return 128_000 }
        
        // O-series reasoning models
        if modelId.hasPrefix("o4") || modelId.hasPrefix("o3") || modelId.hasPrefix("o1") { return 200_000 }
        
        // Claude 4.x series
        if modelId.contains("claude-opus-4") || modelId.contains("claude-sonnet-4") || modelId.contains("claude-haiku-4") {
            return 200_000
        }
        
        // Claude 3.7/3.5 series
        if modelId.contains("claude-3-7") || modelId.contains("claude-3-5") { return 200_000 }
        
        // Default for unknown models (conservative)
        return 32_000
    }
    
    /// Get recommended max context usage (leaving room for response)
    static func maxContextUsage(for modelId: String) -> Int {
        let limit = contextLimit(for: modelId)
        // Reserve 25% for response generation
        return Int(Double(limit) * 0.75)
    }
}

// MARK: - Chat Message Types

struct AgentEvent: Codable, Equatable {
    var kind: String // "status", "step", "summary", "checklist", "file_change"
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
}

// MARK: - Task Checklist

enum TaskStatus: String, Codable, Equatable {
    case pending = "pending"
    case inProgress = "in_progress"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
    
    var emoji: String {
        switch self {
        case .pending: return "○"
        case .inProgress: return "→"
        case .completed: return "✓"
        case .failed: return "✗"
        case .skipped: return "⊘"
        }
    }
}

struct TaskChecklistItem: Codable, Equatable, Identifiable {
    let id: Int
    let description: String
    var status: TaskStatus
    var verificationNote: String?
    
    var displayString: String {
        var str = "\(status.emoji) \(id). \(description)"
        if let note = verificationNote {
            str += " [\(note)]"
        }
        return str
    }
}

struct TaskChecklist: Codable, Equatable {
    var items: [TaskChecklistItem]
    var goalDescription: String
    
    init(from plan: [String], goal: String) {
        self.goalDescription = goal
        self.items = plan.enumerated().map { idx, step in
            TaskChecklistItem(id: idx + 1, description: step, status: .pending, verificationNote: nil)
        }
    }
    
    mutating func updateStatus(for itemId: Int, status: TaskStatus, note: String? = nil) {
        if let idx = items.firstIndex(where: { $0.id == itemId }) {
            items[idx].status = status
            if let note = note {
                items[idx].verificationNote = note
            }
        }
    }
    
    mutating func markInProgress(_ itemId: Int) {
        updateStatus(for: itemId, status: .inProgress)
    }
    
    mutating func markCompleted(_ itemId: Int, note: String? = nil) {
        updateStatus(for: itemId, status: .completed, note: note)
    }
    
    mutating func markFailed(_ itemId: Int, note: String? = nil) {
        updateStatus(for: itemId, status: .failed, note: note)
    }
    
    var completedCount: Int {
        items.filter { $0.status == .completed }.count
    }
    
    var progressPercent: Int {
        guard !items.isEmpty else { return 0 }
        return Int((Double(completedCount) / Double(items.count)) * 100)
    }
    
    var currentItem: TaskChecklistItem? {
        items.first { $0.status == .inProgress } ?? items.first { $0.status == .pending }
    }
    
    var isComplete: Bool {
        items.allSatisfy { $0.status == .completed || $0.status == .skipped }
    }
    
    var displayString: String {
        var str = "CHECKLIST (\(completedCount)/\(items.count) completed - \(progressPercent)%):\n"
        str += items.map { $0.displayString }.joined(separator: "\n")
        return str
    }
    
    /// Get remaining items that haven't been completed or skipped
    var remainingItems: [TaskChecklistItem] {
        items.filter { $0.status == .pending || $0.status == .inProgress || $0.status == .failed }
    }
}

// MARK: - Pinned Context (File Attachments)

/// Type of attached context
enum PinnedContextType: String, Codable, Equatable {
    case file       // File from the filesystem
    case terminal   // Terminal output
    case snippet    // User-provided code snippet
}

/// Represents a line range (start and end are 1-indexed, inclusive)
struct LineRange: Codable, Equatable, Hashable {
    let start: Int
    let end: Int
    
    init(start: Int, end: Int) {
        self.start = min(start, end)
        self.end = max(start, end)
    }
    
    /// Single line
    init(line: Int) {
        self.start = line
        self.end = line
    }
    
    /// Parse a range string like "10-50" or "100"
    static func parse(_ str: String) -> LineRange? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("-") {
            let parts = trimmed.split(separator: "-")
            guard parts.count == 2,
                  let start = Int(parts[0]),
                  let end = Int(parts[1]) else { return nil }
            return LineRange(start: start, end: end)
        } else if let line = Int(trimmed) {
            return LineRange(line: line)
        }
        return nil
    }
    
    /// Parse multiple ranges from a comma-separated string like "10-50,80-100"
    static func parseMultiple(_ str: String) -> [LineRange] {
        str.split(separator: ",").compactMap { parse(String($0)) }
    }
    
    var description: String {
        start == end ? "L\(start)" : "L\(start)-\(end)"
    }
    
    /// Check if a line number is within this range
    func contains(_ line: Int) -> Bool {
        line >= start && line <= end
    }
}

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

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var role: String
    var content: String
    var terminalContext: String? = nil
    var terminalContextMeta: TerminalContextMeta? = nil
    var agentEvent: AgentEvent? = nil
    var attachedContexts: [PinnedContext]? = nil  // Pinned files/contexts attached to this message
}

// MARK: - Chat Session

/// A completely self-contained chat session with its own state, messages, and streaming
@MainActor
final class ChatSession: ObservableObject, Identifiable, ShellCommandExecutor, PlanTrackDelegate {
    let id: UUID
    
    // Chat state
    @Published var messages: [ChatMessage] = [] {
        didSet {
            // Reactively update context token count when messages change
            // Use persist: false to avoid disk I/O on every change during streaming
            updateContextUsage(persist: false)
        }
    }
    @Published var sessionTitle: String = ""
    @Published var streamingMessageId: UUID? = nil
    @Published var pendingTerminalContext: String? = nil
    @Published var pendingTerminalMeta: TerminalContextMeta? = nil
    @Published var pendingAttachedContexts: [PinnedContext] = []  // Files/contexts to attach to next message
    @Published var agentModeEnabled: Bool = false
    @Published var agentContextLog: [String] = [] {
        didSet {
            // Reactively update context token count when agent context changes
            updateContextUsage(persist: false)
        }
    }
    @Published var lastKnownCwd: String = ""
    @Published var agentChecklist: TaskChecklist? = nil
    
    // Agent execution state machine
    @Published var agentExecutionPhase: AgentExecutionPhase = .idle
    
    // User feedback queue - allows users to provide input while agent is running
    @Published var pendingUserFeedback: [String] = []
    
    // Computed properties - unified tracking using checklist as source of truth when available
    var isAgentRunning: Bool { agentExecutionPhase.isActive }
    
    /// Current step: completed checklist items + 1 (for the current in-progress item), or phase step
    var agentCurrentStep: Int {
        if let checklist = agentChecklist {
            // Use checklist progress: completed + in-progress count
            let completed = checklist.completedCount
            let inProgress = checklist.items.filter { $0.status == .inProgress }.count
            return completed + inProgress
        }
        return agentExecutionPhase.currentStep
    }
    
    /// Estimated total steps: checklist item count when available, or phase estimate
    var agentEstimatedSteps: Int {
        if let checklist = agentChecklist {
            return checklist.items.count
        }
        return agentExecutionPhase.estimatedSteps
    }
    
    /// Phase description - shows simpler label when checklist provides the progress info
    var agentPhase: String {
        // When we have a checklist, show a simpler phase label (donut chart shows the numbers)
        if agentChecklist != nil {
            switch agentExecutionPhase {
            case .executing:
                return "Executing"
            case .reflecting:
                return "Reflecting"
            case .verifying:
                return "Verifying"
            case .summarizing:
                return "Summarizing"
            case .waitingForApproval:
                return "Awaiting approval"
            case .waitingForFileLock(let file):
                return "Waiting for \(URL(fileURLWithPath: file).lastPathComponent)"
            default:
                return agentExecutionPhase.description
            }
        }
        return agentExecutionPhase.description
    }
    var isWaitingForFileLock: Bool {
        if case .waitingForFileLock = agentExecutionPhase { return true }
        return false
    }
    var waitingForFile: String? {
        if case .waitingForFileLock(let file) = agentExecutionPhase { return file }
        return nil
    }
    
    // Agent cancellation
    private var agentCancelled: Bool = false
    
    // MARK: - Checkpoint System
    
    /// All checkpoints in this session, ordered by message index
    @Published var checkpoints: [Checkpoint] = []
    
    /// The current checkpoint being built (while agent is processing a user message)
    /// File changes are recorded to this checkpoint until the next user message
    private var currentCheckpoint: Checkpoint?
    
    /// Filename for checkpoint persistence
    private var checkpointsFileName: String { "chat-checkpoints-\(id.uuidString).json" }
    
    // Configuration (each session has its own copy)
    @Published var apiBaseURL: URL
    @Published var apiKey: String?
    @Published var model: String
    @Published var providerName: String
    @Published var availableModels: [String] = []
    @Published var modelFetchError: String? = nil
    @Published var titleGenerationError: ChatAPIError? = nil
    
    // Generation settings
    @Published var temperature: Double = 0.7
    @Published var maxTokens: Int = 4096
    @Published var reasoningEffort: ReasoningEffort = .medium
    
    // Provider type tracking
    @Published var providerType: ProviderType = .local(.ollama)
    
    /// Whether the user has explicitly configured the provider (not just using defaults)
    /// This must be true along with model selection before the session is considered configured
    @Published var hasExplicitlyConfiguredProvider: Bool = false
    
    // Context usage tracking
    @Published var currentContextTokens: Int = 0
    @Published var contextLimitTokens: Int = 32_000
    @Published var lastSummarizationDate: Date? = nil
    @Published var summarizationCount: Int = 0
    /// User-defined context size for local models (nil = use auto-detected/default)
    @Published var customLocalContextSize: Int? = nil
    /// Cumulative tokens used in the current agent run (reset at agent start)
    /// This tracks actual API usage across all LLM calls during agent execution
    @Published var agentSessionTokensUsed: Int = 0
    /// Accumulated context tokens being built up for the next request
    /// This is the actual token count from the API, tracking what's in our context array
    /// Used to know when we need to summarize before the next request
    @Published var accumulatedContextTokens: Int = 0
    
    /// Effective context limit considering custom size for local models
    var effectiveContextLimit: Int {
        if providerType.isLocal, let custom = customLocalContextSize {
            return custom
        }
        return contextLimitTokens
    }
    
    /// Context usage as a percentage (0.0 to 1.0)
    var contextUsagePercent: Double {
        guard effectiveContextLimit > 0 else { return 0 }
        return min(1.0, Double(currentContextTokens) / Double(effectiveContextLimit))
    }
    
    /// Whether summarization occurred recently (within last 5 seconds)
    var recentlySummarized: Bool {
        guard let lastDate = lastSummarizationDate else { return false }
        return Date().timeIntervalSince(lastDate) < 5.0
    }
    
    /// Whether we have at least one real assistant response (not empty/placeholder)
    /// Used to determine when to show context usage indicator
    var hasAssistantResponse: Bool {
        messages.contains { msg in
            msg.role == "assistant" &&
            !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            msg.agentEvent == nil
        }
    }
    
    // System info and prompt - use cached version to avoid blocking main thread
    // Note: For synchronous access (UI), use SystemInfo.cached which may return fast-only data
    // For LLM calls, use getSystemPromptAsync() which waits for full system info
    private var systemInfo: SystemInfo { SystemInfo.cached }
    var systemPrompt: String {
        return systemInfo.injectIntoPrompt()
    }
    
    /// Get system prompt with agent mode instructions when agent mode is enabled
    var agentSystemPrompt: String {
        return systemInfo.injectIntoPromptWithAgentMode()
    }
    
    /// Async version that waits for full system info - use this for LLM calls
    private func getSystemPromptAsync() async -> String {
        let info = await SystemInfo.cachedAsync
        return info.injectIntoPrompt()
    }
    
    /// Async version with agent mode - use this for LLM calls
    /// Uses simplified prompt for native tool calling (tools sent via API)
    private func getAgentSystemPromptAsync() async -> String {
        let info = await SystemInfo.cachedAsync
        return info.injectIntoPromptWithNativeToolCalling()
    }
    
    // Private streaming state
    private var streamingTask: Task<Void, Never>? = nil
    
    // MARK: - Cloud Provider Helpers
    
    /// Whether the current provider is a cloud provider
    var isCloudProvider: Bool {
        providerType.isCloud
    }
    
    /// Get the current cloud provider if applicable
    var currentCloudProvider: CloudProvider? {
        if case .cloud(let provider) = providerType {
            return provider
        }
        return nil
    }
    
    /// Whether the current model supports reasoning/thinking
    var currentModelSupportsReasoning: Bool {
        CuratedModels.supportsReasoning(modelId: model)
    }
    
    /// Whether the session is fully configured (provider explicitly chosen AND model selected)
    /// Used to determine if we should show setup prompt instead of chat
    /// This ensures no data is sent to any API without explicit user consent
    var isConfigured: Bool {
        hasExplicitlyConfiguredProvider && !model.isEmpty
    }
    
    init(
        apiBaseURL: URL = URL(string: "http://localhost:11434/v1")!,
        apiKey: String? = nil,
        model: String = "",
        providerName: String = "Ollama",
        restoredId: UUID? = nil
    ) {
        self.id = restoredId ?? UUID()
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
        self.model = model
        self.providerName = providerName
        
        // Apply default agent mode setting for new sessions (not restored ones)
        if restoredId == nil {
            self.agentModeEnabled = AgentSettings.shared.agentModeEnabledByDefault
        }
        
        // Don't auto-fetch models here - wait until after settings are loaded
        // This prevents overriding the persisted model selection
    }
    
    deinit {
        streamingTask?.cancel()
        if let obs = commandFinishedObserver { NotificationCenter.default.removeObserver(obs) }
    }
    
    func setPendingTerminalContext(_ text: String, meta: TerminalContextMeta?) {
        pendingTerminalContext = text
        pendingTerminalMeta = meta
    }
    
    func clearPendingTerminalContext() {
        pendingTerminalContext = nil
        pendingTerminalMeta = nil
    }
    
    // MARK: - Attached Context Management
    
    /// Add a file to the pending attached contexts
    /// Add a file to the pending attached contexts (legacy - entire file or single range)
    func attachFile(path: String, content: String, startLine: Int? = nil, endLine: Int? = nil) {
        let context = PinnedContext.file(path: path, content: content, startLine: startLine, endLine: endLine)
        pendingAttachedContexts.append(context)
    }
    
    /// Add a file with multiple line ranges to the pending attached contexts
    func attachFileWithRanges(path: String, selectedContent: String, fullContent: String, lineRanges: [LineRange]) {
        let context = PinnedContext.file(path: path, content: selectedContent, fullContent: fullContent, lineRanges: lineRanges)
        pendingAttachedContexts.append(context)
    }
    
    /// Update line ranges for an existing attached context
    func updateAttachedContextLineRanges(id: UUID, lineRanges: [LineRange]) {
        guard let index = pendingAttachedContexts.firstIndex(where: { $0.id == id }) else { return }
        let existing = pendingAttachedContexts[index]
        
        // Get the full content (either stored or from file)
        let fullContent = existing.fullContent ?? existing.content
        let lines = fullContent.components(separatedBy: .newlines)
        
        // Extract selected content based on new ranges
        let selectedContent: String
        if lineRanges.isEmpty {
            selectedContent = fullContent
        } else {
            var selectedLines: [String] = []
            for range in lineRanges.sorted(by: { $0.start < $1.start }) {
                let startIdx = max(0, range.start - 1)
                let endIdx = min(lines.count, range.end)
                guard startIdx < lines.count else { continue }
                selectedLines.append(contentsOf: lines[startIdx..<endIdx])
            }
            selectedContent = selectedLines.joined(separator: "\n")
        }
        
        // Create updated context
        let updated = PinnedContext(
            id: existing.id,
            type: existing.type,
            path: existing.path,
            displayName: existing.displayName,
            content: selectedContent,
            fullContent: fullContent,
            lineRanges: lineRanges.isEmpty ? nil : lineRanges
        )
        
        pendingAttachedContexts[index] = updated
    }
    
    /// Add terminal output to the pending attached contexts
    func attachTerminalOutput(_ content: String, cwd: String? = nil) {
        let context = PinnedContext.terminal(content: content, cwd: cwd)
        pendingAttachedContexts.append(context)
    }
    
    /// Remove an attached context by ID
    func removeAttachedContext(id: UUID) {
        pendingAttachedContexts.removeAll { $0.id == id }
    }
    
    /// Clear all pending attached contexts
    func clearAttachedContexts() {
        pendingAttachedContexts.removeAll()
    }
    
    /// Consume and return pending attached contexts (used when sending a message)
    func consumeAttachedContexts() -> [PinnedContext] {
        let contexts = pendingAttachedContexts
        pendingAttachedContexts.removeAll()
        return contexts
    }
    
    /// Summarize large attached contexts before sending
    /// This processes contexts that exceed the token threshold and generates summaries
    func summarizeLargeContexts() async {
        // Process each context that needs summarization
        var updatedContexts: [PinnedContext] = []
        
        for context in pendingAttachedContexts {
            if context.isLargeContent && context.summary == nil {
                // Generate summary for large content
                if let summary = await generateContextSummary(context) {
                    var updated = context
                    updated.summary = summary
                    updatedContexts.append(updated)
                } else {
                    updatedContexts.append(context)
                }
            } else {
                updatedContexts.append(context)
            }
        }
        
        pendingAttachedContexts = updatedContexts
    }
    
    /// Generate a summary for a large attached context using the LLM
    private func generateContextSummary(_ context: PinnedContext) async -> String? {
        // Skip if model not configured
        guard !model.isEmpty else { return nil }
        
        let prompt = """
        You are summarizing a file that will be used as context for a coding assistant.
        
        File: \(context.displayName)
        Path: \(context.path)
        \(context.language.map { "Language: \($0)" } ?? "")
        
        Provide a concise summary that captures:
        1. The main purpose/functionality of this code
        2. Key functions, classes, or structures defined
        3. Important dependencies or imports
        4. Any notable patterns or configurations
        
        Keep the summary under 500 words. Focus on information that would help an AI understand how to work with or modify this code.
        
        FILE CONTENT:
        ```
        \(context.content.prefix(15000))
        ```
        \(context.content.count > 15000 ? "\n[Content truncated at 15000 characters...]" : "")
        """
        
        do {
            let response = try await requestSimpleCompletion(prompt: prompt, maxTokens: 800)
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            AgentDebugConfig.log("[Summary] Failed to generate summary: \(error)")
            return nil
        }
    }
    
    /// Request a simple completion (non-streaming) for utility tasks like summarization
    private func requestSimpleCompletion(prompt: String, maxTokens: Int = 500) async throws -> String {
        var messageBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a helpful assistant that summarizes code and technical content concisely."],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": maxTokens,
            "temperature": 0.3,
            "stream": false
        ]
        
        let url: URL
        var headers: [String: String] = ["Content-Type": "application/json"]
        
        switch providerType {
        case .cloud(let provider):
            switch provider {
            case .openai:
                url = URL(string: "https://api.openai.com/v1/chat/completions")!
                if let key = CloudAPIKeyManager.shared.getAPIKey(for: .openai) {
                    headers["Authorization"] = "Bearer \(key)"
                }
            case .anthropic:
                // For Anthropic, we need to use a different message format
                url = URL(string: "https://api.anthropic.com/v1/messages")!
                if let key = CloudAPIKeyManager.shared.getAPIKey(for: .anthropic) {
                    headers["x-api-key"] = key
                    headers["anthropic-version"] = "2023-06-01"
                }
                // Anthropic uses a different message format
                messageBody = [
                    "model": model,
                    "max_tokens": maxTokens,
                    "messages": [
                        ["role": "user", "content": prompt]
                    ],
                    "system": "You are a helpful assistant that summarizes code and technical content concisely."
                ]
            case .google:
                // Google AI Studio uses a different URL and message format
                url = CloudProvider.google.baseURL.appendingPathComponent("models/\(model):generateContent")
                if let key = CloudAPIKeyManager.shared.getAPIKey(for: .google) {
                    headers["x-goog-api-key"] = key
                }
                // Google uses a different message format
                // Note: Gemini 2.5 models use reasoning tokens, so we need more output tokens
                // to accommodate both thinking and the actual response
                messageBody = [
                    "contents": [
                        ["role": "user", "parts": [["text": prompt]]]
                    ],
                    "systemInstruction": [
                        "parts": [["text": "You are a helpful assistant that summarizes code and technical content concisely. Be direct and concise."]]
                    ],
                    "generationConfig": [
                        "maxOutputTokens": max(maxTokens, 2048)  // Ensure enough tokens for reasoning + response
                    ]
                ]
            }
        case .local(let provider):
            switch provider {
            case .ollama:
                url = URL(string: "http://127.0.0.1:11434/api/chat")!
            case .lmStudio:
                url = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
            case .vllm:
                url = provider.defaultBaseURL.appendingPathComponent("chat/completions")
            }
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: messageBody)
        request.timeoutInterval = 60
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "Summary", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get summary"])
        }
        
        // Parse response based on provider
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // OpenAI/LM Studio format
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
            // Anthropic format
            if let content = json["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                return text
            }
            // Google AI format
            if let candidates = json["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                return text
            }
            // Ollama format
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        }
        
        throw NSError(domain: "Summary", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not parse response"])
    }
    
    // MARK: - Checkpoint Management
    
    /// Create a new checkpoint at the current message index
    /// Called when a user sends a message to mark a point they can rollback to
    func createCheckpoint(messagePreview: String) {
        let messageIndex = messages.count - 1  // Index of the user message just added
        
        // Finalize any existing checkpoint before creating a new one
        finalizeCurrentCheckpoint()
        
        let checkpoint = Checkpoint(
            messageIndex: messageIndex,
            messagePreview: String(messagePreview.prefix(100))
        )
        
        currentCheckpoint = checkpoint
        AgentDebugConfig.log("[Checkpoint] Created checkpoint at message index \(messageIndex)")
    }
    
    /// Record a file change to the current checkpoint
    /// Should be called BEFORE any file modification to capture the original state
    func recordFileChange(path: String, contentBefore: String?, wasCreated: Bool) {
        guard var checkpoint = currentCheckpoint else {
            AgentDebugConfig.log("[Checkpoint] No current checkpoint - file change not recorded for: \(path)")
            return
        }
        
        // Only record if we haven't already captured this file
        guard checkpoint.fileSnapshots[path] == nil else {
            AgentDebugConfig.log("[Checkpoint] File already recorded in checkpoint: \(path)")
            return
        }
        
        checkpoint.recordFileChange(path: path, contentBefore: contentBefore, wasCreated: wasCreated)
        currentCheckpoint = checkpoint
        AgentDebugConfig.log("[Checkpoint] Recorded file change: \(path) (created: \(wasCreated))")
    }
    
    /// Record a shell command that was executed during this checkpoint
    func recordShellCommand(_ command: String) {
        guard var checkpoint = currentCheckpoint else {
            AgentDebugConfig.log("[Checkpoint] No current checkpoint - shell command not recorded")
            return
        }
        
        checkpoint.recordShellCommand(command)
        currentCheckpoint = checkpoint
        AgentDebugConfig.log("[Checkpoint] Recorded shell command: \(command.prefix(50))...")
    }
    
    /// Finalize the current checkpoint and add it to the checkpoints array
    /// Called when starting a new checkpoint or when the session ends
    func finalizeCurrentCheckpoint() {
        guard let checkpoint = currentCheckpoint else { return }
        
        // Only save checkpoint if it has any recorded changes
        if checkpoint.hasChanges {
            checkpoints.append(checkpoint)
            persistCheckpoints()
            AgentDebugConfig.log("[Checkpoint] Finalized checkpoint with \(checkpoint.modifiedFileCount) files and \(checkpoint.shellCommandsRun.count) commands")
        } else {
            AgentDebugConfig.log("[Checkpoint] Discarding empty checkpoint at message index \(checkpoint.messageIndex)")
        }
        
        currentCheckpoint = nil
    }
    
    /// Get the checkpoint for a specific message index
    func checkpoint(forMessageIndex index: Int) -> Checkpoint? {
        checkpoints.first { $0.messageIndex == index }
    }
    
    /// Get all changes made between a checkpoint and the current state
    /// Returns file changes from this checkpoint through all subsequent checkpoints
    func changesSinceCheckpoint(_ checkpoint: Checkpoint) -> (files: [String: FileSnapshot], commands: [String]) {
        var allFiles: [String: FileSnapshot] = checkpoint.fileSnapshots
        var allCommands: [String] = checkpoint.shellCommandsRun
        
        // Collect changes from all subsequent checkpoints
        for cp in checkpoints where cp.messageIndex > checkpoint.messageIndex {
            for (path, snapshot) in cp.fileSnapshots {
                // Only keep the earliest snapshot for each file
                if allFiles[path] == nil {
                    allFiles[path] = snapshot
                }
            }
            allCommands.append(contentsOf: cp.shellCommandsRun)
        }
        
        // Also include current checkpoint if it exists and is after this checkpoint
        if let current = currentCheckpoint, current.messageIndex > checkpoint.messageIndex {
            for (path, snapshot) in current.fileSnapshots {
                if allFiles[path] == nil {
                    allFiles[path] = snapshot
                }
            }
            allCommands.append(contentsOf: current.shellCommandsRun)
        }
        
        return (allFiles, allCommands)
    }
    
    /// Persist checkpoints to disk
    func persistCheckpoints() {
        let checkpointsToSave = checkpoints
        let fileName = checkpointsFileName
        PersistenceService.saveJSONInBackground(checkpointsToSave, to: fileName)
    }
    
    /// Load checkpoints from disk
    func loadCheckpoints() {
        if let loaded = try? PersistenceService.loadJSON([Checkpoint].self, from: checkpointsFileName) {
            checkpoints = loaded
            AgentDebugConfig.log("[Checkpoint] Loaded \(checkpoints.count) checkpoints")
        }
    }
    
    /// Clear all checkpoints (used when clearing chat)
    func clearCheckpoints() {
        checkpoints.removeAll()
        currentCheckpoint = nil
        
        // Delete the checkpoints file
        if let dir = try? PersistenceService.appSupportDirectory() {
            let file = dir.appendingPathComponent(checkpointsFileName)
            try? FileManager.default.removeItem(at: file)
        }
    }
    
    /// Rollback to a specific checkpoint, restoring files and truncating messages
    /// - Parameters:
    ///   - checkpoint: The checkpoint to rollback to
    ///   - removeUserMessage: If true, also removes the user message at this checkpoint (for edit scenarios)
    /// - Returns: A RollbackResult describing what was done
    func rollbackToCheckpoint(_ checkpoint: Checkpoint, removeUserMessage: Bool = false) -> RollbackResult {
        // Cancel any ongoing streaming or agent work
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageId = nil
        if isAgentRunning {
            cancelAgent()
        }
        
        // Collect all file changes from this checkpoint onwards
        let (allFiles, allCommands) = changesSinceCheckpoint(checkpoint)
        
        // Restore files to their original state
        var restoredFiles: [String] = []
        var failedFiles: [(path: String, error: String)] = []
        
        for (path, snapshot) in allFiles {
            do {
                if snapshot.wasCreated {
                    // File was created by agent - delete it
                    if FileManager.default.fileExists(atPath: path) {
                        try FileManager.default.removeItem(atPath: path)
                        restoredFiles.append(path)
                        AgentDebugConfig.log("[Rollback] Deleted created file: \(path)")
                    }
                } else if let originalContent = snapshot.contentBefore {
                    // File existed before - restore original content
                    try originalContent.write(toFile: path, atomically: true, encoding: .utf8)
                    restoredFiles.append(path)
                    AgentDebugConfig.log("[Rollback] Restored file: \(path)")
                }
            } catch {
                failedFiles.append((path: path, error: error.localizedDescription))
                AgentDebugConfig.log("[Rollback] Failed to restore \(path): \(error)")
            }
        }
        
        // Truncate messages to the checkpoint's message index
        // If removeUserMessage is true, remove the user message too (for edit scenarios)
        let targetMessageCount = removeUserMessage ? checkpoint.messageIndex : checkpoint.messageIndex + 1
        let messagesRemoved = messages.count - targetMessageCount
        if messages.count > targetMessageCount {
            messages = Array(messages.prefix(targetMessageCount))
            persistMessages()
            AgentDebugConfig.log("[Rollback] Truncated messages from \(messages.count + messagesRemoved) to \(messages.count)")
        }
        
        // Remove checkpoints after this one
        checkpoints.removeAll { $0.messageIndex >= checkpoint.messageIndex }
        currentCheckpoint = nil
        persistCheckpoints()
        
        // Reset agent-related state
        agentContextLog.removeAll()
        agentChecklist = nil
        resetContextTracking()
        
        let result = RollbackResult(
            success: failedFiles.isEmpty,
            restoredFiles: restoredFiles,
            failedFiles: failedFiles,
            messagesRemoved: messagesRemoved,
            shellCommandsWarning: allCommands
        )
        
        AgentDebugConfig.log("[Rollback] Completed: \(result.summary)")
        return result
    }
    
    /// Branch from a checkpoint with a new prompt, keeping the current file state
    /// - Parameters:
    ///   - checkpoint: The checkpoint to branch from
    ///   - newPrompt: The new user message to start the branch with
    func branchFromCheckpoint(_ checkpoint: Checkpoint, newPrompt: String) {
        // Cancel any ongoing streaming or agent work
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageId = nil
        if isAgentRunning {
            cancelAgent()
        }
        
        // Truncate messages to the checkpoint's message index (remove the original user message too)
        if messages.count > checkpoint.messageIndex {
            messages = Array(messages.prefix(checkpoint.messageIndex))
            persistMessages()
            AgentDebugConfig.log("[Branch] Truncated messages to index \(checkpoint.messageIndex)")
        }
        
        // Remove this checkpoint and all after it (we're creating a new branch)
        checkpoints.removeAll { $0.messageIndex >= checkpoint.messageIndex }
        currentCheckpoint = nil
        persistCheckpoints()
        
        // Reset agent-related state
        agentContextLog.removeAll()
        agentChecklist = nil
        resetContextTracking()
        
        AgentDebugConfig.log("[Branch] Created branch from checkpoint at message \(checkpoint.messageIndex)")
        
        // Note: The caller should then call sendUserMessage(newPrompt) to continue
    }
    
    /// Get summary of what would be affected by rolling back to a checkpoint
    /// Useful for showing confirmation dialog
    func rollbackPreview(for checkpoint: Checkpoint) -> (filesToRestore: [FileSnapshot], shellCommands: [String], messagesToRemove: Int) {
        let (allFiles, allCommands) = changesSinceCheckpoint(checkpoint)
        let snapshots = Array(allFiles.values)
        let messagesToRemove = messages.count - (checkpoint.messageIndex + 1)
        return (snapshots, allCommands, max(0, messagesToRemove))
    }
    
    func clearChat() {
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageId = nil
        messages = []
        sessionTitle = ""  // Reset title when clearing chat
        resetContextTracking()  // Reset context tracking state
        clearCheckpoints()  // Clear all checkpoints when clearing chat
        persistMessages()
        persistSettings()  // Persist the cleared title
    }
    
    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageId = nil
    }
    
    /// Cancel the current agent execution
    func cancelAgent() {
        AgentDebugConfig.log("[Agent] Cancel requested by user")
        agentCancelled = true
        transitionToPhase(.cancelled)
        
        // Release any file locks held by this session
        FileLockManager.shared.releaseAllLocks(for: self.id)
        
        // Add a message indicating cancellation
        messages.append(ChatMessage(
            role: "assistant",
            content: "",
            agentEvent: AgentEvent(
                kind: "status",
                title: "Agent cancelled",
                details: "User cancelled the agent execution",
                command: nil,
                output: nil,
                collapsed: true
            )
        ))
        messages = messages
        persistMessages()
    }
    
    /// Queue user feedback while agent is running
    /// The feedback will be incorporated into the agent's next decision point
    func queueUserFeedback(_ text: String) {
        guard isAgentRunning else {
            AgentDebugConfig.log("[Agent] Feedback ignored - agent not running")
            return
        }
        
        pendingUserFeedback.append(text)
        AgentDebugConfig.log("[Agent] User feedback queued: \(text.prefix(100))...")
        
        // Add a visible message showing the user's feedback
        messages.append(ChatMessage(
            role: "user",
            content: text,
            agentEvent: AgentEvent(
                kind: "status",
                title: "Feedback for agent",
                details: text,
                command: nil,
                output: nil,
                collapsed: false
            )
        ))
        messages = messages
        persistMessages()
    }
    
    /// Consume and return any pending user feedback
    /// Returns nil if no feedback is pending, otherwise returns all feedback joined
    func consumePendingFeedback() -> String? {
        guard !pendingUserFeedback.isEmpty else { return nil }
        
        let feedback = pendingUserFeedback.joined(separator: "\n\n")
        pendingUserFeedback.removeAll()
        AgentDebugConfig.log("[Agent] Consuming user feedback: \(feedback.prefix(100))...")
        return feedback
    }
    
    /// Append a user message without triggering model streaming (used by Agent mode)
    func appendUserMessage(_ text: String) {
        let ctx = pendingTerminalContext
        let meta = pendingTerminalMeta
        pendingTerminalContext = nil
        pendingTerminalMeta = nil

        // Consume any attached contexts (files, etc.)
        // Note: For appendUserMessage (used in agent mode), we consume without async summarization
        // since agent mode has its own context management
        let attachedContexts = consumeAttachedContexts()

        messages.append(ChatMessage(
            role: "user",
            content: text,
            terminalContext: ctx,
            terminalContextMeta: meta,
            attachedContexts: attachedContexts.isEmpty ? nil : attachedContexts
        ))
        // Force UI update and persist
        messages = messages
        persistMessages()
        
        // Create a checkpoint at this user message for rollback capability
        createCheckpoint(messagePreview: text)
    }
    
    func sendUserMessage(_ text: String) async {
        // Validate model is selected
        guard !model.isEmpty else {
            messages.append(ChatMessage(role: "assistant", content: "⚠️ No model selected. Please go to Settings (⌘,) and select a model."))
            return
        }
        // Generate title for the first user message as the very first step (synchronously)
        let isFirstUserMessage = messages.filter { $0.role == "user" }.isEmpty
        if isFirstUserMessage && sessionTitle.isEmpty {
            await generateTitle(from: text)
        }
        if agentModeEnabled {
            // In agent mode we run the agent orchestration instead of directly streaming
            await runAgentOrchestration(for: text)
            return
        }
        
        let ctx = pendingTerminalContext
        let meta = pendingTerminalMeta
        pendingTerminalContext = nil
        pendingTerminalMeta = nil
        
        // Summarize large attached contexts before consuming
        await summarizeLargeContexts()
        
        // Consume any attached contexts (files, etc.)
        let attachedContexts = consumeAttachedContexts()
        
        messages.append(ChatMessage(
            role: "user",
            content: text,
            terminalContext: ctx,
            terminalContextMeta: meta,
            attachedContexts: attachedContexts.isEmpty ? nil : attachedContexts
        ))
        let assistantIndex = messages.count
        messages.append(ChatMessage(role: "assistant", content: ""))
        streamingMessageId = messages[assistantIndex].id
        
        // Update context usage tracking
        updateContextUsage()
        
        // Force UI update
        messages = messages
        
        // Title already generated before sending when needed
        
        // Cancel any previous stream
        streamingTask?.cancel()
        streamingTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                _ = try await self.requestChatCompletionStream(assistantIndex: assistantIndex)
            } catch is CancellationError {
                // ignore
            } catch {
                await MainActor.run { 
                    self.messages.append(ChatMessage(role: "assistant", content: "Error: \(error.localizedDescription)")) 
                }
            }
            await MainActor.run {
                self.streamingMessageId = nil
                self.updateContextUsage()  // Update context after response
                self.persistMessages()
            }
        }
    }

    // MARK: - Agent Orchestration
    private var commandFinishedObserver: NSObjectProtocol? = nil
    
    /// Check if agent was cancelled and log if so. Returns true if cancelled.
    private func checkCancelled(location: String = "") -> Bool {
        if agentCancelled {
            AgentDebugConfig.log("[Agent] Cancelled at: \(location.isEmpty ? "check" : location)")
            return true
        }
        return false
    }
    
    /// Update the checklist message in the UI to reflect current status
    private func updateChecklistMessage() {
        guard let checklist = agentChecklist else { return }
        
        // Find and update the checklist message
        if let idx = messages.lastIndex(where: { $0.agentEvent?.kind == "checklist" }) {
            var msg = messages[idx]
            var evt = msg.agentEvent!
            evt.title = "Task Checklist (\(checklist.completedCount)/\(checklist.items.count) done)"
            evt.details = checklist.displayString
            evt.checklistItems = checklist.items
            msg.agentEvent = evt
            messages[idx] = msg
            messages = messages
            persistMessages()
        }
    }
    
    /// Run verification phase to confirm goal is truly achieved
    /// Returns true if verification passes, false if issues found
    private func runVerificationPhase(goal: String, context: [String]) async -> Bool {
        // Ask the model what verification steps are needed
        let verifyPlanPrompt = """
        The agent believes the goal is complete. Suggest 1-3 quick verification checks to confirm.
        For each check, specify the tool to use (read_file, list_dir, http_request, check_process, command).
        Reply JSON: {"checks": [{"description": "what to verify", "tool": "tool_name", "args": {"arg1": "val1"}}]}
        
        GOAL: \(goal)
        CONTEXT (last 10 entries):\n\(context.suffix(10).joined(separator: "\n"))
        """
        
        let verifyPlan = await callOneShotJSON(prompt: verifyPlanPrompt)
        AgentDebugConfig.log("[Agent] Verification plan: \(verifyPlan.raw)")
        
        // Parse the verification checks
        guard let checksData = verifyPlan.raw.data(using: .utf8),
              let checksJSON = try? JSONDecoder().decode(VerificationChecks.self, from: checksData),
              !checksJSON.checks.isEmpty else {
            // If we can't parse checks, just do a basic file listing
            AgentDebugConfig.log("[Agent] Could not parse verification checks, doing basic check")
            let listResult = await AgentToolRegistry.shared.get("list_dir")?.execute(
                args: ["path": self.lastKnownCwd.isEmpty ? "." : self.lastKnownCwd],
                cwd: self.lastKnownCwd
            )
            agentContextLog.append("VERIFY: Listed directory - \(listResult?.success == true ? "OK" : "Failed")")
            return true
        }
        
        var allPassed = true
        
        for check in checksJSON.checks.prefix(3) {  // Limit to 3 checks
            if agentCancelled { return false }
            
            messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Verifying: \(check.description)", details: "Tool: \(check.tool)", command: nil, output: nil, collapsed: true)))
            messages = messages
            persistMessages()
            
            // Execute the verification tool
            if let tool = AgentToolRegistry.shared.get(check.tool) {
                // Add session ID for file coordination
                var argsWithSession = check.args
                argsWithSession["_sessionId"] = self.id.uuidString
                
                let result = await tool.execute(args: argsWithSession, cwd: self.lastKnownCwd.isEmpty ? nil : self.lastKnownCwd)
                
                agentContextLog.append("VERIFY[\(check.tool)]: \(result.success ? "PASS" : "FAIL") - \(String(result.output.prefix(200)))")
                
                if !result.success {
                    allPassed = false
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "❌ Check failed: \(check.description)", details: result.error ?? result.output, command: nil, output: nil, collapsed: true)))
                } else {
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "✓ Check passed: \(check.description)", details: String(result.output.prefix(300)), command: nil, output: nil, collapsed: true)))
                }
                messages = messages
                persistMessages()
            }
        }
        
        return allPassed
    }
    
    // Struct for parsing verification checks JSON
    private struct VerificationChecks: Decodable {
        let checks: [VerificationCheck]
    }
    
    private struct VerificationCheck: Decodable {
        let description: String
        let tool: String
        let args: [String: String]
        
        enum CodingKeys: String, CodingKey {
            case description, tool, args
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            description = try container.decode(String.self, forKey: .description)
            tool = try container.decode(String.self, forKey: .tool)
            
            // Handle args - try as [String: String] first, then fall back to parsing
            if let stringArgs = try? container.decode([String: String].self, forKey: .args) {
                args = stringArgs
            } else if let rawArgs = try? container.decode([String: VerificationArgValue].self, forKey: .args) {
                var stringArgs: [String: String] = [:]
                for (key, value) in rawArgs {
                    stringArgs[key] = value.stringValue
                }
                args = stringArgs
            } else {
                args = [:]
            }
        }
    }
    
    // Helper for decoding verification args with mixed types
    private struct VerificationArgValue: Decodable {
        let value: Any
        var stringValue: String {
            switch value {
            case let s as String: return s
            case let i as Int: return String(i)
            case let d as Double: return String(d)
            case let b as Bool: return String(b)
            default: return String(describing: value)
            }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) { value = s }
            else if let i = try? container.decode(Int.self) { value = i }
            else if let d = try? container.decode(Double.self) { value = d }
            else if let b = try? container.decode(Bool.self) { value = b }
            else { value = "" }
        }
    }
    
    /// Transition the agent to a new execution phase
    private func transitionToPhase(_ newPhase: AgentExecutionPhase) {
        let oldPhase = agentExecutionPhase
        if oldPhase.canTransition(to: newPhase) {
            agentExecutionPhase = newPhase
            AgentDebugConfig.log("[Agent] Phase: \(oldPhase) -> \(newPhase)")
        } else {
            AgentDebugConfig.log("[Agent] Invalid transition: \(oldPhase) -> \(newPhase)")
            // Force transition anyway for now, but log the issue
            agentExecutionPhase = newPhase
        }
        
        // Update context usage when transitioning to terminal states
        if newPhase.isTerminal || newPhase == .idle {
            updateContextUsage()
        }
    }
    
    private func runAgentOrchestration(for userPrompt: String) async {
        // Reset cancellation state and transition to starting phase
        agentCancelled = false
        transitionToPhase(.starting)
        
        // Set up shell executor and plan track delegate for native tool calling
        AgentToolRegistry.shared.setShellExecutor(self)
        AgentToolRegistry.shared.setPlanTrackDelegate(self)
        defer { 
            // Clean up delegate references
            AgentToolRegistry.shared.setShellExecutor(nil)
            AgentToolRegistry.shared.setPlanTrackDelegate(nil)
            if !agentExecutionPhase.isTerminal {
                transitionToPhase(.idle)
            }
            // Finalize the current checkpoint when agent run ends
            finalizeCurrentCheckpoint()
        }
        
        // Append user message first
        appendUserMessage(userPrompt)
        
        // Clear any stale data from previous agent runs
        AgentToolRegistry.shared.clearSession()
        
        // Agent context maintained as a growing log of tool/command outputs
        agentContextLog = []
        
        // Reset token tracking for this new agent run
        agentSessionTokensUsed = 0
        accumulatedContextTokens = 0
        currentContextTokens = 0
        
        // Reset checklist - agent will create one via plan_and_track tool if needed
        agentChecklist = nil
        
        // Store user prompt for use in reflection/stuck detection
        let userRequest = userPrompt
        
        // Observe terminal completion events targeted to this session
        if commandFinishedObserver == nil {
            commandFinishedObserver = NotificationCenter.default.addObserver(forName: .TermAICommandFinished, object: nil, queue: .main) { [weak self] note in
                guard let self = self else { return }
                Task { @MainActor in
                    guard let sid = note.userInfo?["sessionId"] as? UUID, sid == self.id else { return }
                    let cmd = note.userInfo?["command"] as? String ?? ""
                    let cwd = note.userInfo?["cwd"] as? String ?? ""
                    let rc = note.userInfo?["exitCode"] as? Int32
                    let out = (note.userInfo?["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    self.lastKnownCwd = cwd
                    self.agentContextLog.append("CWD: \(cwd)")
                    if let rc { self.agentContextLog.append("EXIT_CODE: \(rc)") }
                    if !out.isEmpty {
                        self.agentContextLog.append("OUTPUT(\(cmd.prefix(64))): \(out.prefix(AgentSettings.shared.maxOutputCapture))")
                        // Update last status event bubble with output
                        if let idx = self.messages.lastIndex(where: { $0.agentEvent?.command == cmd }) {
                            var msg = self.messages[idx]
                            var evt = msg.agentEvent!
                            evt.output = out
                            msg.agentEvent = evt
                            self.messages[idx] = msg
                            self.messages = self.messages
                            self.persistMessages()
                        }
                    }
                }
            }
        }
        
        var iterations = 0
        let maxIterations = AgentSettings.shared.maxIterations
        var recentCommands: [String] = []  // Track recent commands for stuck detection
        let reflectionInterval = AgentSettings.shared.reflectionInterval
        let stuckThreshold = AgentSettings.shared.stuckDetectionThreshold
        
        // Estimate steps based on checklist if set, otherwise 0 (unknown)
        var estimatedSteps: Int { agentChecklist?.items.count ?? 0 }
        
        stepLoop: while maxIterations == 0 || iterations < maxIterations {
            // Check for cancellation at start of each iteration
            if agentCancelled {
                AgentDebugConfig.log("[Agent] Cancelled by user at iteration start")
                break stepLoop
            }
            
            // Check for user feedback at start of iteration
            if let feedback = consumePendingFeedback() {
                // Add feedback to context log so it's included in the next prompt
                agentContextLog.append("USER FEEDBACK (received during execution): \(feedback)")
                messages.append(ChatMessage(
                    role: "assistant",
                    content: "",
                    agentEvent: AgentEvent(
                        kind: "status",
                        title: "Incorporating user feedback",
                        details: "The agent will consider your feedback in its next action.",
                        command: nil,
                        output: nil,
                        collapsed: true
                    )
                ))
                messages = messages
                persistMessages()
            }
            
            iterations += 1
            transitionToPhase(.executing(step: iterations, estimatedTotal: estimatedSteps))
            
            // Update context usage for real-time tracking (don't persist every iteration)
            updateContextUsage(persist: false)
            
            // Periodic reflection (if enabled)
            if AgentSettings.shared.enableReflection && iterations > 1 && iterations % reflectionInterval == 0 {
                // Check for user feedback before reflection
                if let feedback = consumePendingFeedback() {
                    agentContextLog.append("USER FEEDBACK (before reflection): \(feedback)")
                }
                
                // Build checklist status for reflection
                let checklistStatus = agentChecklist?.displayString ?? "No checklist set"
                let goalForReflection = agentChecklist?.goalDescription ?? userRequest
                
                let reflectionPrompt = """
                Reflect on progress toward the goal. Assess what has been accomplished and what remains.
                
                REFLECTION QUESTIONS:
                1. What files/artifacts have been created or modified?
                2. Have you verified each completed item works correctly?
                3. What is the most likely failure mode at this point?
                4. What verification steps should be done before completion?
                
                Reply JSON: {
                    "progress_percent": 0-100,
                    "on_track": true/false,
                    "completed": ["task1", ...],
                    "remaining": ["task1", ...],
                    "files_created": ["file1.js", ...],
                    "needs_verification": ["what to test"],
                    "should_adjust": true/false,
                    "new_approach": "optional new strategy if should_adjust is true"
                }
                
                GOAL: \(goalForReflection)
                CHECKLIST:\n\(checklistStatus)
                CONTEXT:\n\(agentContextLog.suffix(20).joined(separator: "\n"))
                """
                AgentDebugConfig.log("[Agent] Reflection prompt =>\n\(reflectionPrompt)")
                let reflection = await callOneShotJSON(prompt: reflectionPrompt)
                AgentDebugConfig.log("[Agent] Reflection: \(reflection.raw)")
                
                let progressStr = reflection.progressPercent.map { "\($0)%" } ?? "?"
                let onTrackStr = reflection.onTrack == true ? "On track" : (reflection.onTrack == false ? "May need adjustment" : "Unknown")
                messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Progress Check (\(progressStr))", details: "\(onTrackStr)\n\(reflection.raw)", command: nil, output: nil, collapsed: true)))
                messages = messages
                persistMessages()
                
                // If reflection suggests adjustment, note it in context
                if reflection.shouldAdjust == true, let newApproach = reflection.newApproach, !newApproach.isEmpty {
                    agentContextLog.append("STRATEGY ADJUSTMENT: \(newApproach)")
                }
            }
            
            // Stuck detection
            if recentCommands.count >= stuckThreshold {
                let lastN = recentCommands.suffix(stuckThreshold)
                let firstCmd = lastN.first ?? ""
                let isStuck = lastN.allSatisfy { cmd in
                    // Check if commands are very similar (same prefix or nearly identical)
                    let similarity = cmd.commonPrefix(with: firstCmd).count
                    return Double(similarity) / Double(max(cmd.count, firstCmd.count, 1)) > 0.7
                }
                
                if isStuck {
                    let goalForStuck = agentChecklist?.goalDescription ?? userRequest
                    let stuckPrompt = """
                    The agent appears stuck, running similar commands repeatedly without progress.
                    Recent commands: \(lastN.joined(separator: "; "))
                    Decide: is this truly stuck? If so, suggest a completely different approach.
                    Reply JSON: {"is_stuck": true/false, "new_approach": "different strategy to try", "should_stop": true/false}
                    GOAL: \(goalForStuck)
                    """
                    AgentDebugConfig.log("[Agent] Stuck detection prompt =>\n\(stuckPrompt)")
                    let stuckResult = await callOneShotJSON(prompt: stuckPrompt)
                    AgentDebugConfig.log("[Agent] Stuck result: \(stuckResult.raw)")
                    
                    if stuckResult.shouldStop == true {
                        messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Agent stopped - unable to make progress", details: stuckResult.raw, command: nil, output: nil, collapsed: true)))
                        messages = messages
                        persistMessages()
                        break stepLoop
                    }
                    
                    if stuckResult.isStuck == true, let newApproach = stuckResult.newApproach, !newApproach.isEmpty {
                        messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Trying different approach", details: newApproach, command: nil, output: nil, collapsed: true)))
                        agentContextLog.append("STUCK RECOVERY - NEW APPROACH: \(newApproach)")
                        recentCommands.removeAll()  // Reset to give new approach a chance
                        messages = messages
                        persistMessages()
                    }
                }
            }
            
            // Build context with summarization if needed (only at 95% of context limit)
            var contextBlob = agentContextLog.joined(separator: "\n")
            let contextTokens = TokenEstimator.estimateTokens(contextBlob, model: model)
            let summarizationThreshold = Int(Double(effectiveContextLimit) * 0.95)
            if contextTokens > summarizationThreshold {
                // Summarize older context when approaching context limit
                contextBlob = await summarizeContext(agentContextLog, maxSize: AgentSettings.shared.maxContextSize)
            }
            
            // Build checklist context for the step prompt (checklist is set via plan_and_track tool)
            // Also auto-mark first pending task as in-progress if none are currently in-progress
            let checklistContext: String
            if var checklist = agentChecklist {
                // Auto-mark first pending task as in-progress
                if checklist.items.first(where: { $0.status == .inProgress }) == nil,
                   let firstPending = checklist.items.first(where: { $0.status == .pending }) {
                    checklist.markInProgress(firstPending.id)
                    agentChecklist = checklist
                    updateChecklistMessage()
                    agentContextLog.append("TASK STARTED: #\(firstPending.id) - \(firstPending.description)")
                }
                
                // Build context with current task highlighted
                var context = checklist.displayString
                if let current = checklist.currentItem {
                    context += "\n\nCURRENT TASK: #\(current.id) - \(current.description)"
                }
                checklistContext = context
            } else {
                checklistContext = ""
            }
            
            // Execute step using native tool calling API
            AgentDebugConfig.log("[Agent] Using native tool calling for step \(iterations)")
            
            // Use checklist goal if set, otherwise user's original request
            let currentGoal = agentChecklist?.goalDescription ?? userRequest
            
            let nativeResult = await executeStepWithNativeTools(
                userRequest: userRequest,
                goal: currentGoal,
                contextLog: agentContextLog,
                checklistContext: checklistContext,
                iterations: iterations,
                maxIterations: maxIterations
            )
            
            // Check for errors
            if let error = nativeResult.error {
                AgentDebugConfig.log("[Agent] Native tool calling error: \(error)")
                messages.append(ChatMessage(
                    role: "assistant",
                    content: "",
                    agentEvent: AgentEvent(
                        kind: "status",
                        title: "Agent Error",
                        details: error,
                        command: nil,
                        output: nil,
                        collapsed: false
                    )
                ))
                messages = messages
                persistMessages()
                break stepLoop
            }
            
            // Update checklist based on tool results (auto-mark in-progress items for file operations)
            for (toolName, result) in nativeResult.toolsExecuted {
                // Mark checklist items based on file operations
                if ["write_file", "edit_file", "insert_lines", "delete_lines"].contains(toolName) {
                    if result.success, var checklist = agentChecklist {
                        // Find an in-progress item to mark complete
                        if let inProgressItem = checklist.items.first(where: { $0.status == .inProgress }) {
                            checklist.markCompleted(inProgressItem.id, note: "Done")
                            agentChecklist = checklist
                            updateChecklistMessage()
                        }
                    }
                }
            }
            
            // Check if done
            if nativeResult.isDone {
                if let response = nativeResult.textResponse, !response.isEmpty {
                    // Model provided a text response (completion or answer)
                    transitionToPhase(.summarizing)
                    messages.append(ChatMessage(role: "assistant", content: response))
                    messages = messages
                    persistMessages()
                    transitionToPhase(.completed)
                    break stepLoop
                } else if nativeResult.toolsExecuted.isEmpty {
                    // No tools and no text - something went wrong
                    AgentDebugConfig.log("[Agent] Native tool calling returned no tools and no text")
                }
            }
            // Continue to next iteration
        }
    }
    
    // MARK: - JSON Helper Structs (for decision prompts, not tool execution)
    
    // Legacy JSON tool execution code has been removed.
    // Tool calling now exclusively uses native provider APIs (executeStepWithNativeTools).
    // The structs below are only used for simple decision prompts (RUN vs RESPOND, done assessment, etc.)
    
    // Helper to decode any JSON value and convert to string
    private struct AnyCodable: Decodable {
        let value: Any
        var stringValue: String {
            switch value {
            case let s as String: return s
            case let i as Int: return String(i)
            case let d as Double: return String(d)
            case let b as Bool: return String(b)
            default: return String(describing: value)
            }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) { value = s }
            else if let i = try? container.decode(Int.self) { value = i }
            else if let d = try? container.decode(Double.self) { value = d }
            else if let b = try? container.decode(Bool.self) { value = b }
            else { value = "" }
        }
    }
    
    /// Unified Codable struct for agent JSON responses - decoded in a single pass
    /// Used for simple decision prompts (RUN vs RESPOND, done assessment, planning, etc.)
    /// Tool execution now uses native provider APIs exclusively (see executeStepWithNativeTools).
    private struct UnifiedAgentJSON: Decodable {
        // Decision fields
        let action: String?
        let reason: String?
        
        // Goal/Plan fields
        let goal: String?
        let plan: [String]?
        let estimated_commands: Int?
        
        // Assessment fields
        let done: Bool?
        let decision: String?
        
        // Reflection fields
        let progress_percent: Int?
        let on_track: Bool?
        let completed: [String]?
        let remaining: [String]?
        let should_adjust: Bool?
        let new_approach: String?
        
        // Stuck recovery fields
        let is_stuck: Bool?
        let should_stop: Bool?
    }
    
    /// Parsed JSON response from the agent (for decision prompts only)
    struct AgentJSONResponse {
        let raw: String
        var action: String? = nil
        var reason: String? = nil
        var goal: String? = nil
        var plan: [String]? = nil
        var estimatedCommands: Int? = nil
        var done: Bool? = nil
        var decision: String? = nil
        var progressPercent: Int? = nil
        var onTrack: Bool? = nil
        var completed: [String]? = nil
        var remaining: [String]? = nil
        var shouldAdjust: Bool? = nil
        var newApproach: String? = nil
        var isStuck: Bool? = nil
        var shouldStop: Bool? = nil
    }
    
    private func callOneShotJSON(prompt: String) async -> AgentJSONResponse {
        let text = await callOneShotText(prompt: prompt)
        
        // Strip markdown code blocks if present
        var cleaned = text
        if cleaned.contains("```") {
            // Remove ```json or ``` markers
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
            cleaned = cleaned.replacingOccurrences(of: "```JSON", with: "")
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        }
        
        // Extract JSON object if there's extra text around it
        if let startBrace = cleaned.firstIndex(of: "{"),
           let endBrace = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[startBrace...endBrace])
        }
        
        let compact = cleaned.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let data = compact.data(using: .utf8) ?? Data()
        var response = AgentJSONResponse(raw: compact)
        
        // Decode all fields in a single pass using the unified struct
        if let unified = try? JSONDecoder().decode(UnifiedAgentJSON.self, from: data) {
            response.action = unified.action
            response.reason = unified.reason
            response.goal = unified.goal
            response.plan = unified.plan
            response.estimatedCommands = unified.estimated_commands
            response.done = unified.done
            response.decision = unified.decision
            response.progressPercent = unified.progress_percent
            response.onTrack = unified.on_track
            response.completed = unified.completed
            response.remaining = unified.remaining
            response.shouldAdjust = unified.should_adjust
            response.newApproach = unified.new_approach
            response.isStuck = unified.is_stuck
            response.shouldStop = unified.should_stop
        }
        
        return response
    }
    
    /// Wrapper around callOneShotJSON with retry logic for network failures or empty responses
    private func callOneShotJSONWithRetry(prompt: String, maxRetries: Int = 3) async -> AgentJSONResponse {
        var lastResponse = AgentJSONResponse(raw: "")
        
        for attempt in 1...maxRetries {
            let response = await callOneShotJSON(prompt: prompt)
            lastResponse = response
            
            // Check for valid response - need at least one meaningful field
            let hasContent = (response.action != nil && !response.action!.isEmpty) ||
                           (response.goal != nil && !response.goal!.isEmpty) ||
                           (response.plan != nil && !response.plan!.isEmpty) ||
                           (response.done != nil) ||
                           (response.decision != nil && !response.decision!.isEmpty)
            
            // Check for error response
            let isError = response.raw.contains("\"error\"") ||
                         response.raw.isEmpty ||
                         response.raw == "{}"
            
            if hasContent && !isError {
                return response
            }
            
            // Log retry attempt
            AgentDebugConfig.log("[Agent] Empty/error response (attempt \(attempt)/\(maxRetries)): \(response.raw.prefix(100))")
            
            if attempt < maxRetries {
                // Check for cancellation before retry
                if agentCancelled {
                    AgentDebugConfig.log("[Agent] Cancelled during retry wait")
                    break
                }
                
                // Wait before retry with exponential backoff
                let delay = Double(attempt) * 1.0  // 1s, 2s, 3s
                AgentDebugConfig.log("[Agent] Retrying in \(delay)s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        // If all retries failed, return the last response (even if empty)
        AgentDebugConfig.log("[Agent] All \(maxRetries) retries failed, using last response")
        return lastResponse
    }
    
    private func callOneShotText(prompt: String) async -> String {
        do {
            // Get full system prompt asynchronously to avoid race condition
            let sysPrompt = await getAgentSystemPromptAsync()
            let result = try await LLMClient.shared.completeWithUsage(
                systemPrompt: sysPrompt,
                userPrompt: prompt,
                provider: providerType,
                modelId: model,
                reasoningEffort: currentModelSupportsReasoning ? reasoningEffort : .none,
                temperature: currentModelSupportsReasoning ? 1.0 : 0.2,
                maxTokens: 64000,
                timeout: 60,
                requestType: .planning
            )
            
            // Update cumulative token tracking (total used across all calls)
            agentSessionTokensUsed += result.totalTokens
            
            // Track the maximum accumulated context seen during this agent run
            // During agent execution, multiple LLM calls happen with different prompt sizes:
            // - Step prompts (largest, include full context log)
            // - Decision/assess prompts (may be smaller)
            // We track the MAX to show true peak context usage for UI and summarization decisions
            // Only reset to smaller values after explicit summarization (which sets it to 0)
            if result.promptTokens > accumulatedContextTokens {
                accumulatedContextTokens = result.promptTokens
            }
            
            // Update currentContextTokens for the UI (shows peak context during agent run)
            currentContextTokens = accumulatedContextTokens
            objectWillChange.send()
            
            return result.content
        } catch {
            return "{\"error\":\"\(error.localizedDescription)\"}"
        }
    }
    
    // MARK: - Native Tool Calling
    
    /// Result of a native tool calling step
    struct NativeToolStepResult {
        let textResponse: String?
        let toolsExecuted: [(name: String, result: AgentToolResult)]
        let isDone: Bool
        let error: String?
    }
    
    /// Execute a step using native tool calling APIs
    /// Returns when the model either responds with text (no tool calls) or signals completion
    private func executeStepWithNativeTools(
        userRequest: String,
        goal: String,
        contextLog: [String],
        checklistContext: String,
        iterations: Int,
        maxIterations: Int
    ) async -> NativeToolStepResult {
        // Build the system prompt with workflow guidance
        // On first iteration with no checklist, guide the agent to consider using plan_and_track
        let planningGuidance: String
        if iterations == 1 && checklistContext.isEmpty {
            planningGuidance = """
            
            IMPORTANT - START BY PLANNING:
            Before doing any work, call plan_and_track to set your goal and create a task checklist.
            This helps track progress and ensures systematic execution.
            
            Example: plan_and_track(goal="Build a REST API", tasks=["Set up project structure", "Create endpoints", "Add error handling", "Test the API"])
            
            Only skip planning for truly trivial single-command requests (e.g., "run pwd", "list files").
            """
        } else if !checklistContext.isEmpty {
            planningGuidance = """
            
            TASK TRACKING:
            - Focus on completing the CURRENT TASK shown above
            - When you finish a task, call plan_and_track with complete_task=<id> to mark it done
            - The next pending task will automatically become current
            """
        } else {
            planningGuidance = ""
        }
        
        let systemPrompt = """
        You are a terminal agent executing commands in the user's real shell (PTY).
        Environment changes (cd, source, export) persist in the user's session.
        
        USER REQUEST: \(userRequest)
        \(goal != userRequest ? "GOAL: \(goal)" : "")
        Progress: Step \(iterations) of max \(maxIterations == 0 ? "unlimited" : String(maxIterations))
        
        ENVIRONMENT:
        - CWD: \(self.lastKnownCwd.isEmpty ? "(discover with pwd or list_dir .)" : self.lastKnownCwd)
        - Shell: /bin/zsh
        
        \(checklistContext.isEmpty ? "" : "CHECKLIST:\n\(checklistContext)")
        \(planningGuidance)
        
        RULES:
        - Use the provided tools to accomplish the request
        - For file operations, prefer file tools (read_file, edit_file, etc.) over shell commands
        - Verify your changes by reading files after editing
        - When the task is complete, respond with a summary (no tool calls)
        """
        
        // Build the context as user message
        let contextMessage = "CONTEXT LOG:\n\(contextLog.joined(separator: "\n"))"
        
        // Initial messages for the conversation
        var conversationMessages: [[String: Any]] = [
            ["role": "user", "content": contextMessage]
        ]
        
        // Get tool schemas based on provider
        let toolSchemas: [[String: Any]]
        switch providerType {
        case .cloud(.anthropic):
            toolSchemas = AgentToolRegistry.shared.allSchemas(for: providerType)
        case .cloud(.google):
            toolSchemas = AgentToolRegistry.shared.allTools().map { $0.schema.toGoogle() }
        default:
            // OpenAI and local providers use OpenAI format
            toolSchemas = AgentToolRegistry.shared.allSchemas(for: providerType)
        }
        
        var allToolsExecuted: [(name: String, result: AgentToolResult)] = []
        var lastTextResponse: String? = nil
        var loopCount = 0
        let maxToolLoops = 20 // Prevent infinite tool calling loops
        
        // Tool calling loop - continue until model stops calling tools or we hit limit
        while loopCount < maxToolLoops {
            loopCount += 1
            
            do {
                // Call LLM with tools
                let result = try await LLMClient.shared.completeWithTools(
                    systemPrompt: systemPrompt,
                    messages: conversationMessages,
                    tools: toolSchemas,
                    provider: providerType,
                    modelId: model,
                    maxTokens: 64000,
                    timeout: 120
                )
                
                // Update token tracking
                agentSessionTokensUsed += result.totalTokens
                if result.promptTokens > accumulatedContextTokens {
                    accumulatedContextTokens = result.promptTokens
                }
                currentContextTokens = accumulatedContextTokens
                
                // Check if model returned text without tool calls (indicating completion)
                if !result.hasToolCalls {
                    lastTextResponse = result.content
                    return NativeToolStepResult(
                        textResponse: lastTextResponse,
                        toolsExecuted: allToolsExecuted,
                        isDone: true,
                        error: nil
                    )
                }
                
                // Execute all tool calls
                var toolResults: [(id: String, name: String, result: String, isError: Bool)] = []
                
                for toolCall in result.toolCalls {
                    AgentDebugConfig.log("[NativeTools] Executing tool: \(toolCall.name) with args: \(toolCall.arguments)")
                    
                    // Check if this is a task status update (complete_task or start_task) - these are silent
                    let isTaskStatusUpdate = toolCall.name == "plan_and_track" && 
                        (toolCall.stringArguments["complete_task"] != nil || toolCall.stringArguments["start_task"] != nil)
                    
                    // Add status message for UI (skip for task status updates to reduce clutter)
                    if !isTaskStatusUpdate {
                        messages.append(ChatMessage(
                            role: "assistant",
                            content: "",
                            agentEvent: AgentEvent(
                                kind: "step",
                                title: "Using tool: \(toolCall.name)",
                                details: "Args: \(toolCall.stringArguments)",
                                command: nil,
                                output: nil,
                                collapsed: true
                            )
                        ))
                        messages = messages
                        persistMessages()
                    }
                    
                    // Execute the tool
                    if let tool = AgentToolRegistry.shared.get(toolCall.name) {
                        var args = toolCall.stringArguments
                        args["_sessionId"] = self.id.uuidString
                        
                        // Check if this is a file operation that needs approval flow
                        let isFileOp = ["write_file", "edit_file", "insert_lines", "delete_lines", "delete_file"].contains(toolCall.name)
                        let toolResult: AgentToolResult
                        if isFileOp {
                            toolResult = await executeFileToolWithApproval(
                                tool: tool,
                                toolName: toolCall.name,
                                args: args,
                                cwd: self.lastKnownCwd.isEmpty ? nil : self.lastKnownCwd
                            )
                        } else {
                            toolResult = await tool.execute(
                                args: args,
                                cwd: self.lastKnownCwd.isEmpty ? nil : self.lastKnownCwd
                            )
                        }
                        
                        allToolsExecuted.append((name: toolCall.name, result: toolResult))
                        
                        let resultString = toolResult.success ? toolResult.output : "ERROR: \(toolResult.error ?? "Unknown error")"
                        toolResults.append((
                            id: toolCall.id,
                            name: toolCall.name,
                            result: resultString,
                            isError: !toolResult.success
                        ))
                        
                        // Update context log (but keep it brief for task status updates)
                        if !isTaskStatusUpdate {
                            agentContextLog.append("TOOL: \(toolCall.name) \(toolCall.stringArguments)")
                            agentContextLog.append("RESULT: \(resultString.prefix(AgentSettings.shared.maxOutputCapture))")
                        }
                        
                        // Add result status message (skip for task status updates - checklist UI shows the update)
                        if !isTaskStatusUpdate {
                            messages.append(ChatMessage(
                                role: "assistant",
                                content: "",
                                agentEvent: AgentEvent(
                                    kind: "status",
                                    title: toolResult.success ? "Tool succeeded" : "Tool failed",
                                    details: String(resultString.prefix(500)),
                                    command: nil,
                                    output: resultString,
                                    collapsed: true,
                                    fileChange: toolResult.fileChange
                                )
                            ))
                            messages = messages
                            persistMessages()
                        }
                    } else {
                        // Unknown tool
                        let errorMsg = "Unknown tool: \(toolCall.name)"
                        toolResults.append((id: toolCall.id, name: toolCall.name, result: errorMsg, isError: true))
                        agentContextLog.append("TOOL ERROR: \(errorMsg)")
                    }
                    
                    // Check for cancellation
                    if agentCancelled {
                        return NativeToolStepResult(
                            textResponse: nil,
                            toolsExecuted: allToolsExecuted,
                            isDone: false,
                            error: "Cancelled by user"
                        )
                    }
                }
                
                // Add assistant message with tool calls and tool results based on provider
                switch providerType {
                case .cloud(.anthropic):
                    // Anthropic: assistant message with tool_use content blocks
                    let assistantMsg = ToolResultFormatter.assistantMessageWithToolCallsAnthropic(
                        content: result.content,
                        toolCalls: result.toolCalls
                    )
                    conversationMessages.append(assistantMsg)
                    // Tool results as user message with tool_result blocks
                    let anthropicResults = toolResults.map { (toolUseId: $0.id, result: $0.result, isError: $0.isError) }
                    conversationMessages.append(ToolResultFormatter.userMessageWithToolResultsAnthropic(results: anthropicResults))
                    
                case .cloud(.google):
                    // Google: model message with functionCall parts, then function response
                    let assistantMsg = ToolResultFormatter.assistantMessageWithToolCallsOpenAI(
                        content: result.content,
                        toolCalls: result.toolCalls
                    )
                    conversationMessages.append(assistantMsg)
                    let googleResults = toolResults.map { (name: $0.name, result: ["output": $0.result] as [String: Any]) }
                    conversationMessages.append(ToolResultFormatter.functionResponseMessageGoogle(results: googleResults))
                    
                default:
                    // OpenAI and local - assistant with tool_calls, then tool role messages
                    let assistantMsg = ToolResultFormatter.assistantMessageWithToolCallsOpenAI(
                        content: result.content,
                        toolCalls: result.toolCalls
                    )
                    conversationMessages.append(assistantMsg)
                    for tr in toolResults {
                        conversationMessages.append(ToolResultFormatter.formatForOpenAI(toolCallId: tr.id, result: tr.result))
                    }
                }
                
            } catch let error as LLMClientError {
                if case .toolsNotSupported(let model) = error {
                    return NativeToolStepResult(
                        textResponse: nil,
                        toolsExecuted: allToolsExecuted,
                        isDone: false,
                        error: "Agent mode is not available with '\(model)'. This model does not support tool calling. Please select a different model or disable native tool calling in settings."
                    )
                }
                return NativeToolStepResult(
                    textResponse: nil,
                    toolsExecuted: allToolsExecuted,
                    isDone: false,
                    error: error.localizedDescription
                )
            } catch {
                return NativeToolStepResult(
                    textResponse: nil,
                    toolsExecuted: allToolsExecuted,
                    isDone: false,
                    error: error.localizedDescription
                )
            }
        }
        
        // Hit max tool loops
        return NativeToolStepResult(
            textResponse: "Reached maximum tool execution limit. Please try a more specific request.",
            toolsExecuted: allToolsExecuted,
            isDone: true,
            error: nil
        )
    }
    
    // MARK: - Quick Environment Context
    
    /// Represents quick environment context for agent decision-making
    struct QuickEnvironmentContext {
        let cwd: String
        let directoryContents: [String]
        let gitBranch: String?
        let gitDirty: Bool
        let projectType: String
        
        /// Format context for inclusion in prompts
        func formatted() -> String {
            var lines: [String] = []
            
            lines.append("- Current Directory: \(cwd.isEmpty ? "(unknown)" : cwd)")
            
            if !directoryContents.isEmpty {
                let contents = directoryContents.prefix(20).joined(separator: ", ")
                let suffix = directoryContents.count > 20 ? ", ..." : ""
                lines.append("- Directory Contents: \(contents)\(suffix)")
            }
            
            if let branch = gitBranch {
                let dirtyIndicator = gitDirty ? " (uncommitted changes)" : ""
                lines.append("- Git: branch '\(branch)'\(dirtyIndicator)")
            }
            
            if !projectType.isEmpty && projectType != "unknown" {
                lines.append("- Project Type: \(projectType)")
            }
            
            return lines.joined(separator: "\n")
        }
    }
    
    /// Gather quick environment context for agent decision-making
    /// This provides the agent with enough context to make informed RESPOND vs RUN decisions
    private func gatherQuickContext() async -> QuickEnvironmentContext {
        let cwd = lastKnownCwd.isEmpty ? FileManager.default.currentDirectoryPath : lastKnownCwd
        
        // Get directory contents (top-level only, quick)
        var directoryContents: [String] = []
        if !cwd.isEmpty {
            let url = URL(fileURLWithPath: cwd)
            if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                directoryContents = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item in
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return item.lastPathComponent + (isDir ? "/" : "")
                }
            }
        }
        
        // Get git info asynchronously
        var gitBranch: String? = nil
        var gitDirty = false
        if !cwd.isEmpty {
            if let gitInfo = await GitInfoService.shared.fetchGitInfo(for: cwd) {
                gitBranch = gitInfo.branch
                gitDirty = gitInfo.isDirty
            }
        }
        
        // Detect project type from common files
        let projectType = detectProjectType(from: directoryContents)
        
        return QuickEnvironmentContext(
            cwd: cwd,
            directoryContents: directoryContents,
            gitBranch: gitBranch,
            gitDirty: gitDirty,
            projectType: projectType
        )
    }
    
    /// Detect project type from directory contents
    private func detectProjectType(from contents: [String]) -> String {
        var types: [String] = []
        
        // Python
        if contents.contains("requirements.txt") || contents.contains("setup.py") || 
           contents.contains("pyproject.toml") || contents.contains("Pipfile") ||
           contents.contains("venv/") || contents.contains(".venv/") {
            types.append("Python")
        }
        
        // Node.js
        if contents.contains("package.json") {
            types.append("Node.js")
        }
        
        // Swift
        if contents.contains("Package.swift") || contents.contains(where: { $0.hasSuffix(".xcodeproj/") || $0.hasSuffix(".xcworkspace/") }) {
            types.append("Swift")
        }
        
        // Rust
        if contents.contains("Cargo.toml") {
            types.append("Rust")
        }
        
        // Go
        if contents.contains("go.mod") {
            types.append("Go")
        }
        
        // Ruby
        if contents.contains("Gemfile") {
            types.append("Ruby")
        }
        
        // Java/Kotlin
        if contents.contains("pom.xml") || contents.contains("build.gradle") || contents.contains("build.gradle.kts") {
            types.append("Java/Kotlin")
        }
        
        // Docker
        if contents.contains("Dockerfile") || contents.contains("docker-compose.yml") || contents.contains("docker-compose.yaml") {
            types.append("Docker")
        }
        
        return types.isEmpty ? "unknown" : types.joined(separator: ", ")
    }
    
    /// Summarize context when it exceeds size limits
    /// Uses token estimation with 95% threshold for more accurate context management
    private func summarizeContext(_ contextLog: [String], maxSize: Int) async -> String {
        let fullContext = contextLog.joined(separator: "\n")
        
        // Calculate limits using model-specific token estimation with 95% threshold
        let currentTokens = TokenEstimator.estimateTokens(fullContext, model: model)
        let tokenThreshold = Int(Double(effectiveContextLimit) * 0.95)
        let maxChars = maxSize
        
        // Use token-based limit as primary, with character limit as fallback
        let charsPerTokenRatio = TokenEstimator.charsPerToken(for: model)
        let tokenBasedCharLimit = Int(Double(tokenThreshold) * charsPerTokenRatio)
        let effectiveLimit = min(maxChars, tokenBasedCharLimit)
        
        // If already under 95% threshold, return as-is
        if currentTokens <= tokenThreshold {
            return fullContext
        }
        
        // Record that summarization is occurring
        await MainActor.run { recordSummarization() }
        
        // Keep most recent entries intact (preserve more if model supports larger context)
        let recentCount = min(contextLog.count, effectiveContextLimit > 100_000 ? 15 : 10)
        let recentEntries = contextLog.suffix(recentCount)
        let olderEntries = contextLog.dropLast(recentCount)
        
        if olderEntries.isEmpty {
            // All entries are recent, just truncate
            return String(fullContext.suffix(effectiveLimit))
        }
        
        // Summarize older entries
        let olderText = olderEntries.joined(separator: "\n")
        let olderLimit = min(olderText.count, effectiveLimit / 2)
        
        let summarizePrompt = """
        Summarize the following agent execution context, preserving:
        - Key commands that were run and their outcomes
        - Important errors or warnings
        - Significant progress milestones
        - Current state information
        Be concise but preserve critical information.
        
        CONTEXT TO SUMMARIZE:
        \(String(olderText.prefix(olderLimit)))
        """
        
        let summary = await callOneShotText(prompt: summarizePrompt)
        let summarized = "[SUMMARIZED HISTORY]\n\(summary)\n\n[RECENT ACTIVITY]\n\(recentEntries.joined(separator: "\n"))"
        
        // Update context usage after summarization
        await MainActor.run { updateContextUsage() }
        
        return String(summarized.suffix(effectiveLimit))
    }
    
    /// Summarize long command output
    private func summarizeOutput(_ output: String, command: String) async -> String {
        let settings = AgentSettings.shared
        
        // If output is short enough, return as-is
        if output.count <= settings.maxOutputCapture {
            return output
        }
        
        // If summarization is disabled, just truncate
        if !settings.enableOutputSummarization || output.count <= settings.outputSummarizationThreshold {
            return String(output.prefix(settings.maxOutputCapture)) + "\n... [truncated, \(output.count) total chars]"
        }
        
        // Summarize the output
        let summarizePrompt = """
        Summarize this command output concisely, preserving:
        - Errors and warnings (quote exact error messages)
        - Key results/data
        - File paths mentioned
        - Success/failure indicators
        - Any actionable information
        
        COMMAND: \(command)
        OUTPUT (first \(settings.maxOutputCapture) chars of \(output.count) total):
        \(output.prefix(settings.maxOutputCapture))
        """
        
        let summary = await callOneShotText(prompt: summarizePrompt)
        return "[SUMMARIZED OUTPUT from '\(command)' (\(output.count) chars)]\n\(summary)"
    }
    
    private func lastExitCodeString() -> String {
        // We don't have direct access to PTYModel here; rely on last recorded value from context if present.
        // Look for "EXIT_CODE: N" pattern and extract just the number
        for line in agentContextLog.reversed() {
            if let range = line.range(of: "EXIT_CODE: ") {
                // Extract only the numeric characters immediately following the marker
                var numStr = ""
                var idx = range.upperBound
                while idx < line.endIndex {
                    let char = line[idx]
                    if char.isNumber || (numStr.isEmpty && char == "-") {
                        numStr.append(char)
                    } else {
                        break  // Stop at first non-numeric character
                    }
                    idx = line.index(after: idx)
                }
                if !numStr.isEmpty {
                    return numStr
                }
            }
        }
        return "unknown"
    }

    private func waitForCommandOutput(matching command: String, timeout: TimeInterval) async -> String? {
        let sid = self.id
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var token: NSObjectProtocol?
            var cancelCheckTimer: DispatchSourceTimer?
            var resolved = false
            
            func finish(_ value: String?) {
                guard !resolved else { return }
                resolved = true
                cancelCheckTimer?.cancel()
                cancelCheckTimer = nil
                if let t = token { NotificationCenter.default.removeObserver(t) }
                token = nil
                continuation.resume(returning: value)
            }
            
            // Check for cancellation periodically
            cancelCheckTimer = DispatchSource.makeTimerSource(queue: .main)
            cancelCheckTimer?.schedule(deadline: .now() + 0.5, repeating: 0.5)
            cancelCheckTimer?.setEventHandler { [weak self] in
                if self?.agentCancelled == true {
                    AgentDebugConfig.log("[Agent] Command wait cancelled by user")
                    finish(nil)
                }
            }
            cancelCheckTimer?.resume()
            
            token = NotificationCenter.default.addObserver(forName: .TermAICommandFinished, object: nil, queue: .main) { note in
                guard let noteSid = note.userInfo?["sessionId"] as? UUID, noteSid == sid else { return }
                guard let cmd = note.userInfo?["command"] as? String, cmd == command else { return }
                let out = note.userInfo?["output"] as? String
                finish(out)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
        }
    }
    
    /// Request approval for a command if settings require it
    /// Returns the approved command (possibly edited), or nil if rejected
    private func requestCommandApproval(_ command: String) async -> String? {
        let settings = AgentSettings.shared
        
        // Auto-approve if approval not required or command is read-only and auto-approve is enabled
        if settings.shouldAutoApprove(command) {
            return command
        }
        
        // Post notification requesting approval
        let approvalId = UUID()
        NotificationCenter.default.post(
            name: .TermAICommandPendingApproval,
            object: nil,
            userInfo: [
                "sessionId": self.id,
                "approvalId": approvalId,
                "command": command
            ]
        )
        
        // Add a pending approval message
        messages.append(ChatMessage(
            role: "assistant",
            content: "",
            agentEvent: AgentEvent(
                kind: "status",
                title: "Awaiting command approval",
                details: command,
                command: command,
                output: nil,
                collapsed: false
            )
        ))
        messages = messages
        persistMessages()
        
        // Wait for approval response
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var token: NSObjectProtocol?
            var cancelCheckTimer: DispatchSourceTimer?
            var resolved = false
            
            func finish(_ value: String?) {
                guard !resolved else { return }
                resolved = true
                cancelCheckTimer?.cancel()
                cancelCheckTimer = nil
                if let t = token { NotificationCenter.default.removeObserver(t) }
                token = nil
                continuation.resume(returning: value)
            }
            
            // Check for cancellation periodically
            cancelCheckTimer = DispatchSource.makeTimerSource(queue: .main)
            cancelCheckTimer?.schedule(deadline: .now() + 0.5, repeating: 0.5)
            cancelCheckTimer?.setEventHandler { [weak self] in
                if self?.agentCancelled == true {
                    AgentDebugConfig.log("[Agent] Approval wait cancelled by user")
                    finish(nil)
                }
            }
            cancelCheckTimer?.resume()
            
            token = NotificationCenter.default.addObserver(
                forName: .TermAICommandApprovalResponse,
                object: nil,
                queue: .main
            ) { note in
                guard let noteApprovalId = note.userInfo?["approvalId"] as? UUID,
                      noteApprovalId == approvalId else { return }
                
                let approved = note.userInfo?["approved"] as? Bool ?? false
                let editedCommand = note.userInfo?["command"] as? String
                
                if approved {
                    finish(editedCommand ?? command)
                } else {
                    finish(nil)
                }
            }
            
            // Timeout after 5 minutes (user might be away)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                finish(nil)
            }
        }
    }
    
    /// Execute a command with optional approval flow
    private func executeCommandWithApproval(_ command: String) async -> String? {
        // Request approval if needed
        guard let approvedCommand = await requestCommandApproval(command) else {
            // Command was rejected
            messages.append(ChatMessage(
                role: "assistant",
                content: "",
                agentEvent: AgentEvent(
                    kind: "status",
                    title: "Command rejected",
                    details: "User declined to execute: \(command)",
                    command: nil,
                    output: nil,
                    collapsed: true
                )
            ))
            messages = messages
            persistMessages()
            return nil
        }
        
        // Update status if command was edited
        if approvedCommand != command {
            messages.append(ChatMessage(
                role: "assistant",
                content: "",
                agentEvent: AgentEvent(
                    kind: "status",
                    title: "Command edited by user",
                    details: approvedCommand,
                    command: approvedCommand,
                    output: nil,
                    collapsed: true
                )
            ))
            messages = messages
            persistMessages()
        }
        
        // Execute the command
        let runningTitle = "Executing command in terminal"
        messages.append(ChatMessage(
            role: "assistant",
            content: "",
            agentEvent: AgentEvent(
                kind: "status",
                title: runningTitle,
                details: approvedCommand,
                command: approvedCommand,
                output: nil,
                collapsed: false
            )
        ))
        messages = messages
        persistMessages()
        
        AgentDebugConfig.log("[Agent] Executing command: \(approvedCommand)")
        NotificationCenter.default.post(
            name: .TermAIExecuteCommand,
            object: nil,
            userInfo: [
                "sessionId": self.id,
                "command": approvedCommand
            ]
        )
        
        // Wait for output
        let output = await waitForCommandOutput(matching: approvedCommand, timeout: AgentSettings.shared.commandTimeout)
        
        // Record in context log - note: recentCommands tracking done in caller
        agentContextLog.append("RAN: \(approvedCommand)")
        if let out = output, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Summarize if output is long
            let processedOutput = await summarizeOutput(out, command: approvedCommand)
            agentContextLog.append("OUTPUT: \(processedOutput)")
        }
        
        // Track tool call execution
        TokenUsageTracker.shared.recordToolCall(
            provider: providerName,
            model: model,
            command: approvedCommand
        )
        
        return output
    }
    
    // MARK: - ShellCommandExecutor Protocol
    
    /// Execute a shell command via the terminal PTY (ShellCommandExecutor protocol)
    /// This is used by the ShellCommandTool in the native tool calling flow
    nonisolated func executeShellCommand(_ command: String, requireApproval: Bool) async -> (success: Bool, output: String, exitCode: Int) {
        // Record shell command to checkpoint for rollback warnings
        await MainActor.run {
            recordShellCommand(command)
        }
        
        // Execute the command
        // Always require approval for destructive commands (rm, rmdir), regardless of settings
        let output: String?
        if AgentSettings.shared.isDestructiveCommand(command) ||
           (requireApproval && !AgentSettings.shared.shouldAutoApprove(command)) {
            output = await executeCommandWithApproval(command)
        } else {
            // Direct execution
            await MainActor.run {
                AgentDebugConfig.log("[ShellTool] Executing command: \(command)")
                NotificationCenter.default.post(
                    name: .TermAIExecuteCommand,
                    object: nil,
                    userInfo: [
                        "sessionId": self.id,
                        "command": command
                    ]
                )
            }
            output = await waitForCommandOutput(matching: command, timeout: AgentSettings.shared.commandTimeout)
            
            await MainActor.run {
                agentContextLog.append("RAN: \(command)")
                TokenUsageTracker.shared.recordToolCall(
                    provider: providerName,
                    model: model,
                    command: command
                )
            }
        }
        
        // Get exit code from context log
        let exitCode = await MainActor.run { () -> Int in
            let exitStr = lastExitCodeString()
            return Int(exitStr) ?? -1
        }
        
        let success = exitCode == 0
        let outputStr = output ?? ""
        
        // Store output for later search
        if !outputStr.isEmpty {
            await MainActor.run {
                AgentToolRegistry.shared.storeOutput(outputStr, command: command)
            }
        }
        
        return (success: success, output: outputStr, exitCode: exitCode)
    }
    
    // MARK: - PlanTrackDelegate Protocol
    
    /// Set the agent's goal and optionally create a task checklist
    func setGoalAndTasks(goal: String, tasks: [String]?) {
        // Store the goal in context for reference
        agentContextLog.append("GOAL SET: \(goal)")
        
        // Create checklist if tasks provided
        if let tasks = tasks, !tasks.isEmpty {
            agentChecklist = TaskChecklist(from: tasks, goal: goal)
            
            // Add a checklist message to the UI
            let checklistDisplay = agentChecklist!.displayString
            messages.append(ChatMessage(
                role: "assistant",
                content: "",
                agentEvent: AgentEvent(
                    kind: "checklist",
                    title: "Task Checklist (\(tasks.count) items)",
                    details: checklistDisplay,
                    command: nil,
                    output: nil,
                    collapsed: false,
                    checklistItems: agentChecklist!.items
                )
            ))
            messages = messages
            persistMessages()
        } else {
            // Just goal, no tasks - add a simple status message
            messages.append(ChatMessage(
                role: "assistant",
                content: "",
                agentEvent: AgentEvent(
                    kind: "status",
                    title: "Goal",
                    details: goal,
                    command: nil,
                    output: nil,
                    collapsed: true
                )
            ))
            messages = messages
            persistMessages()
        }
    }
    
    /// Mark a task as in-progress
    func markTaskInProgress(id taskId: Int) {
        guard var checklist = agentChecklist else { return }
        
        checklist.markInProgress(taskId)
        agentChecklist = checklist
        
        // Update the checklist message in UI
        updateChecklistMessage()
        
        // Log start
        agentContextLog.append("TASK STARTED: #\(taskId)")
    }
    
    /// Mark a task as complete
    func markTaskComplete(id taskId: Int, note: String?) {
        guard var checklist = agentChecklist else { return }
        
        checklist.markCompleted(taskId, note: note)
        agentChecklist = checklist
        
        // Update the checklist message in UI
        updateChecklistMessage()
        
        // Log completion
        let noteStr = note.map { " (\($0))" } ?? ""
        agentContextLog.append("TASK COMPLETED: #\(taskId)\(noteStr)")
    }
    
    /// Get the current checklist status for context
    func getChecklistStatus() -> String? {
        return agentChecklist?.displayString
    }
    
    // MARK: - File Change Approval
    
    /// Request user approval for a file change before applying it
    /// - Parameters:
    ///   - fileChange: The file change to approve
    ///   - toolName: Name of the tool requesting the change
    ///   - toolArgs: Arguments passed to the tool
    ///   - forceApproval: If true, always require approval regardless of settings (for destructive operations)
    private func requestFileChangeApproval(fileChange: FileChange, toolName: String, toolArgs: [String: String], forceApproval: Bool = false) async -> Bool {
        // Check if approval is required
        // Always require approval if forceApproval is true (for destructive operations like delete_file)
        guard AgentSettings.shared.requireFileEditApproval || forceApproval else {
            return true
        }
        
        // Post notification requesting approval
        let approvalId = UUID()
        let approval = PendingFileChangeApproval(
            id: approvalId,
            sessionId: self.id,
            fileChange: fileChange,
            toolName: toolName,
            toolArgs: toolArgs
        )
        
        NotificationCenter.default.post(
            name: .TermAIFileChangePendingApproval,
            object: nil,
            userInfo: [
                "sessionId": self.id,
                "approvalId": approvalId,
                "approval": approval
            ]
        )
        
        // Add a pending approval message with inline approval buttons
        messages.append(ChatMessage(
            role: "assistant",
            content: "",
            agentEvent: AgentEvent(
                kind: "file_change",
                title: "Awaiting file change approval",
                details: "Wants to \(fileChange.operationType.description.lowercased()): \(fileChange.fileName)",
                command: nil,
                output: nil,
                collapsed: false,
                fileChange: fileChange,
                pendingApprovalId: approvalId,
                pendingToolName: toolName
            )
        ))
        messages = messages
        persistMessages()
        
        // Wait for approval response
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var token: NSObjectProtocol?
            var cancelCheckTimer: DispatchSourceTimer?
            var resolved = false
            
            func finish(_ approved: Bool) {
                guard !resolved else { return }
                resolved = true
                cancelCheckTimer?.cancel()
                cancelCheckTimer = nil
                if let t = token { NotificationCenter.default.removeObserver(t) }
                token = nil
                continuation.resume(returning: approved)
            }
            
            // Check for cancellation periodically
            cancelCheckTimer = DispatchSource.makeTimerSource(queue: .main)
            cancelCheckTimer?.schedule(deadline: .now() + 0.5, repeating: 0.5)
            cancelCheckTimer?.setEventHandler { [weak self] in
                if self?.agentCancelled == true {
                    AgentDebugConfig.log("[Agent] File change approval wait cancelled by user")
                    finish(false)
                }
            }
            cancelCheckTimer?.resume()
            
            token = NotificationCenter.default.addObserver(
                forName: .TermAIFileChangeApprovalResponse,
                object: nil,
                queue: .main
            ) { note in
                guard let noteApprovalId = note.userInfo?["approvalId"] as? UUID,
                      noteApprovalId == approvalId else { return }
                
                let approved = note.userInfo?["approved"] as? Bool ?? false
                finish(approved)
            }
            
            // Timeout after 5 minutes (user might be away)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                finish(false)
            }
        }
    }
    
    /// Execute a file operation tool with optional approval flow
    private func executeFileToolWithApproval(
        tool: AgentTool,
        toolName: String,
        args: [String: String],
        cwd: String?
    ) async -> AgentToolResult {
        // Check if this is a FileOperationTool that can provide previews
        // Always require approval for RequiresApprovalTool (like delete_file)
        let alwaysRequiresApproval = (tool as? RequiresApprovalTool)?.alwaysRequiresApproval ?? false
        
        // Get the preview of changes (needed for approval flow)
        var fileChange: FileChange?
        if let fileOpTool = tool as? FileOperationTool {
            fileChange = await fileOpTool.prepareChange(args: args, cwd: cwd)
        }
        
        // Handle approval flow if required
        if tool is FileOperationTool,
           (AgentSettings.shared.requireFileEditApproval || alwaysRequiresApproval),
           let change = fileChange {
            // Request approval (force approval for destructive operations)
            let approved = await requestFileChangeApproval(
                fileChange: change,
                toolName: toolName,
                toolArgs: args,
                forceApproval: alwaysRequiresApproval
            )
            
            if !approved {
                // File change was rejected
                messages.append(ChatMessage(
                    role: "assistant",
                    content: "",
                    agentEvent: AgentEvent(
                        kind: "status",
                        title: "File change rejected",
                        details: "User declined to apply changes to: \(change.fileName)",
                        command: nil,
                        output: nil,
                        collapsed: true,
                        fileChange: change
                    )
                ))
                messages = messages
                persistMessages()
                return .failure("File change rejected by user")
            }
            
            // Update status to show approval
            messages.append(ChatMessage(
                role: "assistant",
                content: "",
                agentEvent: AgentEvent(
                    kind: "status",
                    title: "File change approved",
                    details: "Applying changes to: \(change.fileName)",
                    command: nil,
                    output: nil,
                    collapsed: true,
                    fileChange: change
                )
            ))
            messages = messages
            persistMessages()
        }
        
        // Record file change to checkpoint for rollback capability
        // This must happen after approval is confirmed but before execution
        if let change = fileChange {
            let wasCreated = change.operationType == .create
            recordFileChange(
                path: change.filePath,
                contentBefore: change.beforeContent,
                wasCreated: wasCreated
            )
        }
        
        // Execute the tool
        return await tool.execute(args: args, cwd: cwd)
    }
    
    // MARK: - Title Generation
    private func generateTitle(from userMessage: String) async {
        // Clear any previous error
        await MainActor.run { [weak self] in
            self?.titleGenerationError = nil
        }
        
        // Skip if model is not set
        guard !model.isEmpty else {
            await MainActor.run { [weak self] in
                self?.titleGenerationError = ChatAPIError(
                    friendlyMessage: "Cannot generate title: No model selected",
                    fullDetails: "No model is currently selected. Please select a model in settings."
                )
            }
            return
        }
        
        // Run title generation in a separate task
        let titleTask = Task { [weak self] in
            guard let self = self else { return }
            
            let titlePrompt = """
            Generate a concise 2-5 word title for a chat conversation that starts with this user message. \
            The title should capture the main topic or intent. \
            Only respond with the title itself, no quotes, no explanation.
            
            User message: \(userMessage)
            """
            
            // Determine the correct URL based on provider type
            let url: URL
            if case .cloud(let cloudProvider) = self.providerType {
                switch cloudProvider {
                case .openai:
                    url = URL(string: "https://api.openai.com/v1/chat/completions")!
                case .anthropic:
                    // Use Anthropic endpoint
                    url = URL(string: "https://api.anthropic.com/v1/messages")!
                case .google:
                    // Use Google AI endpoint
                    url = CloudProvider.google.baseURL.appendingPathComponent("models/\(self.model):generateContent")
                }
            } else {
                url = self.apiBaseURL.appendingPathComponent("chat/completions")
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60.0
            
            // Set up authentication based on provider
            if case .cloud(let cloudProvider) = self.providerType {
                switch cloudProvider {
                case .openai:
                    if let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .openai) {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                case .anthropic:
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    if let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .anthropic) {
                        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    }
                case .google:
                    if let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .google) {
                        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    }
                }
            } else if let apiKey = self.apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            
            // Build request body based on provider
            let requestData: Data
            do {
                if case .cloud(let cloudProvider) = self.providerType {
                    switch cloudProvider {
                    case .openai:
                        // OpenAI format with max_completion_tokens
                        var bodyDict: [String: Any] = [
                            "model": self.model,
                            "messages": [
                                ["role": "system", "content": "You are a helpful assistant that generates concise titles."],
                                ["role": "user", "content": titlePrompt]
                            ],
                            "stream": false,
                            "max_completion_tokens": 256
                        ]
                        // For reasoning models use temperature 1.0, otherwise use title temperature
                        if self.currentModelSupportsReasoning {
                            bodyDict["temperature"] = 1.0
                        } else {
                            bodyDict["temperature"] = self.temperature
                        }
                        requestData = try JSONSerialization.data(withJSONObject: bodyDict)
                        
                    case .anthropic:
                        // Anthropic format
                        let bodyDict: [String: Any] = [
                            "model": self.model,
                            "max_tokens": 256,
                            "system": "You are a helpful assistant that generates concise titles.",
                            "messages": [
                                ["role": "user", "content": titlePrompt]
                            ]
                        ]
                        requestData = try JSONSerialization.data(withJSONObject: bodyDict)
                        
                    case .google:
                        // Google AI format
                        // Note: Gemini 2.5 models use reasoning tokens, so we need more output tokens
                        // to accommodate both thinking (can use 200-500+ tokens) and the actual response
                        let bodyDict: [String: Any] = [
                            "contents": [
                                ["role": "user", "parts": [["text": titlePrompt]]]
                            ],
                            "systemInstruction": [
                                "parts": [["text": "You are a helpful assistant that generates concise titles. Respond with ONLY the title, nothing else."]]
                            ],
                            "generationConfig": [
                                "maxOutputTokens": 1024,  // Higher limit to account for reasoning tokens
                                "temperature": self.temperature
                            ]
                        ]
                        requestData = try JSONSerialization.data(withJSONObject: bodyDict)
                    }
                } else {
                    // Local provider format (Ollama, LM Studio, vLLM)
                    struct RequestBody: Encodable {
                        struct Message: Codable { let role: String; let content: String }
                        let model: String
                        let messages: [Message]
                        let stream: Bool
                        let max_tokens: Int
                        let temperature: Double
                    }
                    let messages = [
                        RequestBody.Message(role: "system", content: "You are a helpful assistant that generates concise titles."),
                        RequestBody.Message(role: "user", content: titlePrompt)
                    ]
                    let req = RequestBody(
                        model: self.model,
                        messages: messages,
                        stream: false,
                        max_tokens: 256,
                        temperature: self.temperature
                    )
                    requestData = try JSONEncoder().encode(req)
                }
                request.httpBody = requestData
                
                // Use a custom URLSession with longer timeout configuration
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 60.0
                config.timeoutIntervalForResource = 60.0
                let session = URLSession(configuration: config)
                
                let (data, response) = try await session.data(for: request)
                
                guard !Task.isCancelled else { 
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = ChatAPIError(
                            friendlyMessage: "Title generation was cancelled",
                            fullDetails: "The title generation request was cancelled by the user."
                        )
                    }
                    return 
                }
                
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = ChatAPIError(
                            friendlyMessage: "Invalid response from server",
                            fullDetails: "The server returned an invalid response that could not be processed."
                        )
                    }
                    return
                }
                
                guard (200..<300).contains(http.statusCode) else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                    // Use provider-specific error parsing
                    let apiError: ChatAPIError
                    if case .cloud(let cloudProvider) = self.providerType {
                        apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: cloudProvider)
                    } else {
                        apiError = ChatAPIError(
                            friendlyMessage: "Title generation failed (HTTP \(http.statusCode))",
                            fullDetails: "HTTP \(http.statusCode): \(errorBody)",
                            statusCode: http.statusCode,
                            provider: self.providerName
                        )
                    }
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = apiError
                    }
                    return
                }
                
                // Response format structs with usage
                struct OpenAIUsage: Decodable { let prompt_tokens: Int; let completion_tokens: Int }
                struct OpenAIChoice: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message
                }
                struct OpenAIResponse: Decodable { let choices: [OpenAIChoice]; let usage: OpenAIUsage? }
                
                struct OllamaResponse: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message?
                    let response: String?
                    let prompt_eval_count: Int?
                    let eval_count: Int?
                }
                
                // Anthropic response format with usage
                struct AnthropicUsage: Decodable { let input_tokens: Int; let output_tokens: Int }
                struct AnthropicContentBlock: Decodable { let type: String; let text: String? }
                struct AnthropicResponse: Decodable { let content: [AnthropicContentBlock]; let usage: AnthropicUsage? }
                
                // Google AI response format with usage
                struct GooglePart: Decodable { let text: String? }
                struct GoogleContent: Decodable { let parts: [GooglePart]?; let role: String? }
                struct GoogleCandidate: Decodable { let content: GoogleContent? }
                struct GoogleUsageMetadata: Decodable { let promptTokenCount: Int?; let candidatesTokenCount: Int? }
                struct GoogleResponse: Decodable { let candidates: [GoogleCandidate]?; let usageMetadata: GoogleUsageMetadata? }
                
                var generatedTitle: String? = nil
                var promptTokens: Int? = nil
                var completionTokens: Int? = nil
                
                // Estimate prompt tokens for fallback
                let systemPromptForTitle = "You are a helpful assistant that generates concise titles."
                let estimatedPromptTokens = TokenEstimator.estimateTokens(systemPromptForTitle + titlePrompt)
                
                // Parse based on provider
                if case .cloud(let cloudProvider) = self.providerType, cloudProvider == .anthropic {
                    // Anthropic format
                    if let decoded = try? JSONDecoder().decode(AnthropicResponse.self, from: data),
                       let textBlock = decoded.content.first(where: { $0.type == "text" }),
                       let text = textBlock.text {
                        generatedTitle = text
                        promptTokens = decoded.usage?.input_tokens
                        completionTokens = decoded.usage?.output_tokens
                    }
                } else if case .cloud(let cloudProvider) = self.providerType, cloudProvider == .google {
                    // Google AI format - try structured decoding first
                    if let decoded = try? JSONDecoder().decode(GoogleResponse.self, from: data),
                       let candidate = decoded.candidates?.first,
                       let content = candidate.content,
                       let parts = content.parts,
                       let textPart = parts.first(where: { $0.text != nil }),
                       let text = textPart.text {
                        generatedTitle = text
                        promptTokens = decoded.usageMetadata?.promptTokenCount
                        completionTokens = decoded.usageMetadata?.candidatesTokenCount
                    } else {
                        // Fallback: Try manual JSON parsing for Google responses
                        // This handles cases where the response structure differs slightly
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let candidates = json["candidates"] as? [[String: Any]],
                           let firstCandidate = candidates.first,
                           let content = firstCandidate["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]],
                           let firstPart = parts.first,
                           let text = firstPart["text"] as? String {
                            generatedTitle = text
                            // Try to get usage metadata
                            if let usageMetadata = json["usageMetadata"] as? [String: Any] {
                                promptTokens = usageMetadata["promptTokenCount"] as? Int
                                completionTokens = usageMetadata["candidatesTokenCount"] as? Int
                            }
                        }
                    }
                } else {
                    // Try OpenAI format first
                    do {
                        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
                        if let title = decoded.choices.first?.message.content {
                            generatedTitle = title
                            promptTokens = decoded.usage?.prompt_tokens
                            completionTokens = decoded.usage?.completion_tokens
                        }
                    } catch {
                        // Try Ollama format
                        do {
                            let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
                            generatedTitle = decoded.message?.content ?? decoded.response
                            promptTokens = decoded.prompt_eval_count
                            completionTokens = decoded.eval_count
                        } catch {
                            // Failed to decode both formats
                        }
                    }
                }
                
                if let title = generatedTitle {
                    // Record usage for title generation
                    let finalPromptTokens = promptTokens ?? estimatedPromptTokens
                    let finalCompletionTokens = completionTokens ?? TokenEstimator.estimateTokens(title)
                    let isEstimated = promptTokens == nil || completionTokens == nil
                    
                    let providerForTracking: String
                    if case .cloud(let cloudProvider) = self.providerType {
                        switch cloudProvider {
                        case .anthropic: providerForTracking = "Anthropic"
                        case .google: providerForTracking = "Google"
                        case .openai: providerForTracking = "OpenAI"
                        }
                    } else {
                        providerForTracking = self.providerName
                    }
                    
                    TokenUsageTracker.shared.recordUsage(
                        provider: providerForTracking,
                        model: self.model,
                        promptTokens: finalPromptTokens,
                        completionTokens: finalCompletionTokens,
                        isEstimated: isEstimated,
                        requestType: .titleGeneration
                    )
                    
                    await MainActor.run { [weak self] in
                        self?.sessionTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.titleGenerationError = nil  // Clear any error on success
                        self?.persistSettings()
                    }
                } else {
                    let responseBody = String(data: data, encoding: .utf8) ?? "Unable to decode response"
                    let providerInfo = self.providerName
                    let modelInfo = self.model
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = ChatAPIError(
                            friendlyMessage: "Could not parse title from response",
                            fullDetails: """
                            Provider: \(providerInfo)
                            Model: \(modelInfo)
                            
                            Response body:
                            \(responseBody)
                            """,
                            provider: providerInfo
                        )
                    }
                }
            } catch {
                let apiError: ChatAPIError
                if let urlError = error as? URLError {
                    let friendlyMessage: String
                    switch urlError.code {
                    case .timedOut:
                        friendlyMessage = "Request timed out"
                    case .notConnectedToInternet:
                        friendlyMessage = "No internet connection"
                    case .cannotConnectToHost:
                        friendlyMessage = "Cannot connect to server"
                    default:
                        friendlyMessage = "Network error"
                    }
                    apiError = ChatAPIError(
                        friendlyMessage: friendlyMessage,
                        fullDetails: "URLError: \(urlError.localizedDescription)\nCode: \(urlError.code.rawValue)"
                    )
                } else {
                    apiError = ChatAPIError(
                        friendlyMessage: "Title generation error",
                        fullDetails: error.localizedDescription
                    )
                }
                
                await MainActor.run { [weak self] in
                    self?.titleGenerationError = apiError
                }
            }
        }
        
        // Cancel the task if it takes more than 90 seconds (extra buffer beyond URLSession timeout)
        Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)  // 90 seconds
            if !titleTask.isCancelled {
                titleTask.cancel()
                await MainActor.run { [weak self] in
                    // Only set timeout error if we still don't have a title
                    if self?.sessionTitle.isEmpty == true {
                        self?.titleGenerationError = ChatAPIError(
                            friendlyMessage: "Title generation timed out",
                            fullDetails: "The request took longer than 90 seconds and was cancelled."
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - Streaming
    private func requestChatCompletionStream(assistantIndex: Int) async throws -> String {
        // Route to appropriate provider
        if case .cloud(let cloudProvider) = providerType {
            switch cloudProvider {
            case .openai:
                return try await requestOpenAIStream(assistantIndex: assistantIndex)
            case .anthropic:
                return try await requestAnthropicStream(assistantIndex: assistantIndex)
            case .google:
                return try await requestGoogleStream(assistantIndex: assistantIndex)
            }
        } else {
            return try await requestLocalProviderStream(assistantIndex: assistantIndex)
        }
    }
    
    // MARK: - Local Provider Streaming (Ollama, LM Studio, vLLM)
    private func requestLocalProviderStream(assistantIndex: Int) async throws -> String {
        struct RequestBody: Encodable {
            struct Message: Codable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let stream: Bool
            let temperature: Double?
            let max_tokens: Int?
        }
        
        let url = apiBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        // Get full system prompt asynchronously to avoid race condition
        let sysPrompt = await getSystemPromptAsync()
        let allMessages = buildMessageArray(withSystemPrompt: sysPrompt)
        let req = RequestBody(
            model: model,
            messages: allMessages.map { .init(role: $0.role, content: $0.content) },
            stream: true,
            temperature: temperature,
            max_tokens: maxTokens
        )
        request.httpBody = try JSONEncoder().encode(req)
        
        // Calculate prompt tokens for estimation (local providers don't return usage)
        let promptText = allMessages.map { $0.content }.joined(separator: "\n")
        let estimatedPromptTokens = TokenEstimator.estimateTokens(promptText)
        
        return try await streamSSEResponse(
            request: request,
            assistantIndex: assistantIndex,
            provider: providerName,
            modelName: model,
            estimatedPromptTokens: estimatedPromptTokens
        )
    }
    
    // MARK: - OpenAI Streaming
    private func requestOpenAIStream(assistantIndex: Int) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .openai) else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI API key not found. Set OPENAI_API_KEY environment variable."])
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Get full system prompt asynchronously to avoid race condition
        let sysPrompt = await getSystemPromptAsync()
        let allMessages = buildMessageArray(withSystemPrompt: sysPrompt)
        
        // Build request body as dictionary to handle different parameter names
        var bodyDict: [String: Any] = [
            "model": model,
            "messages": allMessages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "stream_options": ["include_usage": true]  // Request usage data in streaming response
        ]
        
        // Handle temperature and max tokens based on whether model supports reasoning
        if currentModelSupportsReasoning {
            // Reasoning models require temperature = 1.0
            bodyDict["temperature"] = 1.0
            // Use max_completion_tokens for newer models
            bodyDict["max_completion_tokens"] = maxTokens
            // Add reasoning effort if not "none"
            if let reasoningValue = reasoningEffort.openAIValue {
                bodyDict["reasoning_effort"] = reasoningValue
            }
        } else {
            // Standard models use regular temperature and max_tokens
            bodyDict["temperature"] = temperature
            bodyDict["max_completion_tokens"] = maxTokens
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        // Calculate prompt tokens for estimation
        let promptText = allMessages.map { $0.content }.joined(separator: "\n")
        let estimatedPromptTokens = TokenEstimator.estimateTokens(promptText)
        
        return try await streamSSEResponse(
            request: request,
            assistantIndex: assistantIndex,
            provider: "OpenAI",
            modelName: model,
            estimatedPromptTokens: estimatedPromptTokens
        )
    }
    
    // MARK: - Anthropic Streaming
    private func requestAnthropicStream(assistantIndex: Int) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .anthropic) else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Anthropic API key not found. Set ANTHROPIC_API_KEY environment variable."])
        }
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        // Anthropic uses extended thinking via beta header
        if currentModelSupportsReasoning && reasoningEffort != .none {
            request.setValue("interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
        }
        
        // Get full system prompt asynchronously to avoid race condition
        let sysPrompt = await getSystemPromptAsync()
        let allMessages = buildMessageArray(withSystemPrompt: sysPrompt)
        
        // Anthropic format is different - separate system from messages
        var bodyDict: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true
        ]
        
        // Add system prompt
        bodyDict["system"] = sysPrompt
        
        // Convert messages (exclude system role for Anthropic)
        let anthropicMessages = allMessages.filter { $0.role != "system" }.map { msg -> [String: Any] in
            return ["role": msg.role, "content": msg.content]
        }
        bodyDict["messages"] = anthropicMessages
        
        // Add temperature (only for non-reasoning or when reasoning is disabled)
        if !currentModelSupportsReasoning || reasoningEffort == .none {
            bodyDict["temperature"] = temperature
        }
        
        // Add thinking configuration for extended thinking models
        if currentModelSupportsReasoning, let budgetTokens = reasoningEffort.anthropicBudgetTokens {
            bodyDict["thinking"] = [
                "type": "enabled",
                "budget_tokens": budgetTokens
            ]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        return try await streamAnthropicResponse(
            request: request,
            assistantIndex: assistantIndex,
            modelName: model,
            systemPromptUsed: sysPrompt
        )
    }
    
    // MARK: - Google AI Studio Streaming (Gemini)
    private func requestGoogleStream(assistantIndex: Int) async throws -> String {
        // Google AI Studio uses a different URL format: /models/{model}:streamGenerateContent?alt=sse
        let baseURL = CloudProvider.google.baseURL
        guard var urlComponents = URLComponents(url: baseURL.appendingPathComponent("models/\(model):streamGenerateContent"), resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Google API URL"])
        }
        urlComponents.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        
        guard let url = urlComponents.url else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Google API URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .google) else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Google API key not found. Set GOOGLE_API_KEY environment variable."])
        }
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        
        // Get full system prompt asynchronously to avoid race condition
        let sysPrompt = await getSystemPromptAsync()
        let allMessages = buildMessageArray(withSystemPrompt: sysPrompt)
        
        // Build Google AI request format
        // Convert messages to Google format (user/model roles, parts array)
        var googleContents: [[String: Any]] = []
        for msg in allMessages.filter({ $0.role != "system" }) {
            let role = msg.role == "assistant" ? "model" : "user"
            googleContents.append([
                "role": role,
                "parts": [["text": msg.content]]
            ])
        }
        
        var bodyDict: [String: Any] = [
            "contents": googleContents,
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": maxTokens
            ]
        ]
        
        // Add system instruction if provided
        if !sysPrompt.isEmpty {
            bodyDict["systemInstruction"] = [
                "parts": [["text": sysPrompt]]
            ]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        return try await streamGoogleResponse(
            request: request,
            assistantIndex: assistantIndex,
            modelName: model,
            systemPromptUsed: sysPrompt
        )
    }
    
    // MARK: - Message Building Helper
    private struct SimpleMessage {
        let role: String
        let content: String
    }
    
    /// Build message array for LLM calls. Pass the system prompt explicitly to ensure
    /// async callers can await full system info before building messages.
    private func buildMessageArray(withSystemPrompt sysPrompt: String) -> [SimpleMessage] {
        // Exclude agent event bubbles and assistant placeholders from the provider context
        let conversational = messages.filter { msg in
            guard msg.role != "system" else { return false }
            if msg.agentEvent != nil { return false }
            if msg.role == "assistant" && msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            return true
        }
        
        // Convert to SimpleMessages
        var allConv = conversational.map { msg -> SimpleMessage in
            var prefix = ""
            
            // Add terminal context if present
            if let ctx = msg.terminalContext, !ctx.isEmpty {
                var header = "Terminal Context:"
                if let meta = msg.terminalContextMeta, let cwd = meta.cwd, !cwd.isEmpty {
                    header += "\nCurrent Working Directory - \(cwd)"
                }
                prefix = "\(header)\n```\n\(ctx)\n```\n\n"
            }
            
            // Add attached contexts (files, etc.) if present
            if let contexts = msg.attachedContexts, !contexts.isEmpty {
                for context in contexts {
                    prefix += formatAttachedContext(context)
                }
            }
            
            return SimpleMessage(role: msg.role, content: prefix + msg.content)
        }
        
        // Context window management: estimate ~4 chars per token
        // Most models have 4K-128K token limits. We'll aim for ~100K chars max
        let maxContextChars = 100_000
        let systemPromptChars = sysPrompt.count
        let availableChars = maxContextChars - systemPromptChars
        
        // Calculate total message size
        var totalChars = allConv.reduce(0) { $0 + $1.content.count }
        
        // If we exceed the limit, trim older messages (keep most recent)
        while totalChars > availableChars && allConv.count > 2 {
            // Remove oldest message (but keep at least the last 2 exchanges)
            let removed = allConv.removeFirst()
            totalChars -= removed.content.count
            AgentDebugConfig.log("[Context] Trimmed old message to fit context window")
        }
        
        // If individual messages are too long, truncate them
        allConv = allConv.map { msg in
            let maxMsgChars = 20_000 // Max ~5K tokens per message
            if msg.content.count > maxMsgChars {
                let truncated = String(msg.content.prefix(maxMsgChars)) + "\n\n[Content truncated due to length...]"
                return SimpleMessage(role: msg.role, content: truncated)
            }
            return msg
        }
        
        var result = [SimpleMessage(role: "system", content: sysPrompt)]
        result += allConv
        return result
    }
    
    /// Convenience version using the synchronous system prompt (for token estimation only)
    private func buildMessageArray() -> [SimpleMessage] {
        return buildMessageArray(withSystemPrompt: systemPrompt)
    }
    
    /// Format an attached context (file, terminal, etc.) for inclusion in the prompt
    private func formatAttachedContext(_ context: PinnedContext) -> String {
        var result = ""
        
        switch context.type {
        case .file:
            // Format file context
            var header = "Attached File: \(context.displayName)"
            header += "\nPath: \(context.path)"
            if let range = context.lineRangeDescription {
                header += " (\(range))"
            }
            if let lang = context.language {
                header += "\nLanguage: \(lang)"
            }
            
            // Use summary if available and content is large
            let contentToInclude: String
            if let summary = context.summary, context.isLargeContent {
                contentToInclude = "[Content summarized due to size]\n\(summary)"
            } else {
                contentToInclude = context.content
            }
            
            result = "\(header)\n```\(context.language ?? "")\n\(contentToInclude)\n```\n\n"
            
        case .terminal:
            // Format terminal context
            let header = "Attached Terminal Output:"
            result = "\(header)\n```\n\(context.content)\n```\n\n"
            
        case .snippet:
            // Format code snippet
            let header = "Attached Code Snippet:"
            result = "\(header)\n```\(context.language ?? "")\n\(context.content)\n```\n\n"
        }
        
        return result
    }
    
    // MARK: - SSE Response Streaming (OpenAI-compatible)
    private func streamSSEResponse(
        request: URLRequest,
        assistantIndex: Int,
        provider: String? = nil,
        modelName: String? = nil,
        estimatedPromptTokens: Int? = nil
    ) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if !(200..<300).contains(http.statusCode) {
            // Try to read error message
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            // Use provider-specific error parsing for cloud providers
            if case .cloud(let cloudProvider) = providerType {
                let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: cloudProvider)
                throw NSError(domain: "ChatAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: apiError.friendlyMessage, "fullDetails": apiError.fullDetails])
            }
            throw NSError(domain: "ChatAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errorBody)"])
        }
        
        var accumulated = ""
        let index = assistantIndex
        
        // Token usage tracking
        var promptTokens: Int? = nil
        var completionTokens: Int? = nil
        
        // Throttle UI updates to reduce overhead during streaming
        let updateInterval: TimeInterval = 0.05  // 50ms between UI updates
        var lastUpdateTime = Date.distantPast
        
        streamLoop: for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break streamLoop }
            guard let data = payload.data(using: .utf8) else { continue }
            
            var didAccumulate = false
            
            if let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) {
                if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                    accumulated += delta
                    didAccumulate = true
                }
                // Capture usage from final chunk (OpenAI sends usage in last chunk with stream_options)
                if let usage = chunk.usage {
                    promptTokens = usage.prompt_tokens
                    completionTokens = usage.completion_tokens
                }
            } else if let ollama = try? JSONDecoder().decode(OllamaStreamChunk.self, from: data) {
                if let content = ollama.message?.content ?? ollama.response {
                    accumulated += content
                    didAccumulate = true
                }
            }
            
            if didAccumulate {
                if Task.isCancelled { break streamLoop }
                
                // Only update UI if enough time has passed since last update
                let now = Date()
                if now.timeIntervalSince(lastUpdateTime) >= updateInterval {
                    messages[index].content = accumulated
                    messages = messages
                    lastUpdateTime = now
                }
            }
        }
        
        // Ensure final state is always reflected in UI
        messages[index].content = accumulated
        messages = messages
        
        // Record token usage
        if let provider = provider, let modelName = modelName {
            let finalPromptTokens = promptTokens ?? estimatedPromptTokens ?? 0
            let finalCompletionTokens = completionTokens ?? TokenEstimator.estimateTokens(accumulated)
            let isEstimated = promptTokens == nil || completionTokens == nil
            
            TokenUsageTracker.shared.recordUsage(
                provider: provider,
                model: modelName,
                promptTokens: finalPromptTokens,
                completionTokens: finalCompletionTokens,
                isEstimated: isEstimated
            )
        }
        
        return accumulated
    }
    
    // MARK: - Anthropic Response Streaming
    private func streamAnthropicResponse(
        request: URLRequest,
        assistantIndex: Int,
        modelName: String,
        systemPromptUsed: String? = nil
    ) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if !(200..<300).contains(http.statusCode) {
            // Try to read error message
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            // Use provider-specific error parsing for Anthropic
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .anthropic)
            throw NSError(domain: "ChatAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: apiError.friendlyMessage, "fullDetails": apiError.fullDetails])
        }
        
        var accumulated = ""
        let index = assistantIndex
        
        // Token usage tracking
        var inputTokens: Int? = nil
        var outputTokens: Int? = nil
        
        // Throttle UI updates
        let updateInterval: TimeInterval = 0.05
        var lastUpdateTime = Date.distantPast
        
        // Anthropic SSE event types
        struct ContentBlockDelta: Decodable {
            struct Delta: Decodable {
                let type: String?
                let text: String?
                let thinking: String?
            }
            let delta: Delta?
        }
        
        streamLoop: for try await line in bytes.lines {
            if Task.isCancelled { break streamLoop }
            
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8) else { continue }
            
            // Try to parse message_start for input tokens
            if let messageStart = try? JSONDecoder().decode(AnthropicMessageStart.self, from: data),
               let usage = messageStart.message?.usage {
                inputTokens = usage.input_tokens
            }
            
            // Try to parse message_delta for output tokens
            if let messageDelta = try? JSONDecoder().decode(AnthropicMessageDelta.self, from: data),
               let usage = messageDelta.usage {
                outputTokens = usage.output_tokens
            }
            
            // Parse event type from previous line or inline
            if let event = try? JSONDecoder().decode(ContentBlockDelta.self, from: data),
               let delta = event.delta {
                var didAccumulate = false
                
                // Handle text delta
                if let text = delta.text, !text.isEmpty {
                    accumulated += text
                    didAccumulate = true
                }
                
                // Handle thinking delta (for extended thinking models)
                // We could optionally display thinking in a collapsible section
                // For now, we just skip it
                
                if didAccumulate {
                    let now = Date()
                    if now.timeIntervalSince(lastUpdateTime) >= updateInterval {
                        messages[index].content = accumulated
                        messages = messages
                        lastUpdateTime = now
                    }
                }
            }
        }
        
        // Ensure final state is always reflected in UI
        messages[index].content = accumulated
        messages = messages
        
        // Record token usage
        let sysPromptForEstimation = systemPromptUsed ?? systemPrompt
        let finalInputTokens = inputTokens ?? TokenEstimator.estimateTokens(sysPromptForEstimation + messages.map { $0.content }.joined())
        let finalOutputTokens = outputTokens ?? TokenEstimator.estimateTokens(accumulated)
        let isEstimated = inputTokens == nil || outputTokens == nil
        
        TokenUsageTracker.shared.recordUsage(
            provider: "Anthropic",
            model: modelName,
            promptTokens: finalInputTokens,
            completionTokens: finalOutputTokens,
            isEstimated: isEstimated
        )
        
        return accumulated
    }
    
    // MARK: - Google AI Studio Response Streaming
    private func streamGoogleResponse(
        request: URLRequest,
        assistantIndex: Int,
        modelName: String,
        systemPromptUsed: String? = nil
    ) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ChatAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if !(200..<300).contains(http.statusCode) {
            // Try to read error message
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            // Parse user-friendly error messages for Google API errors
            let apiError = ChatAPIError.from(statusCode: http.statusCode, errorBody: errorBody, provider: .google)
            throw NSError(domain: "ChatAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: apiError.friendlyMessage, "fullDetails": apiError.fullDetails])
        }
        
        var accumulated = ""
        let index = assistantIndex
        
        // Token usage tracking
        var promptTokens: Int? = nil
        var completionTokens: Int? = nil
        
        // Throttle UI updates
        let updateInterval: TimeInterval = 0.05
        var lastUpdateTime = Date.distantPast
        
        // Google AI SSE response structures
        struct Part: Decodable { let text: String? }
        struct Content: Decodable { let parts: [Part]?; let role: String? }
        struct Candidate: Decodable { let content: Content? }
        struct UsageMetadata: Decodable { let promptTokenCount: Int?; let candidatesTokenCount: Int? }
        struct GoogleStreamChunk: Decodable { let candidates: [Candidate]?; let usageMetadata: UsageMetadata? }
        
        streamLoop: for try await line in bytes.lines {
            if Task.isCancelled { break streamLoop }
            
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8) else { continue }
            
            if let chunk = try? JSONDecoder().decode(GoogleStreamChunk.self, from: data) {
                var didAccumulate = false
                
                // Extract text from candidates
                if let candidate = chunk.candidates?.first,
                   let content = candidate.content,
                   let parts = content.parts {
                    for part in parts {
                        if let text = part.text, !text.isEmpty {
                            accumulated += text
                            didAccumulate = true
                        }
                    }
                }
                
                // Capture usage metadata (usually in final chunk)
                if let usage = chunk.usageMetadata {
                    promptTokens = usage.promptTokenCount
                    completionTokens = usage.candidatesTokenCount
                }
                
                if didAccumulate {
                    let now = Date()
                    if now.timeIntervalSince(lastUpdateTime) >= updateInterval {
                        messages[index].content = accumulated
                        messages = messages
                        lastUpdateTime = now
                    }
                }
            }
        }
        
        // Ensure final state is always reflected in UI
        messages[index].content = accumulated
        messages = messages
        
        // Record token usage
        let sysPromptForEstimation = systemPromptUsed ?? systemPrompt
        let finalPromptTokens = promptTokens ?? TokenEstimator.estimateTokens(sysPromptForEstimation + messages.map { $0.content }.joined())
        let finalCompletionTokens = completionTokens ?? TokenEstimator.estimateTokens(accumulated)
        let isEstimated = promptTokens == nil || completionTokens == nil
        
        TokenUsageTracker.shared.recordUsage(
            provider: "Google",
            model: modelName,
            promptTokens: finalPromptTokens,
            completionTokens: finalCompletionTokens,
            isEstimated: isEstimated
        )
        
        return accumulated
    }
    
    // MARK: - Model Cache
    
    /// Cache key for the current provider configuration
    private var modelCacheKey: String {
        "modelCache_\(providerName)_\(apiBaseURL.absoluteString)"
    }
    
    /// TTL for cached models (1 hour)
    private static let modelCacheTTL: TimeInterval = 3600
    
    /// Check if cached models are still valid
    private func getCachedModels() -> [String]? {
        guard let data = UserDefaults.standard.data(forKey: modelCacheKey),
              let cache = try? JSONDecoder().decode(ModelCache.self, from: data) else {
            return nil
        }
        
        // Check if cache is expired
        if Date().timeIntervalSince(cache.timestamp) > Self.modelCacheTTL {
            return nil
        }
        
        return cache.models
    }
    
    /// Save models to cache
    private func cacheModels(_ models: [String]) {
        let cache = ModelCache(models: models, timestamp: Date())
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: modelCacheKey)
        }
    }
    
    // MARK: - Models
    func fetchAvailableModels(forceRefresh: Bool = false) async {
        await MainActor.run {
            self.modelFetchError = nil
        }
        
        // Handle cloud providers - use curated model list (no caching needed, these are static)
        if case .cloud(let cloudProvider) = providerType {
            let models = CuratedModels.models(for: cloudProvider).map { $0.id }
            await MainActor.run {
                self.availableModels = models
                if models.isEmpty {
                    self.modelFetchError = "No models available for \(cloudProvider.rawValue)"
                }
            }
            return
        }
        
        // Check cache first for local providers (unless force refresh)
        if !forceRefresh, let cachedModels = getCachedModels(), !cachedModels.isEmpty {
            await MainActor.run {
                self.availableModels = cachedModels
            }
            return
        }
        
        await MainActor.run {
            self.availableModels = []
        }
        
        // Handle local providers
        switch LocalLLMProvider(rawValue: providerName) {
        case .ollama:
            await fetchOllamaModelsInternal()
        case .lmStudio, .vllm:
            await fetchOpenAIStyleModels()
        case .none:
            break
        }
    }

    /// Backward-compatible entry point kept for existing call sites
    func fetchOllamaModels() async { await fetchAvailableModels() }

    private func fetchOllamaModelsInternal() async {
        let base = apiBaseURL.absoluteString
        guard let url = URL(string: base.replacingOccurrences(of: "/v1", with: "") + "/api/tags") else {
            await MainActor.run { self.modelFetchError = "Invalid Ollama URL" }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                await MainActor.run { self.modelFetchError = "Failed to fetch Ollama models (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))" }
                return
            }
            struct TagsResponse: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
            if let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data) {
                let names = decoded.models.map { $0.name }.sorted()
                // Cache the results
                cacheModels(names)
                await MainActor.run {
                    self.availableModels = names
                    if names.isEmpty {
                        self.modelFetchError = "No models found on Ollama"
                    }
                    // Don't auto-select - let user choose their model
                    self.updateContextLimit()
                    self.persistSettings()
                }
            } else {
                await MainActor.run { self.modelFetchError = "Unable to decode Ollama models" }
            }
        } catch {
            await MainActor.run { self.modelFetchError = "Ollama connection failed: \(error.localizedDescription)" }
        }
    }

    private func fetchOpenAIStyleModels() async {
        let url = apiBaseURL.appendingPathComponent("models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        if let apiKey {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                await MainActor.run { self.modelFetchError = "Failed to fetch models (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))" }
                return
            }
            struct ModelsResponse: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
            if let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) {
                let ids = decoded.data.map { $0.id }.sorted()
                // Cache the results
                cacheModels(ids)
                await MainActor.run {
                    self.availableModels = ids
                    if ids.isEmpty {
                        self.modelFetchError = "No models available"
                    }
                    // Don't auto-select - let user choose their model
                    self.updateContextLimit()
                    self.persistSettings()
                }
            } else {
                await MainActor.run { self.modelFetchError = "Unable to decode models list" }
            }
        } catch {
            await MainActor.run { self.modelFetchError = "Model fetch failed: \(error.localizedDescription)" }
        }
    }
    
    // MARK: - Persistence
    private var messagesFileName: String { "chat-session-\(id.uuidString).json" }
    
    /// Debounce work item for batching message persistence
    private var persistDebounceItem: DispatchWorkItem?
    private let persistDebounceInterval: TimeInterval = 0.5  // 500ms debounce
    
    /// Persist messages with debouncing to reduce disk I/O during streaming
    func persistMessages() {
        persistDebounceItem?.cancel()
        // Capture messages immediately to avoid race conditions
        let messagesToSave = messages
        let fileName = messagesFileName
        let item = DispatchWorkItem {
            // Save on background thread
            PersistenceService.saveJSONInBackground(messagesToSave, to: fileName)
        }
        persistDebounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceInterval, execute: item)
    }
    
    /// Force immediate persistence for critical events (session close, app quit)
    func persistMessagesImmediately() {
        persistDebounceItem?.cancel()
        persistDebounceItem = nil
        // Synchronous save for critical paths (app quit)
        try? PersistenceService.saveJSON(messages, to: messagesFileName)
    }
    
    func loadMessages() {
        if let m = try? PersistenceService.loadJSON([ChatMessage].self, from: messagesFileName) {
            messages = m
        }
        // Also load checkpoints alongside messages
        loadCheckpoints()
    }
    
    func persistSettings() {
        let settings = SessionSettings(
            apiBaseURL: apiBaseURL.absoluteString,
            apiKey: apiKey,
            model: model,
            providerName: providerName,
            systemPrompt: nil,  // No longer used
            sessionTitle: sessionTitle,
            agentModeEnabled: agentModeEnabled,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            providerType: providerType,
            hasExplicitlyConfiguredProvider: hasExplicitlyConfiguredProvider,
            customLocalContextSize: customLocalContextSize,
            currentContextTokens: currentContextTokens,
            contextLimitTokens: contextLimitTokens,
            lastSummarizationDate: lastSummarizationDate,
            summarizationCount: summarizationCount
        )
        // Use background save for settings (not critical path)
        PersistenceService.saveJSONInBackground(settings, to: "session-settings-\(id.uuidString).json")
    }
    
    func loadSettings() {
        if let settings = try? PersistenceService.loadJSON(SessionSettings.self, from: "session-settings-\(id.uuidString).json") {
            if let url = URL(string: settings.apiBaseURL) { apiBaseURL = url }
            apiKey = settings.apiKey
            model = settings.model
            providerName = settings.providerName
            // Note: systemPrompt is no longer loaded from settings - using hard-coded prompt
            sessionTitle = settings.sessionTitle ?? ""
            agentModeEnabled = settings.agentModeEnabled ?? false
            
            // Load generation settings
            temperature = settings.temperature ?? 0.7
            maxTokens = settings.maxTokens ?? 4096
            reasoningEffort = settings.reasoningEffort ?? .medium
            providerType = settings.providerType ?? .local(.ollama)
            
            // Load provider configuration status (defaults to false for backward compatibility)
            hasExplicitlyConfiguredProvider = settings.hasExplicitlyConfiguredProvider ?? false
            
            // Load context size settings
            customLocalContextSize = settings.customLocalContextSize
            
            // Load context tracking (per-session)
            if let tokens = settings.currentContextTokens {
                currentContextTokens = tokens
            }
            if let limit = settings.contextLimitTokens {
                contextLimitTokens = limit
            }
            lastSummarizationDate = settings.lastSummarizationDate
            if let count = settings.summarizationCount {
                summarizationCount = count
            }
        }
        
        // Update context limit based on model (only if not already loaded from settings)
        if contextLimitTokens == 32_000 {
            updateContextLimit()
        }
        
        // After loading settings, fetch models for selected provider
        Task { await fetchAvailableModels() }
    }
    
    /// Switch to a cloud provider
    func switchToCloudProvider(_ provider: CloudProvider) {
        providerType = .cloud(provider)
        providerName = provider.rawValue
        apiBaseURL = provider.baseURL
        apiKey = CloudAPIKeyManager.shared.getAPIKey(for: provider)
        model = "" // Reset model selection
        hasExplicitlyConfiguredProvider = true // User explicitly chose this provider
        availableModels = CuratedModels.models(for: provider).map { $0.id }
        persistSettings()
    }
    
    /// Switch to a local provider
    func switchToLocalProvider(_ provider: LocalLLMProvider) {
        providerType = .local(provider)
        providerName = provider.rawValue
        // Use the URL from global AgentSettings
        apiBaseURL = AgentSettings.shared.baseURL(for: provider)
        apiKey = nil
        model = "" // Reset model selection
        hasExplicitlyConfiguredProvider = true // User explicitly chose this provider
        persistSettings()
        Task { await fetchAvailableModels() }
    }
    
    // MARK: - Context Tracking
    
    /// Update the context limit based on the current model
    func updateContextLimit() {
        if providerType.isLocal {
            // For local models, use custom size if set, otherwise use TokenEstimator fallback
            if let custom = customLocalContextSize {
                contextLimitTokens = custom
            } else {
                contextLimitTokens = TokenEstimator.contextLimit(for: model)
            }
        } else {
            // For cloud models, use ModelDefinition if available
            contextLimitTokens = ModelDefinition.contextSize(for: model)
        }
    }
    
    /// Update the current context usage based on messages and agent context
    /// During agent execution, this is a no-op since we use actual API-reported tokens
    func updateContextUsage(persist: Bool = true) {
        // During active agent execution, skip estimation - we use actual API tokens set by callOneShotText()
        if agentModeEnabled && isAgentRunning {
            if persist {
                persistSettings()
            }
            return
        }
        
        var totalTokens = 0
        
        if agentModeEnabled && !agentContextLog.isEmpty {
            // Agent mode but not actively running - show combined estimate
            let messageArray = buildMessageArray()
            let messageText = messageArray.map { $0.content }.joined(separator: "\n")
            totalTokens = TokenEstimator.estimateTokens(messageText, model: model)
            let agentContext = agentContextLog.joined(separator: "\n")
            totalTokens += TokenEstimator.estimateTokens(agentContext, model: model)
        } else {
            // Normal chat mode: estimate from messages
            let messageArray = buildMessageArray()
            let messageText = messageArray.map { $0.content }.joined(separator: "\n")
            totalTokens = TokenEstimator.estimateTokens(messageText, model: model)
        }
        
        // Only update and notify if the value has actually changed
        if currentContextTokens != totalTokens {
            currentContextTokens = totalTokens
        }
        
        if persist {
            persistSettings()  // Persist context tracking per session
        }
    }
    
    /// Record that summarization occurred
    func recordSummarization() {
        summarizationCount += 1
        lastSummarizationDate = Date()
        // Reset accumulated context after summarization since we've compressed it
        accumulatedContextTokens = 0
        persistSettings()  // Persist context tracking per session
    }
    
    /// Reset context tracking state (e.g., when clearing chat)
    func resetContextTracking() {
        currentContextTokens = 0
        accumulatedContextTokens = 0
        lastSummarizationDate = nil
        summarizationCount = 0
        agentSessionTokensUsed = 0
        // Note: persistSettings() is called by the caller (clearChat)
    }
}

// MARK: - Supporting Types

/// Cache for fetched model lists
private struct ModelCache: Codable {
    let models: [String]
    let timestamp: Date
}

private struct SessionSettings: Codable {
    let apiBaseURL: String
    let apiKey: String?
    let model: String
    let providerName: String
    let systemPrompt: String? // Kept for backward compatibility but no longer used
    let sessionTitle: String?
    let agentModeEnabled: Bool?
    
    // Generation settings
    let temperature: Double?
    let maxTokens: Int?
    let reasoningEffort: ReasoningEffort?
    let providerType: ProviderType?
    
    // Provider configuration tracking
    let hasExplicitlyConfiguredProvider: Bool?
    
    // Context size settings
    let customLocalContextSize: Int?
    
    // Context tracking (per-session)
    let currentContextTokens: Int?
    let contextLimitTokens: Int?
    let lastSummarizationDate: Date?
    let summarizationCount: Int?
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
    }
    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
    let choices: [Choice]
    let usage: Usage?
}

private struct OllamaStreamChunk: Decodable {
    struct Message: Decodable { let content: String? }
    let message: Message?
    let response: String?
}

// MARK: - Anthropic Usage Types
private struct AnthropicMessageStart: Decodable {
    struct Message: Decodable {
        struct Usage: Decodable {
            let input_tokens: Int
        }
        let usage: Usage?
    }
    let message: Message?
}

private struct AnthropicMessageDelta: Decodable {
    struct Usage: Decodable {
        let output_tokens: Int
    }
    let usage: Usage?
}