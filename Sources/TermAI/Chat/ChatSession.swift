import Foundation
import SwiftUI
import TermAIModels

// Types are now in ChatMessageTypes.swift:
// - TokenEstimator
// - AgentEvent
// - TaskStatus, TaskChecklistItem, TaskChecklist
// - PinnedContextType, LineRange, PinnedContext
// - ChatMessage

// MARK: - Chat Session

/// A completely self-contained chat session with its own state, messages, and streaming
@MainActor
final class ChatSession: ObservableObject, Identifiable, ShellCommandExecutor, PlanTrackDelegate, CreatePlanDelegate {
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
    @Published var agentMode: AgentMode = .scout
    @Published var agentProfile: AgentProfile = .general
    
    /// The ID of the current plan being implemented (Navigator mode integration)
    @Published var currentPlanId: UUID? = nil
    
    /// The currently active profile (for Auto mode, this tracks the dynamically selected profile)
    /// When agentProfile is not .auto, this always equals agentProfile
    @Published var activeProfile: AgentProfile = .general {
        didSet {
            // Only log transitions when actually changing in auto mode
            if agentProfile.isAuto && oldValue != activeProfile {
                AgentDebugConfig.log("[Agent] Auto mode switched profile: \(oldValue.rawValue) → \(activeProfile.rawValue)")
            }
        }
    }
    
    /// The profile to use for prompts (activeProfile in Auto mode, agentProfile otherwise)
    var effectiveProfile: AgentProfile {
        agentProfile.isAuto ? activeProfile : agentProfile
    }
    
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
    var agentCancelled: Bool = false
    
    // MARK: - Checkpoint System
    
    /// All checkpoints in this session, ordered by message index
    @Published var checkpoints: [Checkpoint] = []
    
    /// The current checkpoint being built (while agent is processing a user message)
    /// File changes are recorded to this checkpoint until the next user message
    /// The current checkpoint being built (while agent is processing a user message)
    /// File changes are recorded to this checkpoint until the next user message
    var currentCheckpoint: Checkpoint?
    
    /// Filename for checkpoint persistence
    var checkpointsFileName: String { "chat-checkpoints-\(id.uuidString).json" }
    
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
    
    /// Effective output capture limit based on model's context window
    /// Dynamically scales with model capability while respecting min/max bounds
    var effectiveOutputCaptureLimit: Int {
        AgentSettings.shared.effectiveOutputCaptureLimit(forContextTokens: effectiveContextLimit)
    }
    
