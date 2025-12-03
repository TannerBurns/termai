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

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var role: String
    var content: String
    var terminalContext: String? = nil
    var terminalContextMeta: TerminalContextMeta? = nil
    var agentEvent: AgentEvent? = nil
}

// MARK: - Chat Session

/// A completely self-contained chat session with its own state, messages, and streaming
@MainActor
final class ChatSession: ObservableObject, Identifiable {
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
    
    // Configuration (each session has its own copy)
    @Published var apiBaseURL: URL
    @Published var apiKey: String?
    @Published var model: String
    @Published var providerName: String
    @Published var availableModels: [String] = []
    @Published var modelFetchError: String? = nil
    @Published var titleGenerationError: String? = nil
    
    // Generation settings
    @Published var temperature: Double = 0.7
    @Published var maxTokens: Int = 4096
    @Published var reasoningEffort: ReasoningEffort = .medium
    
    // Provider type tracking
    @Published var providerType: ProviderType = .local(.ollama)
    
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
    
    // System info and prompt
    private let systemInfo: SystemInfo = SystemInfo.gather()
    var systemPrompt: String {
        return systemInfo.injectIntoPrompt()
    }
    
    /// Get system prompt with agent mode instructions when agent mode is enabled
    var agentSystemPrompt: String {
        return systemInfo.injectIntoPromptWithAgentMode()
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
    
    func clearChat() {
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageId = nil
        messages = []
        sessionTitle = ""  // Reset title when clearing chat
        resetContextTracking()  // Reset context tracking state
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
        messages.append(ChatMessage(role: "user", content: text, terminalContext: ctx, terminalContextMeta: meta))
        // Force UI update and persist
        messages = messages
        persistMessages()
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
        
        messages.append(ChatMessage(role: "user", content: text, terminalContext: ctx, terminalContextMeta: meta))
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
        defer { 
            if !agentExecutionPhase.isTerminal {
                transitionToPhase(.idle)
            }
        }
        
        // Append user message first
        appendUserMessage(userPrompt)
        
        // Add an agent status message (collapsed) indicating decision in progress
        messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Agent deciding next action…", details: "Evaluating whether to run commands or reply directly.", command: nil, output: nil, collapsed: true)))
        messages = messages
        persistMessages()
        
        // Check cancellation before first API call
        if checkCancelled(location: "before decision") { return }
        
        transitionToPhase(.deciding)
        
        // Gather environment context for informed decision-making
        let envContext = await gatherQuickContext()
        
        // Ask the model whether to run commands or reply
        let decisionPrompt = """
        You are operating in agent mode inside a terminal-centric app. Commands you run execute DIRECTLY in the user's real shell session (via PTY) - environment changes like `source venv/bin/activate`, `export`, `cd`, etc. WILL persist in their terminal.

        CURRENT ENVIRONMENT (may be incomplete if no commands run yet):
        \(envContext.formatted())

        Given the user's request below, decide one of two actions:
        - RESPOND: ONLY for pure questions/explanations where no action is requested
        - RUN: For ANY request that implies running commands or performing actions

        BIAS TOWARD ACTION: When in doubt, choose RUN. The user is asking you to DO something.
        - "activate venv" → RUN (try common paths: venv, .venv, env)
        - "run tests" → RUN (figure out the test command)
        - "install dependencies" → RUN
        - "build the project" → RUN
        - "what does X do?" → RESPOND (pure question)
        - "explain Y" → RESPOND (pure explanation)

        NOTE: The environment info above may not reflect the user's actual terminal directory. 
        If the request is clearly actionable, choose RUN and discover the environment during execution.

        Reply strictly in JSON on one line with keys: {"action":"RESPOND|RUN", "reason":"short sentence"}.
        User: \(userPrompt)
        """
        let decision = await callOneShotJSON(prompt: decisionPrompt)
        
        // Check cancellation after API call
        if checkCancelled(location: "after decision") { return }
        
        AgentDebugConfig.log("[Agent] Decision: \(decision.raw)")
        
        // Replace last agent status with decision
        if let lastIdx = messages.indices.last, messages[lastIdx].agentEvent != nil {
            let jsonText = decision.raw
            messages[lastIdx] = ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Agent decision", details: jsonText, command: nil, output: nil, collapsed: true))
        }
        messages = messages
        persistMessages()
        
        guard decision.action == "RUN" else {
            // Fall back to normal streaming reply using the same request path
            let assistantIndex = messages.count
            messages.append(ChatMessage(role: "assistant", content: ""))
            streamingMessageId = messages[assistantIndex].id
            messages = messages
            do {
                _ = try await requestChatCompletionStream(assistantIndex: assistantIndex)
            } catch is CancellationError {
                // ignore
            } catch {
                await MainActor.run {
                    self.messages.append(ChatMessage(role: "assistant", content: "Error: \(error.localizedDescription)"))
                }
            }
            await MainActor.run {
                self.streamingMessageId = nil
                self.persistMessages()
            }
            return
        }
        
        // Generate a concrete goal
        transitionToPhase(.settingGoal)
        let goalPrompt = """
        Convert the user's request below into a concise actionable goal a shell-capable agent should accomplish.
        
        CURRENT ENVIRONMENT (reference only, may be incomplete):
        \(envContext.formatted())
        
        Create an actionable goal. Don't over-constrain based on environment - the user knows their setup.
        Examples:
        - "activate venv" → "Activate Python virtual environment"
        - "run tests" → "Run the project's test suite"
        - "build" → "Build the project"
        
        Reply as JSON: {"goal":"short goal phrase"}.
        User: \(userPrompt)
        """
        let goal = await callOneShotJSON(prompt: goalPrompt)
        if checkCancelled(location: "after goal") { return }
        
        messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Goal", details: goal.raw, command: nil, output: nil, collapsed: true)))
        messages = messages
        persistMessages()
        
        // Clear any stale data from previous agent runs
        AgentToolRegistry.shared.clearSession()
        
        // Agent context maintained as a growing log of tool/command outputs
        // NOTE: Don't add GOAL/CHECKLIST here - they're shown separately in the step prompt
        // Adding them here causes confusion with outdated state in the context
        agentContextLog = []
        
        // Reset token tracking for this new agent run
        agentSessionTokensUsed = 0
        accumulatedContextTokens = 0
        currentContextTokens = 0
        
        // Planning phase (if enabled)
        var agentPlan: [String] = []
        var estimatedSteps: Int = 10
        agentChecklist = nil  // Reset checklist
        
        if AgentSettings.shared.enablePlanning {
            if checkCancelled(location: "before planning") { return }
            transitionToPhase(.planning)
            let planPrompt = """
            Create a numbered plan (3-10 steps) to achieve this goal.
            Each step should be a concrete action that can be verified.
            Consider: what commands to run, what to check, what could go wrong.
            IMPORTANT: Include a final verification step to confirm the goal is achieved.
            Reply JSON: {"plan": ["step 1 description", "step 2 description", ..., "Verify: <verification action>"], "estimated_commands": 5}
            GOAL: \(goal.goal ?? "")
            ENVIRONMENT:
            - Current Working Directory: \(self.lastKnownCwd.isEmpty ? "(unknown)" : self.lastKnownCwd)
            - Shell: /bin/zsh
            """
            AgentDebugConfig.log("[Agent] Planning prompt =>\n\(planPrompt)")
            let planResult = await callOneShotJSON(prompt: planPrompt)
            if checkCancelled(location: "after planning") { return }
            AgentDebugConfig.log("[Agent] Plan: \(planResult.raw)")
            
            if let steps = planResult.plan, !steps.isEmpty {
                agentPlan = steps
                estimatedSteps = planResult.estimatedCommands ?? steps.count
                
                // Create the task checklist from the plan
                agentChecklist = TaskChecklist(from: steps, goal: goal.goal ?? "")
                
                // Display checklist with status indicators
                let checklistDisplay = agentChecklist!.displayString
                messages.append(ChatMessage(
                    role: "assistant",
                    content: "",
                    agentEvent: AgentEvent(
                        kind: "checklist",
                        title: "Task Checklist (\(steps.count) items)",
                        details: checklistDisplay,
                        command: nil,
                        output: nil,
                        collapsed: false,
                        checklistItems: agentChecklist!.items
                    )
                ))
                // NOTE: Don't add checklist to agentContextLog - it's shown separately in step prompt
                // and would show stale state as the checklist updates
            } else {
                messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Plan", details: "Could not generate plan, proceeding with adaptive execution", command: nil, output: nil, collapsed: true)))
            }
            messages = messages
            persistMessages()
        }
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
        var fixAttempts = 0
        let maxFixAttempts = AgentSettings.shared.maxFixAttempts
        var recentCommands: [String] = []  // Track recent commands for stuck detection
        var currentPlanStep = 0
        var emptyResponseCount = 0  // Track consecutive empty LLM responses
        var unknownToolCount = 0  // Track consecutive unknown tool calls to prevent loops
        let reflectionInterval = AgentSettings.shared.reflectionInterval
        let stuckThreshold = AgentSettings.shared.stuckDetectionThreshold
        
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
                let checklistStatus = agentChecklist?.displayString ?? (agentPlan.isEmpty ? "No plan" : agentPlan.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "; "))
                
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
                
                GOAL: \(goal.goal ?? "")
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
                    let stuckPrompt = """
                    The agent appears stuck, running similar commands repeatedly without progress.
                    Recent commands: \(lastN.joined(separator: "; "))
                    Decide: is this truly stuck? If so, suggest a completely different approach.
                    Reply JSON: {"is_stuck": true/false, "new_approach": "different strategy to try", "should_stop": true/false}
                    GOAL: \(goal.goal ?? "")
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
            
            // Build checklist/plan context for the step prompt
            let checklistContext: String
            if let checklist = agentChecklist {
                checklistContext = checklist.displayString
            } else if !agentPlan.isEmpty {
                let planWithMarkers = agentPlan.enumerated().map { idx, step in
                    let marker = idx < currentPlanStep ? "✓" : (idx == currentPlanStep ? "→" : "○")
                    return "\(marker) \(idx + 1). \(step)"
                }.joined(separator: "\n")
                checklistContext = "PLAN:\n\(planWithMarkers)\nCurrent step: \(currentPlanStep + 1) of \(agentPlan.count)"
            } else {
                checklistContext = ""
            }
            
            let stepPrompt = """
            You are a terminal agent executing commands in the user's REAL shell (PTY). Based on the GOAL and CONTEXT below, decide the next action.
            
            GOAL REMINDER: \(goal.goal ?? "")
            Progress: Step \(iterations) of max \(maxIterations == 0 ? "unlimited" : String(maxIterations))
            
            AVAILABLE TOOLS (prefer these over complex shell commands):
            FILE OPERATIONS:
            1. "write_file" - Create or overwrite entire file. Args: path, content, mode (overwrite|append)
            2. "edit_file" - Edit file by replacing specific text. Args: path, old_text, new_text, replace_all (true/false)
            3. "insert_lines" - Insert content at line number. Args: path, line_number, content
            4. "delete_lines" - Delete line range. Args: path, start_line, end_line
            5. "read_file" - Read file contents. Args: path, start_line (optional), end_line (optional)
            6. "list_dir" - List directory. Args: path, recursive (true|false)
            7. "search_files" - Find files by pattern. Args: path, pattern (e.g. "*.swift")
            
            SHELL & PROCESS:
            8. "command" - Run a simple shell command (ls, mkdir, cd, git, npm, node, source, python, etc.)
            9. "run_background" - Start server/process in background. Args: command, wait_for (text to detect startup), timeout
            10. "check_process" - Check process status. Args: pid, port, or list=true
            11. "stop_process" - Stop a background process. Args: pid, or all=true
            
            VERIFICATION:
            12. "http_request" - Test API endpoints. Args: url, method (GET/POST/PUT/DELETE), body, headers
            13. "search_output" - Search previous command outputs. Args: pattern
            
            CONTEXT LOG FORMAT (how to read the CONTEXT section):
            - "RAN: <command>" = command that was executed
            - "OUTPUT: ..." = command output (may be empty for silent commands)
            - "EXIT_CODE: N" = exit code (0=success, non-zero=failure)
            - "CWD: /path" = current working directory after command
            - Many commands (cd, source, mkdir, export) succeed SILENTLY with no output
            
            RULES:
            - For creating NEW files, use write_file tool
            - For EDITING existing files, use edit_file (search/replace) or insert_lines/delete_lines
            - For reading files, use read_file tool instead of cat
            - Use shell commands for: mkdir, ls, cd, git, grep, find, npm, node, source, python, etc.
            - Environment commands (source venv/bin/activate, export, cd) run in user's real shell and PERSIST
            - For servers: use run_background to start, http_request to test endpoints
            - For MARKDOWN: Always include blank lines before headings (## Title) when inserting
            - ALWAYS verify your edits by reading the file after making changes
            - Before declaring done, VERIFY the goal is achieved (check files exist, test endpoints, etc.)
            - Output strictly valid JSON on ONE line
            
            RESPONSE FORMAT:
            {"step":"description", "tool":"tool_name", "command":"shell command if tool=command", "tool_args":{"path":"...", "content":"..."}, "checklist_item": 1}
            
            NOTE: Include "checklist_item" with the item number you're working on from the checklist.
            
            ENVIRONMENT:
            - CWD: \(self.lastKnownCwd.isEmpty ? "(unknown)" : self.lastKnownCwd)
            - Shell: /bin/zsh (user's real shell - environment changes persist)
            
            \(checklistContext)
            
            CONTEXT:\n\(contextBlob)
            """
            AgentDebugConfig.log("[Agent] Step prompt =>\n\(stepPrompt)")
            let step = await callOneShotJSONWithRetry(prompt: stepPrompt)
            
            // Check for cancellation after LLM call
            if agentCancelled {
                AgentDebugConfig.log("[Agent] Cancelled after step prompt")
                break stepLoop
            }
            
            let commandToRun = step.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let toolToUse = step.tool?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "command"
            let toolArgs = step.toolArgs ?? [:]
            let workingOnChecklistItem = step.checklistItem
            
            // Mark checklist item as in progress
            if let itemId = workingOnChecklistItem, var checklist = agentChecklist {
                checklist.markInProgress(itemId)
                agentChecklist = checklist  // Explicit reassignment triggers @Published
                updateChecklistMessage()
            }
            
            // Check if this is a tool call rather than a shell command
            if toolToUse != "command" && !toolToUse.isEmpty {
                
                // Special handling for "done" tool - LLM is signaling completion
                // This prevents infinite loops where the LLM keeps calling "done"
                if toolToUse == "done" || toolToUse == "complete" || toolToUse == "finish" {
                    AgentDebugConfig.log("[Agent] Detected completion signal via tool='\(toolToUse)', running assessment...")
                    
                    // Run a goal assessment to verify if we're actually done
                    let checklistStatus = (self.agentChecklist?.items ?? []).map { 
                        let status = $0.status == .completed ? "✓" : ($0.status == .failed ? "✗" : "○")
                        return "\(status) \($0.description)"
                    }.joined(separator: "\n")
                    
                    let completedCount = (self.agentChecklist?.items ?? []).filter { $0.status == .completed }.count
                    let totalCount = self.agentChecklist?.items.count ?? 0
                    
                    let assessPrompt = """
                    The agent is signaling completion. Verify if the GOAL is actually achieved.
                    The goal is ONLY complete if ALL checklist items are marked ✓ (completed).
                    
                    NOTE: Exit code 0 = success. Commands like cd, source, mkdir, export succeed silently (no output).
                    
                    Reply JSON: {"done":true|false, "reason":"short explanation"}.
                    GOAL: \(goal.goal ?? "")
                    CHECKLIST (\(completedCount)/\(totalCount) completed):
                    \(checklistStatus)
                    RECENT CONTEXT:\n\(agentContextLog.suffix(10).joined(separator: "\n"))
                    """
                    
                    let assess = await callOneShotJSON(prompt: assessPrompt)
                    if checkCancelled(location: "after done-tool assess") { break stepLoop }
                    AgentDebugConfig.log("[Agent] Done-tool assessment: \(assess.raw)")
                    
                    if assess.done == true {
                        // Actually complete - summarize and finish
                        transitionToPhase(.summarizing)
                        let summaryPrompt = """
                        Summarize concisely what was done to achieve the goal and the result. Reply markdown.
                        GOAL: \(goal.goal ?? "")
                        CONTEXT:\n\(agentContextLog.joined(separator: "\n"))
                        """
                        let summaryText = await callOneShotText(prompt: summaryPrompt)
                        messages.append(ChatMessage(role: "assistant", content: summaryText))
                        messages = messages
                        persistMessages()
                        transitionToPhase(.completed)
                        break stepLoop
                    } else {
                        // Not actually done - add context to help LLM understand what's still needed
                        let incompleteItems = (self.agentChecklist?.items ?? []).filter { $0.status != .completed }
                        let itemsList = incompleteItems.map { "- \($0.description)" }.joined(separator: "\n")
                        
                        agentContextLog.append("COMPLETION CHECK: Not done yet. Remaining items:\n\(itemsList)")
                        messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Not yet complete", details: "Still need to complete:\n\(itemsList)", command: nil, output: nil, collapsed: false)))
                        messages = messages
                        persistMessages()
                        continue stepLoop
                    }
                }
                
                // Execute agent tool
                messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "step", title: step.step ?? "Using tool: \(toolToUse)", details: "Args: \(toolArgs)", command: nil, output: nil, collapsed: true)))
                messages = messages
                persistMessages()
                
                if let tool = AgentToolRegistry.shared.get(toolToUse) {
                    // Add session ID for file coordination
                    var argsWithSession = toolArgs
                    argsWithSession["_sessionId"] = self.id.uuidString
                    
                    // Check if this is a file operation and show waiting status if needed
                    let isFileOp = ["write_file", "edit_file", "insert_lines", "delete_lines"].contains(toolToUse)
                    let previousPhase = agentExecutionPhase
                    if isFileOp, let path = toolArgs["path"] {
                        // Check if we'll need to wait for this file
                        if let lockHolder = FileLockManager.shared.lockHolder(for: path), lockHolder != self.id {
                            transitionToPhase(.waitingForFileLock(file: path))
                            messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "⏳ Waiting for file access", details: "Another session is editing: \(URL(fileURLWithPath: path).lastPathComponent)", command: nil, output: nil, collapsed: false)))
                            messages = messages
                            persistMessages()
                        }
                    }
                    
                    // Execute tool - use approval flow for file operations if enabled
                    let result: AgentToolResult
                    if isFileOp {
                        result = await executeFileToolWithApproval(
                            tool: tool,
                            toolName: toolToUse,
                            args: argsWithSession,
                            cwd: self.lastKnownCwd.isEmpty ? nil : self.lastKnownCwd
                        )
                    } else {
                        result = await tool.execute(args: argsWithSession, cwd: self.lastKnownCwd.isEmpty ? nil : self.lastKnownCwd)
                    }
                    
                    // Restore execution phase if we were waiting
                    if case .waitingForFileLock = agentExecutionPhase {
                        agentExecutionPhase = previousPhase
                    }
                    
                    if checkCancelled(location: "after tool execution") { break stepLoop }
                    
                    let resultOutput = result.success ? result.output : "ERROR: \(result.error ?? "Unknown error")"
                    
                    agentContextLog.append("TOOL: \(toolToUse) \(toolArgs)")
                    agentContextLog.append("RESULT: \(resultOutput.prefix(AgentSettings.shared.maxOutputCapture))")
                    
                    // Include file change info in the result message if available
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: result.success ? "Tool succeeded" : "Tool failed", details: String(resultOutput.prefix(500)), command: nil, output: resultOutput, collapsed: true, fileChange: result.fileChange)))
                    messages = messages
                    persistMessages()
                    
                    // Update checklist item status
                    if let itemId = workingOnChecklistItem, var checklist = agentChecklist {
                        if result.success {
                            checklist.markCompleted(itemId, note: "Done")
                        } else {
                            checklist.markFailed(itemId, note: result.error?.prefix(50).description)
                        }
                        agentChecklist = checklist  // Explicit reassignment triggers @Published
                        updateChecklistMessage()
                    }
                    
                    // Advance plan step if we completed something
                    if result.success && !agentPlan.isEmpty && currentPlanStep < agentPlan.count {
                        currentPlanStep += 1
                    }
                    
                    // For write/edit operations, do a quick goal assessment
                    // Only check completion if ALL checklist items are done
                    let pendingItems = (self.agentChecklist?.items ?? []).filter { $0.status == .pending || $0.status == .inProgress }
                    if result.success && pendingItems.isEmpty && (toolToUse == "write_file" || toolToUse == "edit_file" || toolToUse == "insert_lines") {
                        let checklistStatus = (self.agentChecklist?.items ?? []).map { "\($0.status.rawValue) \($0.description)" }.joined(separator: "\n")
                        let quickAssess = """
                        Based on the tool result and checklist status, is the GOAL now complete? 
                        The goal is ONLY complete if ALL checklist items are marked ✓ (completed).
                        Reply JSON: {"done":true|false, "reason":"short"}.
                        GOAL: \(goal.goal ?? "")
                        CHECKLIST:
                        \(checklistStatus)
                        TOOL USED: \(toolToUse)
                        RESULT: \(resultOutput.prefix(500))
                        """
                        let assessResult = await callOneShotJSON(prompt: quickAssess)
                        if checkCancelled(location: "after tool assess") { break stepLoop }
                        
                        if assessResult.done == true {
                            AgentDebugConfig.log("[Agent] Goal completed after tool: \(assessResult.raw)")
                            transitionToPhase(.summarizing)
                            let summaryPrompt = """
                            Summarize concisely what was done to achieve the goal and the result. Reply markdown.
                            GOAL: \(goal.goal ?? "")
                            CONTEXT:\n\(agentContextLog.joined(separator: "\n"))
                            """
                            let summaryText = await callOneShotText(prompt: summaryPrompt)
                            messages.append(ChatMessage(role: "assistant", content: summaryText))
                            messages = messages
                            persistMessages()
                            transitionToPhase(.completed)
                            break stepLoop
                        }
                    }
                    // Reset unknown tool counter on successful tool call
                    unknownToolCount = 0
                } else {
                    // Unknown tool - track and prevent infinite loops
                    unknownToolCount += 1
                    AgentDebugConfig.log("[Agent] Unknown tool '\(toolToUse)' (attempt \(unknownToolCount))")
                    
                    agentContextLog.append("TOOL: \(toolToUse) - not found. Use one of: read_file, write_file, edit_file, insert_lines, delete_lines, list_dir, search_files, run_background, check_process, stop_process, http_request, or 'command' for shell commands.")
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Unknown tool: \(toolToUse)", details: "Available tools: \(AgentToolRegistry.shared.allTools().map { $0.name }.joined(separator: ", ")), or use 'command' for shell commands", command: nil, output: nil, collapsed: true)))
                    messages = messages
                    persistMessages()
                    
                    // Fail-safe: stop if we get too many unknown tool calls in a row
                    if unknownToolCount >= 3 {
                        AgentDebugConfig.log("[Agent] Too many unknown tool calls, stopping")
                        messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Agent stopped", details: "Unable to continue - the model keeps requesting unavailable tools. Please rephrase your request.", command: nil, output: nil, collapsed: false)))
                        messages = messages
                        persistMessages()
                        break stepLoop
                    }
                }
                
                continue stepLoop
            }
            
            // Handle empty response from LLM
            let stepDescription = step.step?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if commandToRun.isEmpty && stepDescription.isEmpty && toolToUse == "command" {
                // No valid action from LLM - log and continue (retries already attempted)
                AgentDebugConfig.log("[Agent] No action returned from LLM after retries, continuing...")
                messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "⚠️ Temporary issue", details: "Could not determine next action. Retrying...", command: nil, output: nil, collapsed: true)))
                messages = messages
                persistMessages()
                emptyResponseCount += 1
                
                // Fail-safe: if we get too many empty responses in a row, stop
                if emptyResponseCount >= 3 {
                    AgentDebugConfig.log("[Agent] Too many empty responses, stopping")
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Agent stopped", details: "Unable to continue - received too many empty responses from the model.", command: nil, output: nil, collapsed: true)))
                    messages = messages
                    persistMessages()
                    break stepLoop
                }
                continue stepLoop
            }
            
            // Reset counters on successful action (command execution)
            emptyResponseCount = 0
            unknownToolCount = 0
            
            messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "step", title: stepDescription.isEmpty ? "Next step" : stepDescription, details: nil, command: commandToRun, output: nil, collapsed: true)))
            messages = messages
            persistMessages()
            
            // If tool action but command is empty, it was handled above - skip command execution
            guard !commandToRun.isEmpty else { continue stepLoop }
            
            // Execute command with optional approval flow
            let capturedOut: String?
            if AgentSettings.shared.requireCommandApproval && !AgentSettings.shared.shouldAutoApprove(commandToRun) {
                // Use approval flow
                capturedOut = await executeCommandWithApproval(commandToRun)
                
                // Track command for stuck detection
                recentCommands.append(commandToRun)
                if recentCommands.count > 10 { recentCommands.removeFirst() }
                
                // Check if command was rejected
                if capturedOut == nil && !agentContextLog.contains(where: { $0.contains("RAN: \(commandToRun)") }) {
                    // Command was rejected, skip this iteration
                    continue stepLoop
                }
            } else {
                // Direct execution without approval
                let runningTitle = "Executing command in terminal"
                messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: runningTitle, details: "\(commandToRun)", command: commandToRun, output: nil, collapsed: false)))
                messages = messages
                persistMessages()
                
                AgentDebugConfig.log("[Agent] Executing command: \(commandToRun)")
                NotificationCenter.default.post(name: .TermAIExecuteCommand, object: nil, userInfo: [
                    "sessionId": self.id,
                    "command": commandToRun
                ])
                
                capturedOut = await waitForCommandOutput(matching: commandToRun, timeout: AgentSettings.shared.commandTimeout)
                agentContextLog.append("RAN: \(commandToRun)")
                recentCommands.append(commandToRun)
                if recentCommands.count > 10 { recentCommands.removeFirst() }
                
                // Track tool call execution
                TokenUsageTracker.shared.recordToolCall(
                    provider: providerName,
                    model: model,
                    command: commandToRun
                )
                
                if let out = capturedOut, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Store in buffer for search
                    AgentToolRegistry.shared.storeOutput(out, command: commandToRun)
                    // Summarize if output is long
                    let processedOutput = await summarizeOutput(out, command: commandToRun)
                    agentContextLog.append("OUTPUT: \(processedOutput)")
                }
            }
            
            AgentDebugConfig.log("[Agent] Command finished. cwd=\(self.lastKnownCwd), exit=\(lastExitCodeString())\nOutput (first 500 chars):\n\((capturedOut ?? "(no output)").prefix(500))")
            
            // Check for cancellation after command execution
            if agentCancelled {
                AgentDebugConfig.log("[Agent] Cancelled after command execution")
                break stepLoop
            }
            
            // Check for user feedback after command execution
            if let feedback = consumePendingFeedback() {
                agentContextLog.append("USER FEEDBACK (after command): \(feedback)")
                messages.append(ChatMessage(
                    role: "assistant",
                    content: "",
                    agentEvent: AgentEvent(
                        kind: "status",
                        title: "Received user feedback",
                        details: "Adjusting next action based on your input.",
                        command: nil,
                        output: nil,
                        collapsed: true
                    )
                ))
                messages = messages
                persistMessages()
            }
            
            // Advance plan step if command succeeded
            if lastExitCodeString() == "0" && !agentPlan.isEmpty && currentPlanStep < agentPlan.count {
                currentPlanStep += 1
            }
            
            // Analyze command outcome; propose fixes if failed
            let analyzePrompt = """
            Analyze the following command execution and decide outcome and next action.
            
            INTERPRETATION GUIDE:
            - EXIT_CODE 0 = success (even if output is empty - many commands succeed silently)
            - EXIT_CODE non-zero = failure (check output for error messages)
            - Commands like cd, source, export, mkdir often produce NO output on success
            - "(no output)" with EXIT_CODE 0 typically means the command succeeded
            
            Reply strictly as JSON on one line with keys:
            {"outcome":"success|fail|uncertain", "reason":"short", "next":"continue|stop|fix", "fixed_command":"optional replacement if next=fix else empty"}
            GOAL: \(goal.goal ?? "")
            COMMAND: \(commandToRun)
            EXIT_CODE: \(lastExitCodeString())
            OUTPUT:\n\(capturedOut ?? "(no output)")
            CWD: \(self.lastKnownCwd.isEmpty ? "(unknown)" : self.lastKnownCwd)
            """
            AgentDebugConfig.log("[Agent] Analyze prompt =>\n\(analyzePrompt)")
            let analysis = await callOneShotJSON(prompt: analyzePrompt)
            if checkCancelled(location: "after analysis") { break stepLoop }
            AgentDebugConfig.log("[Agent] Analysis: \(analysis.raw)")
            
            // Update checklist item status for shell commands (mirrors tool execution logic)
            if let itemId = workingOnChecklistItem, var checklist = agentChecklist {
                let outcome = analysis.outcome?.lowercased() ?? ""
                if outcome == "success" {
                    checklist.markCompleted(itemId, note: "Done")
                } else if outcome == "fail" {
                    checklist.markFailed(itemId, note: analysis.reason?.prefix(50).description)
                }
                // "uncertain" leaves it in progress for now
                agentChecklist = checklist  // Explicit reassignment triggers @Published
                updateChecklistMessage()
            }
            
            if analysis.next == "fix", let fixed = analysis.fixed_command?.trimmingCharacters(in: .whitespacesAndNewlines), !fixed.isEmpty, fixAttempts < maxFixAttempts {
                fixAttempts += 1
                messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Fixing command and retrying", details: fixed, command: fixed, output: nil, collapsed: false)))
                messages = messages
                persistMessages()
                
                // Execute fix command with optional approval
                let fixOut: String?
                if AgentSettings.shared.requireCommandApproval && !AgentSettings.shared.shouldAutoApprove(fixed) {
                    fixOut = await executeCommandWithApproval(fixed)
                    if fixOut == nil && !agentContextLog.contains(where: { $0.contains("RAN: \(fixed)") }) {
                        // Fix command was rejected, continue without fix
                        continue stepLoop
                    }
                } else {
                    AgentDebugConfig.log("[Agent] Fixing by executing: \(fixed)")
                    NotificationCenter.default.post(name: .TermAIExecuteCommand, object: nil, userInfo: [
                        "sessionId": self.id,
                        "command": fixed
                    ])
                    fixOut = await waitForCommandOutput(matching: fixed, timeout: AgentSettings.shared.commandTimeout)
                    agentContextLog.append("RAN: \(fixed)")
                    recentCommands.append(fixed)
                    if recentCommands.count > 10 { recentCommands.removeFirst() }
                    
                    if let out = fixOut, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let processedOutput = await summarizeOutput(out, command: fixed)
                        agentContextLog.append("OUTPUT: \(processedOutput)")
                    }
                }
                // Immediately reassess after a fix attempt based on exit code, output, and checklist
                let postFixItems = self.agentChecklist?.items ?? []
                let postFixChecklistStatus = postFixItems.map { "\($0.status.rawValue) \($0.description)" }.joined(separator: "\n")
                let postFixCompletedCount = postFixItems.filter { $0.status == .completed }.count
                let postFixTotalCount = postFixItems.count
                let quickAssessPrompt = """
                Decide if the GOAL is now achieved after the fix attempt.
                The goal is ONLY complete if ALL checklist items are marked ✓ (completed).
                
                NOTE: Exit code 0 = success. Commands like cd, source, mkdir, export succeed silently (no output).
                
                Reply JSON: {"done":true|false, "reason":"short"}.
                GOAL: \(goal.goal ?? "")
                CHECKLIST (\(postFixCompletedCount)/\(postFixTotalCount) completed):
                \(postFixChecklistStatus)
                BASE CONTEXT:
                - Current Working Directory: \(self.lastKnownCwd.isEmpty ? "(unknown)" : self.lastKnownCwd)
                - Last Command: \(fixed)
                - Last Exit Code: \(lastExitCodeString())
                - Last Output: \((fixOut ?? "(none - command succeeded silently)").prefix(AgentSettings.shared.maxOutputCapture))
                CONTEXT:\n\(agentContextLog.joined(separator: "\n"))
                """
                AgentDebugConfig.log("[Agent] Post-fix assess prompt =>\n\(quickAssessPrompt)")
                let quickAssess = await callOneShotJSON(prompt: quickAssessPrompt)
                AgentDebugConfig.log("[Agent] Post-fix assess: \(quickAssess.raw)")
                messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Post-fix assessment", details: quickAssess.raw, command: nil, output: nil, collapsed: true)))
                messages = messages
                persistMessages()
                if quickAssess.done == true {
                    transitionToPhase(.summarizing)
                    let summaryPrompt = """
                    Summarize concisely what was done to achieve the goal and the result. Reply markdown.
                    GOAL: \(goal.goal ?? "")
                    CONTEXT:\n\(agentContextLog.joined(separator: "\n"))
                    """
                    AgentDebugConfig.log("[Agent] Summary prompt =>\n\(summaryPrompt)")
                    let summaryText = await callOneShotText(prompt: summaryPrompt)
                    messages.append(ChatMessage(role: "assistant", content: summaryText))
                    messages = messages
                    persistMessages()
                    transitionToPhase(.completed)
                    break stepLoop
                }
            }
            
            // Ask if goal achieved, with latest context and checklist status
            let assessItems = self.agentChecklist?.items ?? []
            let checklistStatus = assessItems.map { "\($0.status.rawValue) \($0.description)" }.joined(separator: "\n")
            let completedCount = assessItems.filter { $0.status == .completed }.count
            let totalCount = assessItems.count
            let assessPrompt = """
            Given the GOAL, CHECKLIST, and CONTEXT, decide if the goal is accomplished.
            The goal is ONLY complete if ALL checklist items are marked ✓ (completed).
            
            NOTE: Exit code 0 = success. Many commands (cd, source, mkdir, export) succeed silently with no output.
            
            Reply JSON: {"done":true|false, "reason":"short"}.
            GOAL: \(goal.goal ?? "")
            CHECKLIST (\(completedCount)/\(totalCount) completed):
            \(checklistStatus)
            BASE CONTEXT:
            - Current Working Directory: \(self.lastKnownCwd.isEmpty ? "(unknown)" : self.lastKnownCwd)
            - Last Command: \(commandToRun)
            - Last Exit Code: \(lastExitCodeString())
            - Last Output: \((capturedOut ?? "(none - command succeeded silently)").prefix(AgentSettings.shared.maxOutputCapture))
            CONTEXT:\n\(agentContextLog.joined(separator: "\n"))
            """
            AgentDebugConfig.log("[Agent] Assess prompt =>\n\(assessPrompt)")
            let assess = await callOneShotJSON(prompt: assessPrompt)
            if checkCancelled(location: "after assess") { break stepLoop }
            AgentDebugConfig.log("[Agent] Assess result => \(assess.raw)")
            messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Assessment", details: assess.raw, command: nil, output: nil, collapsed: true)))
            messages = messages
            persistMessages()
            
            if assess.done == true {
                // Run verification phase if enabled
                if AgentSettings.shared.enableVerificationPhase {
                    transitionToPhase(.verifying)
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "🔍 Verification Phase", details: "Running final verification before completing...", command: nil, output: nil, collapsed: false)))
                    messages = messages
                    persistMessages()
                    
                    let verificationPassed = await runVerificationPhase(goal: goal.goal ?? "", context: agentContextLog)
                    if checkCancelled(location: "after verification") { break stepLoop }
                    
                    if !verificationPassed {
                        // Verification failed, continue trying
                        agentContextLog.append("VERIFICATION: Failed - continuing to fix issues")
                        messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "⚠️ Verification incomplete", details: "Some checks did not pass. Continuing to address issues...", command: nil, output: nil, collapsed: true)))
                        messages = messages
                        persistMessages()
                        continue stepLoop
                    }
                    
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "✓ Verification passed", details: "All checks completed successfully", command: nil, output: nil, collapsed: true)))
                    messages = messages
                    persistMessages()
                }
                
                // Mark all remaining checklist items as complete
                if var checklist = agentChecklist {
                    for item in checklist.remainingItems {
                        checklist.markCompleted(item.id, note: "Done")
                    }
                    agentChecklist = checklist
                    updateChecklistMessage()
                }
                
                // Summarize actions
                transitionToPhase(.summarizing)
                let summaryPrompt = """
                Summarize concisely what was done to achieve the goal and the result. Reply markdown.
                GOAL: \(goal.goal ?? "")
                CONTEXT:\n\(agentContextLog.joined(separator: "\n"))
                """
                let summaryText = await callOneShotText(prompt: summaryPrompt)
                messages.append(ChatMessage(role: "assistant", content: summaryText))
                messages = messages
                persistMessages()
                transitionToPhase(.completed)
                break stepLoop
            } else {
                // Only ask about continuing if we've done many iterations (to avoid API call overhead)
                // The normal flow is to just continue to the next step
                if iterations > 0 && iterations % 20 == 0 {
                    // Every 20 iterations, check if we should continue or stop
                    let contPrompt = """
                    Decide whether to CONTINUE or STOP given diminishing returns. Reply JSON: {"decision":"CONTINUE|STOP", "reason":"short"}.
                    GOAL: \(goal.goal ?? "")
                    CONTEXT (last 10 entries):\n\(agentContextLog.suffix(10).joined(separator: "\n"))
                    """
                    let cont = await callOneShotJSONWithRetry(prompt: contPrompt, maxRetries: 2)
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Continue check", details: cont.raw, command: nil, output: nil, collapsed: true)))
                    messages = messages
                    persistMessages()
                    if cont.decision == "STOP" { 
                        let summaryPrompt = """
                        Summarize what was done so far and suggest next steps. Reply markdown.
                        GOAL: \(goal.goal ?? "")
                        CONTEXT:\n\(agentContextLog.joined(separator: "\n"))
                        """
                        let summaryText = await callOneShotText(prompt: summaryPrompt)
                        messages.append(ChatMessage(role: "assistant", content: summaryText))
                        messages = messages
                        persistMessages()
                        break stepLoop
                    }
                }
                // Otherwise, just continue to next step
            }
        }
    }
    
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
    
    /// Unified Codable struct for all agent JSON responses - decoded in a single pass
    private struct UnifiedAgentJSON: Decodable {
        // Decision fields
        let action: String?
        let reason: String?
        
        // Goal/Plan fields
        let goal: String?
        let plan: [String]?
        let estimated_commands: Int?
        
        // Step/Command fields
        let step: String?
        let command: String?
        let tool: String?
        var tool_args: [String: String]?
        let checklist_item: Int?
        
        // Assessment fields
        let done: Bool?
        let decision: String?
        let outcome: String?
        let next: String?
        let fixed_command: String?
        
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
        
        private enum CodingKeys: String, CodingKey {
            case action, reason, goal, plan, estimated_commands
            case step, command, tool, tool_args, checklist_item
            case done, decision, outcome, next, fixed_command
            case progress_percent, on_track, completed, remaining, should_adjust, new_approach
            case is_stuck, should_stop
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            // Decode simple fields
            action = try container.decodeIfPresent(String.self, forKey: .action)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            goal = try container.decodeIfPresent(String.self, forKey: .goal)
            plan = try container.decodeIfPresent([String].self, forKey: .plan)
            estimated_commands = try container.decodeIfPresent(Int.self, forKey: .estimated_commands)
            step = try container.decodeIfPresent(String.self, forKey: .step)
            command = try container.decodeIfPresent(String.self, forKey: .command)
            tool = try container.decodeIfPresent(String.self, forKey: .tool)
            checklist_item = try container.decodeIfPresent(Int.self, forKey: .checklist_item)
            done = try container.decodeIfPresent(Bool.self, forKey: .done)
            decision = try container.decodeIfPresent(String.self, forKey: .decision)
            outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
            next = try container.decodeIfPresent(String.self, forKey: .next)
            fixed_command = try container.decodeIfPresent(String.self, forKey: .fixed_command)
            progress_percent = try container.decodeIfPresent(Int.self, forKey: .progress_percent)
            on_track = try container.decodeIfPresent(Bool.self, forKey: .on_track)
            completed = try container.decodeIfPresent([String].self, forKey: .completed)
            remaining = try container.decodeIfPresent([String].self, forKey: .remaining)
            should_adjust = try container.decodeIfPresent(Bool.self, forKey: .should_adjust)
            new_approach = try container.decodeIfPresent(String.self, forKey: .new_approach)
            is_stuck = try container.decodeIfPresent(Bool.self, forKey: .is_stuck)
            should_stop = try container.decodeIfPresent(Bool.self, forKey: .should_stop)
            
            // Handle tool_args with mixed types
            if let rawArgs = try? container.decodeIfPresent([String: AnyCodable].self, forKey: .tool_args) {
                var stringArgs: [String: String] = [:]
                for (key, value) in rawArgs {
                    stringArgs[key] = value.stringValue
                }
                tool_args = stringArgs
            } else {
                tool_args = nil
            }
        }
    }
    
    /// Parsed JSON response from the agent
    struct AgentJSONResponse {
        let raw: String
        var action: String? = nil
        var reason: String? = nil
        var goal: String? = nil
        var plan: [String]? = nil
        var estimatedCommands: Int? = nil
        var step: String? = nil
        var command: String? = nil
        var tool: String? = nil
        var toolArgs: [String: String]? = nil
        var checklistItem: Int? = nil
        var done: Bool? = nil
        var decision: String? = nil
        var outcome: String? = nil
        var next: String? = nil
        var fixed_command: String? = nil
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
            response.step = unified.step
            response.command = unified.command
            response.tool = unified.tool
            response.toolArgs = unified.tool_args
            response.checklistItem = unified.checklist_item
            response.done = unified.done
            response.decision = unified.decision
            response.outcome = unified.outcome
            response.next = unified.next
            response.fixed_command = unified.fixed_command
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
            
            // Check for valid response - need at least a step description or command
            let hasContent = (response.step != nil && !response.step!.isEmpty) ||
                           (response.command != nil && !response.command!.isEmpty) ||
                           (response.tool != nil && !response.tool!.isEmpty)
            
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
            let result = try await LLMClient.shared.completeWithUsage(
                systemPrompt: agentSystemPrompt,
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
    
    // MARK: - File Change Approval
    
    /// Request user approval for a file change before applying it
    private func requestFileChangeApproval(fileChange: FileChange, toolName: String, toolArgs: [String: String]) async -> Bool {
        // Check if approval is required
        guard AgentSettings.shared.requireFileEditApproval else {
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
        
        // Add a pending approval message
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
                fileChange: fileChange
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
        if let fileOpTool = tool as? FileOperationTool,
           AgentSettings.shared.requireFileEditApproval {
            // Get the preview of changes
            if let fileChange = await fileOpTool.prepareChange(args: args, cwd: cwd) {
                // Request approval
                let approved = await requestFileChangeApproval(
                    fileChange: fileChange,
                    toolName: toolName,
                    toolArgs: args
                )
                
                if !approved {
                    // File change was rejected
                    messages.append(ChatMessage(
                        role: "assistant",
                        content: "",
                        agentEvent: AgentEvent(
                            kind: "status",
                            title: "File change rejected",
                            details: "User declined to apply changes to: \(fileChange.fileName)",
                            command: nil,
                            output: nil,
                            collapsed: true,
                            fileChange: fileChange
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
                        details: "Applying changes to: \(fileChange.fileName)",
                        command: nil,
                        output: nil,
                        collapsed: true,
                        fileChange: fileChange
                    )
                ))
                messages = messages
                persistMessages()
            }
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
                self?.titleGenerationError = "Cannot generate title: No model selected"
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
                        self?.titleGenerationError = "Title generation was cancelled"
                    }
                    return 
                }
                
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = "Invalid response from server"
                    }
                    return
                }
                
                guard (200..<300).contains(http.statusCode) else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = "Title generation failed (HTTP \(http.statusCode)): \(errorBody)"
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
                        providerForTracking = cloudProvider == .anthropic ? "Anthropic" : "OpenAI"
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
                    await MainActor.run { [weak self] in
                        self?.titleGenerationError = "Could not parse title from response. Response: \(responseBody)"
                    }
                }
            } catch {
                let errorMessage: String
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .timedOut:
                        errorMessage = "Request timed out (URLError)"
                    case .notConnectedToInternet:
                        errorMessage = "No internet connection"
                    case .cannotConnectToHost:
                        errorMessage = "Cannot connect to host: \(self.apiBaseURL.host ?? "unknown")"
                    default:
                        errorMessage = "Network error: \(urlError.localizedDescription)"
                    }
                } else {
                    errorMessage = "Title generation error: \(error.localizedDescription)"
                }
                
                await MainActor.run { [weak self] in
                    self?.titleGenerationError = errorMessage
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
                        self?.titleGenerationError = "Title generation timed out after 90 seconds"
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
        
        let allMessages = buildMessageArray()
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
        
        let allMessages = buildMessageArray()
        
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
        
        let allMessages = buildMessageArray()
        
        // Anthropic format is different - separate system from messages
        var bodyDict: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true
        ]
        
        // Add system prompt
        bodyDict["system"] = systemPrompt
        
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
            modelName: model
        )
    }
    
    // MARK: - Message Building Helper
    private struct SimpleMessage {
        let role: String
        let content: String
    }
    
    private func buildMessageArray() -> [SimpleMessage] {
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
            if let ctx = msg.terminalContext, !ctx.isEmpty {
                var header = "Terminal Context:"
                if let meta = msg.terminalContextMeta, let cwd = meta.cwd, !cwd.isEmpty {
                    header += "\nCurrent Working Directory - \(cwd)"
                }
                prefix = "\(header)\n```\n\(ctx)\n```\n\n"
            }
            return SimpleMessage(role: msg.role, content: prefix + msg.content)
        }
        
        // Context window management: estimate ~4 chars per token
        // Most models have 4K-128K token limits. We'll aim for ~100K chars max
        let maxContextChars = 100_000
        let systemPromptChars = systemPrompt.count
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
        
        var result = [SimpleMessage(role: "system", content: systemPrompt)]
        result += allConv
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
        modelName: String
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
            throw NSError(domain: "ChatAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errorBody)"])
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
        let finalInputTokens = inputTokens ?? TokenEstimator.estimateTokens(systemPrompt + messages.map { $0.content }.joined())
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
                    } else if self.model.isEmpty {
                        // Only auto-select if no model is set; preserve user's persisted model
                        self.model = names.first ?? self.model
                    }
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
                    } else if self.model.isEmpty {
                        // Only auto-select if no model is set; preserve user's persisted model
                        self.model = ids.first ?? self.model
                    }
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
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            try? PersistenceService.saveJSON(self.messages, to: self.messagesFileName)
        }
        persistDebounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceInterval, execute: item)
    }
    
    /// Force immediate persistence for critical events (session close, app quit)
    func persistMessagesImmediately() {
        persistDebounceItem?.cancel()
        persistDebounceItem = nil
        try? PersistenceService.saveJSON(messages, to: messagesFileName)
    }
    
    func loadMessages() {
        if let m = try? PersistenceService.loadJSON([ChatMessage].self, from: messagesFileName) {
            messages = m
        }
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
            customLocalContextSize: customLocalContextSize,
            currentContextTokens: currentContextTokens,
            contextLimitTokens: contextLimitTokens,
            lastSummarizationDate: lastSummarizationDate,
            summarizationCount: summarizationCount
        )
        try? PersistenceService.saveJSON(settings, to: "session-settings-\(id.uuidString).json")
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