    /// Effective agent memory limit based on model's context window
    /// Dynamically scales with model capability while respecting min/max bounds
    var effectiveAgentMemoryLimit: Int {
        AgentSettings.shared.effectiveAgentMemoryLimit(forContextTokens: effectiveContextLimit)
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
    func getSystemPromptAsync() async -> String {
        let info = await SystemInfo.cachedAsync
        return info.injectIntoPrompt()
    }
    
    /// Async version with agent mode - use this for LLM calls
    /// Uses simplified prompt for native tool calling (tools sent via API)
    /// Includes profile-specific guidance based on the current agentProfile
    private func getAgentSystemPromptAsync() async -> String {
        let info = await SystemInfo.cachedAsync
        let basePrompt = info.injectIntoPromptWithNativeToolCalling()
        let profileAddition = effectiveProfile.systemPromptAddition(for: agentMode)
        
        // For Navigator mode, inject plan state context
        var planStateContext = ""
        if agentMode == .navigator {
            if currentPlanId != nil {
                // A plan already exists - emphasize build mode switching
                planStateContext = """
                
                ⚠️ PLAN ALREADY EXISTS - If user wants to build/implement:
                → For "pilot", "yes", "go ahead", "build", "start" → Reply: <BUILD_MODE>pilot</BUILD_MODE>
                → For "copilot" specifically → Reply: <BUILD_MODE>copilot</BUILD_MODE>
                DO NOT create another plan. Just output the BUILD_MODE tag.
                
                """
            }
        }
        
        return basePrompt + profileAddition + planStateContext
    }
    
    // Private streaming state
    var streamingTask: Task<Void, Never>? = nil
    
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
        
        // Apply default agent mode and profile settings for new sessions (not restored ones)
        if restoredId == nil {
            self.agentMode = AgentSettings.shared.defaultAgentMode
            self.agentProfile = AgentSettings.shared.defaultAgentProfile
            // Initialize activeProfile to match (will be updated dynamically in Auto mode)
            self.activeProfile = AgentSettings.shared.defaultAgentProfile.isAuto ? .general : AgentSettings.shared.defaultAgentProfile
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
    
    // Attached Context Management is in ChatSession+AttachedContext.swift
    
    // Checkpoint Management is in ChatSession+Checkpoint.swift
    
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
        // All agent modes (Scout, Copilot, Pilot) use tool-enabled orchestration
        // Tools are filtered based on the mode by the orchestration
        await runAgentOrchestration(for: text)
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
    func updateChecklistMessage() {
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
            
            messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Verifying: \(check.description)", details: "Tool: \(check.tool)", command: nil, output: nil, collapsed: true, isInternal: true)))
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
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "❌ Check failed: \(check.description)", details: result.error ?? result.output, command: nil, output: nil, collapsed: true, isInternal: true)))
                } else {
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "✓ Check passed: \(check.description)", details: String(result.output.prefix(300)), command: nil, output: nil, collapsed: true, isInternal: true)))
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
        AgentToolRegistry.shared.setCreatePlanDelegate(self)
        defer {
            // Clean up delegate references
            AgentToolRegistry.shared.setShellExecutor(nil)
            AgentToolRegistry.shared.setPlanTrackDelegate(nil)
            AgentToolRegistry.shared.setCreatePlanDelegate(nil)
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
        
        // Capture starting directory for directory hygiene
        // The agent should return here when done to preserve user's terminal state
        let startingCwd = lastKnownCwd.isEmpty ? FileManager.default.currentDirectoryPath : lastKnownCwd
        agentContextLog.append("STARTING_CWD: \(startingCwd)")
        
        // Reset token tracking for this new agent run
        agentSessionTokensUsed = 0
        accumulatedContextTokens = 0
        currentContextTokens = 0
        
        // Only reset checklist if not already set (e.g., by Navigator mode plan extraction)
        // Agent will create one via plan_and_track tool if needed and none exists
        if agentChecklist == nil {
            // No checklist set - agent can create one if needed
            AgentDebugConfig.log("[Agent] No pre-set checklist, agent may create one")
        } else {
            AgentDebugConfig.log("[Agent] Using pre-set checklist with \(agentChecklist!.items.count) items")
        }
        
        // Store user prompt for use in reflection/stuck detection
        let userRequest = userPrompt
        
        // Reset activeProfile for Auto mode and do initial profile analysis
        if agentProfile.isAuto {
            activeProfile = .general
            
            // Analyze the user's request to determine the best profile to start with
            if let analysis = await analyzeProfileForTask(
                currentTask: userRequest,
                nextItems: [],
                recentContext: ""
            ) {
                if analysis.confidence != "low" {
                    switchProfileIfNeeded(to: analysis.profile, reason: analysis.reason)
                    AgentDebugConfig.log("[Agent] Initial profile analysis: \(analysis.profile) (\(analysis.confidence) confidence) - \(analysis.reason)")
                }
            }
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
                        // Use smart truncation with dynamic limits based on model context
                        let truncatedOutput = SmartTruncator.smartTruncate(
                            out,
                            maxChars: self.effectiveOutputCaptureLimit,
                            context: .commandOutput
                        )
                        self.agentContextLog.append("OUTPUT(\(cmd.prefix(64))): \(truncatedOutput)")
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
                        collapsed: true,
                        isInternal: true
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
                
                // Get profile-specific reflection questions (use effectiveProfile for Auto mode)
                let profileReflectionQuestions = effectiveProfile.reflectionPrompt(for: agentMode)
                
                let reflectionPrompt = """
                Reflect on progress toward the goal. Assess what has been accomplished and what remains.
                
                \(profileReflectionQuestions)
                
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
                messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Progress Check (\(progressStr))", details: "\(onTrackStr)\n\(reflection.raw)", command: nil, output: nil, collapsed: true, isInternal: true)))
                messages = messages
                persistMessages()
                
                // If reflection suggests adjustment, note it in context
                if reflection.shouldAdjust == true, let newApproach = reflection.newApproach, !newApproach.isEmpty {
                    agentContextLog.append("STRATEGY ADJUSTMENT: \(newApproach)")
                }
                
                // Auto profile: Analyze if we should switch profiles during reflection
                if agentProfile.isAuto {
                    // Get remaining items from checklist for context
                    let remainingItems = agentChecklist?.items
                        .filter { $0.status == .pending || $0.status == .inProgress }
                        .map { $0.description } ?? []
                    
                    // Analyze what profile fits the current work
                    if let analysis = await analyzeProfileForTask(
                        currentTask: remainingItems.first ?? goalForReflection,
                        nextItems: Array(remainingItems.dropFirst()),
                        recentContext: agentContextLog.suffix(10).joined(separator: "\n")
                    ) {
                        // Only switch on medium or high confidence
                        if analysis.confidence != "low" {
                            switchProfileIfNeeded(to: analysis.profile, reason: analysis.reason)
                        }
                    }
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
                        messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Agent stopped - unable to make progress", details: stuckResult.raw, command: nil, output: nil, collapsed: true, isInternal: true)))
                        messages = messages
                        persistMessages()
                        break stepLoop
                    }
                    
                    if stuckResult.isStuck == true, let newApproach = stuckResult.newApproach, !newApproach.isEmpty {
                        messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Trying different approach", details: newApproach, command: nil, output: nil, collapsed: true, isInternal: true)))
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
                // Use dynamic agent memory limit based on model context size
                contextBlob = await summarizeContext(agentContextLog, maxSize: effectiveAgentMemoryLimit)
            }
            
            // Build checklist context for the step prompt (checklist is set via plan_and_track tool)
            // Also auto-mark first pending task as in-progress if none are currently in-progress
            let checklistContext: String
            if var checklist = agentChecklist {
                // Auto-mark first pending task as in-progress
                let startedNewTask: TaskChecklistItem?
                if checklist.items.first(where: { $0.status == .inProgress }) == nil,
                   let firstPending = checklist.items.first(where: { $0.status == .pending }) {
                    checklist.markInProgress(firstPending.id)
                    agentChecklist = checklist
                    updateChecklistMessage()
                    agentContextLog.append("TASK STARTED: #\(firstPending.id) - \(firstPending.description)")
                    startedNewTask = firstPending
                } else {
                    startedNewTask = nil
                }
                
                // Build context with current task highlighted
                var context = checklist.displayString
                if let current = checklist.currentItem {
                    context += "\n\nCURRENT TASK: #\(current.id) - \(current.description)"
                }
                checklistContext = context
                
                // Auto profile: Analyze if we should switch profiles when starting a new task
                if agentProfile.isAuto, let newTask = startedNewTask {
                    let remainingItems = checklist.items
                        .filter { $0.status == .pending && $0.id != newTask.id }
                        .map { $0.description }
                    
                    if let analysis = await analyzeProfileForTask(
                        currentTask: newTask.description,
                        nextItems: remainingItems,
                        recentContext: agentContextLog.suffix(5).joined(separator: "\n")
                    ) {
                        // Switch on medium or high confidence
                        if analysis.confidence != "low" {
                            switchProfileIfNeeded(to: analysis.profile, reason: analysis.reason)
                        }
                    }
                }
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
                    // Check for Navigator mode BUILD_MODE trigger
                    if agentMode == .navigator, let buildMode = extractBuildMode(from: response) {
                        // Clean the response (remove the BUILD_MODE tag)
                        let cleanedResponse = response.replacingOccurrences(
                            of: "<BUILD_MODE>\\w+</BUILD_MODE>",
                            with: "",
                            options: .regularExpression
                        ).trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // Update the existing streamed message with cleaned content (without BUILD_MODE tags)
                        if !cleanedResponse.isEmpty {
                            if let lastIdx = messages.lastIndex(where: { $0.role == "assistant" && $0.agentEvent == nil }) {
                                messages[lastIdx].content = cleanedResponse
                            messages = messages
                            persistMessages()
                            }
                        }
                        
                        // Switch to the requested mode and start building
                        await startBuildingPlan(with: buildMode)
                        transitionToPhase(.completed)
                        break stepLoop
                    }
                    
                    // Model provided a text response (completion or answer)
                    // Note: The streaming code has already added/updated the assistant message,
                    // so we don't need to append it again here
                    transitionToPhase(.summarizing)
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
    
    // JSON Parsing, Profile Analysis are in ChatSession+JSONParsing.swift
    
    func callOneShotText(prompt: String) async -> String {
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
    
    // Native Tool Calling is in ChatSession+NativeToolCalling.swift
    
    // Quick Environment Context & helpers are in ChatSession+ContextHelpers.swift
    
    // Command execution methods are in ChatSession+CommandExecution.swift
    
    // Plan Management is in ChatSession+PlanManagement.swift
    
    // File Approval is in ChatSession+FileApproval.swift
    
    // Title Generation is in ChatSession+TitleGeneration.swift
    
    // Streaming methods are in ChatSession+Streaming.swift
    
    // MARK: - Message Building Helper
    struct SimpleMessage {
        let role: String
        let content: String
    }
    
    /// Build message array for LLM calls. Pass the system prompt explicitly to ensure
    /// async callers can await full system info before building messages.
    func buildMessageArray(withSystemPrompt sysPrompt: String) -> [SimpleMessage] {
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
                var header = "=== TERMINAL OUTPUT (from user's terminal session) ==="
                if let meta = msg.terminalContextMeta, let cwd = meta.cwd, !cwd.isEmpty {
                    header += "\nWorking Directory: \(cwd)"
                }
                header += "\nThe user has shared the following terminal output for you to analyze:"
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
    func buildMessageArray() -> [SimpleMessage] {
        return buildMessageArray(withSystemPrompt: systemPrompt)
    }
    
    /// Format an attached context (file, terminal, etc.) for inclusion in the prompt
    func formatAttachedContext(_ context: PinnedContext) -> String {
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
            // Format terminal context - make it clear this is actual terminal output
            var header = "=== ATTACHED TERMINAL OUTPUT (from user's terminal session) ==="
            if !context.path.isEmpty && context.path != "terminal" {
                header += "\nWorking Directory: \(context.path)"
            }
            header += "\nThe user has shared this terminal output for you to analyze:"
            result = "\(header)\n```\n\(context.content)\n```\n\n"
            
        case .snippet:
            // Format code snippet - use displayName if it indicates a plan
            let header: String
            if context.displayName.contains("Plan") || context.path.hasPrefix("plan://") {
                header = "📋 \(context.displayName)\n\n--- IMPLEMENTATION PLAN START ---"
                result = "\(header)\n\(context.content)\n--- IMPLEMENTATION PLAN END ---\n\n"
            } else {
                header = "Attached Code Snippet:"
                result = "\(header)\n```\(context.language ?? "")\n\(context.content)\n```\n\n"
            }
        }
        
        return result
    }
    
    // SSE/Anthropic/Google Response Streaming methods are in ChatSession+Streaming.swift
    
    // Model cache and fetching methods are in ChatSession+ModelManagement.swift
    
    // Persistence methods are in ChatSession+Persistence.swift
    var messagesFileName: String { "chat-session-\(id.uuidString).json" }
    
    /// Debounce work item for batching message persistence
    var persistDebounceItem: DispatchWorkItem?
    let persistDebounceInterval: TimeInterval = 0.5  // 500ms debounce
}

// MARK: - Supporting Types (for LLM streaming)

/// Cache for fetched model lists
struct ModelCache: Codable {
    let models: [String]
    let timestamp: Date
}

struct OpenAIStreamChunk: Decodable {
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

struct OllamaStreamChunk: Decodable {
    struct Message: Decodable { let content: String? }
    let message: Message?
    let response: String?
}

// MARK: - Anthropic Usage Types
struct AnthropicMessageStart: Decodable {
    struct Message: Decodable {
        struct Usage: Decodable {
            let input_tokens: Int
        }
        let usage: Usage?
    }
    let message: Message?
}

struct AnthropicMessageDelta: Decodable {
    struct Usage: Decodable {
        let output_tokens: Int
    }
    let usage: Usage?
}