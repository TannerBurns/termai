import Foundation
import SwiftUI

// MARK: - Chat Message Types

struct AgentEvent: Codable, Equatable {
    var kind: String // "status", "step", "summary", "checklist"
    var title: String
    var details: String? = nil
    var command: String? = nil
    var output: String? = nil
    var collapsed: Bool? = true
    var checklistItems: [TaskChecklistItem]? = nil
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
    @Published var messages: [ChatMessage] = []
    @Published var sessionTitle: String = ""
    @Published var streamingMessageId: UUID? = nil
    @Published var pendingTerminalContext: String? = nil
    @Published var pendingTerminalMeta: TerminalContextMeta? = nil
    @Published var agentModeEnabled: Bool = false
    @Published var agentContextLog: [String] = []
    @Published var lastKnownCwd: String = ""
    @Published var isAgentRunning: Bool = false
    @Published var agentCurrentStep: Int = 0
    @Published var agentEstimatedSteps: Int = 0
    @Published var agentPhase: String = ""
    @Published var agentChecklist: TaskChecklist? = nil
    
    // File coordination state
    @Published var isWaitingForFileLock: Bool = false
    @Published var waitingForFile: String? = nil
    
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
    
    // MARK: - Local Providers (kept for backward compatibility)
    enum LocalProvider: String {
        case ollama = "Ollama"
        case lmStudio = "LM Studio"
        case vllm = "vLLM"
        
        var defaultBaseURL: URL {
            switch self {
            case .ollama:
                return URL(string: "http://localhost:11434/v1")!
            case .lmStudio:
                return URL(string: "http://localhost:1234/v1")!
            case .vllm:
                return URL(string: "http://localhost:8000/v1")!
            }
        }
    }
    
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
        isAgentRunning = false
        agentPhase = "Cancelled"
        
        // Release any file locks held by this session
        FileLockManager.shared.releaseAllLocks(for: self.id)
        isWaitingForFileLock = false
        waitingForFile = nil
        
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
    
    private func runAgentOrchestration(for userPrompt: String) async {
        // Reset cancellation state and mark agent as running
        agentCancelled = false
        isAgentRunning = true
        agentCurrentStep = 0
        agentEstimatedSteps = 0
        agentPhase = "Starting"
        defer { 
            isAgentRunning = false 
            if agentPhase != "Cancelled" {
                agentPhase = ""
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
        
        // Ask the model whether to run commands or reply
        let decisionPrompt = """
        You are operating in an agent mode inside a terminal-centric app. Given the user's request below, decide one of two actions: either respond directly (RESPOND) or run one or more shell commands (RUN). 
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
        agentPhase = "Setting goal"
        let goalPrompt = """
        Convert the user's request below into a concise actionable goal a shell-capable agent should accomplish.
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
        
        // Agent context maintained as a growing log we pass to the model
        agentContextLog = []
        agentContextLog.append("GOAL: \(goal.goal ?? "")")
        
        // Planning phase (if enabled)
        var agentPlan: [String] = []
        var estimatedSteps: Int = 10
        agentChecklist = nil  // Reset checklist
        
        if AgentSettings.shared.enablePlanning {
            if checkCancelled(location: "before planning") { return }
            agentPhase = "Planning"
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
                agentEstimatedSteps = estimatedSteps
                
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
                agentContextLog.append("CHECKLIST:\n\(checklistDisplay)")
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
                    if let rc { self.agentContextLog.append("__TERMAI_RC__=\(rc)") }
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
        let reflectionInterval = AgentSettings.shared.reflectionInterval
        let stuckThreshold = AgentSettings.shared.stuckDetectionThreshold
        
        stepLoop: while maxIterations == 0 || iterations < maxIterations {
            // Check for cancellation at start of each iteration
            if agentCancelled {
                AgentDebugConfig.log("[Agent] Cancelled by user at iteration start")
                break stepLoop
            }
            
            iterations += 1
            agentCurrentStep = iterations
            agentPhase = "Step \(iterations)"
            
            // Periodic reflection (if enabled)
            if AgentSettings.shared.enableReflection && iterations > 1 && iterations % reflectionInterval == 0 {
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
            
            // Build context with summarization if needed
            var contextBlob = agentContextLog.joined(separator: "\n")
            if contextBlob.count > AgentSettings.shared.maxContextSize {
                // Summarize older context
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
            You are a terminal agent. Based on the GOAL and CONTEXT below, decide the next action.
            
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
            8. "command" - Run a simple shell command (ls, mkdir, cd, git, npm, etc.)
            9. "run_background" - Start server/process in background. Args: command, wait_for (text to detect startup), timeout
            10. "check_process" - Check process status. Args: pid, port, or list=true
            11. "stop_process" - Stop a background process. Args: pid, or all=true
            
            VERIFICATION:
            12. "http_request" - Test API endpoints. Args: url, method (GET/POST/PUT/DELETE), body, headers
            13. "search_output" - Search previous command outputs. Args: pattern
            
            RULES:
            - For creating NEW files, use write_file tool
            - For EDITING existing files, use edit_file (search/replace) or insert_lines/delete_lines
            - For reading files, use read_file tool instead of cat
            - Use shell commands for: mkdir, ls, cd, git, grep, find, npm, node, etc.
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
            - Shell: /bin/zsh
            
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
            if let itemId = workingOnChecklistItem, agentChecklist != nil {
                agentChecklist!.markInProgress(itemId)
                updateChecklistMessage()
            }
            
            // Check if this is a tool call rather than a shell command
            if toolToUse != "command" && !toolToUse.isEmpty {
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
                    if isFileOp, let path = toolArgs["path"] {
                        // Check if we'll need to wait for this file
                        if let lockHolder = FileLockManager.shared.lockHolder(for: path), lockHolder != self.id {
                            self.isWaitingForFileLock = true
                            self.waitingForFile = path
                            messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "⏳ Waiting for file access", details: "Another session is editing: \(URL(fileURLWithPath: path).lastPathComponent)", command: nil, output: nil, collapsed: false)))
                            messages = messages
                            persistMessages()
                        }
                    }
                    
                    let result = await tool.execute(args: argsWithSession, cwd: self.lastKnownCwd.isEmpty ? nil : self.lastKnownCwd)
                    
                    // Clear waiting state
                    self.isWaitingForFileLock = false
                    self.waitingForFile = nil
                    
                    if checkCancelled(location: "after tool execution") { break stepLoop }
                    
                    let resultOutput = result.success ? result.output : "ERROR: \(result.error ?? "Unknown error")"
                    
                    agentContextLog.append("TOOL: \(toolToUse) \(toolArgs)")
                    agentContextLog.append("RESULT: \(resultOutput.prefix(AgentSettings.shared.maxOutputCapture))")
                    
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: result.success ? "Tool succeeded" : "Tool failed", details: String(resultOutput.prefix(500)), command: nil, output: resultOutput, collapsed: true)))
                    messages = messages
                    persistMessages()
                    
                    // Update checklist item status
                    if let itemId = workingOnChecklistItem, agentChecklist != nil {
                        if result.success {
                            agentChecklist!.markCompleted(itemId, note: "Done")
                        } else {
                            agentChecklist!.markFailed(itemId, note: result.error?.prefix(50).description)
                        }
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
                            let summaryPrompt = """
                            Summarize concisely what was done to achieve the goal and the result. Reply markdown.
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
                } else {
                    agentContextLog.append("TOOL: \(toolToUse) - not found")
                    messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Unknown tool: \(toolToUse)", details: "Available tools: \(AgentToolRegistry.shared.allTools().map { $0.name }.joined(separator: ", "))", command: nil, output: nil, collapsed: true)))
                    messages = messages
                    persistMessages()
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
            
            // Reset empty response counter on successful action
            emptyResponseCount = 0
            
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
            
            // Advance plan step if command succeeded
            if lastExitCodeString() == "0" && !agentPlan.isEmpty && currentPlanStep < agentPlan.count {
                currentPlanStep += 1
            }
            
            // Analyze command outcome; propose fixes if failed
            let analyzePrompt = """
            Analyze the following command execution and decide outcome and next action.
            Reply strictly as JSON on one line with keys:
            {"outcome":"success|fail|uncertain", "reason":"short", "next":"continue|stop|fix", "fixed_command":"optional replacement if next=fix else empty"}
            GOAL: \(goal.goal ?? "")
            COMMAND: \(commandToRun)
            OUTPUT:\n\(capturedOut ?? "(no output)")
            CWD: \(self.lastKnownCwd.isEmpty ? "(unknown)" : self.lastKnownCwd)
            EXIT_CODE: \(lastExitCodeString())
            """
            AgentDebugConfig.log("[Agent] Analyze prompt =>\n\(analyzePrompt)")
            let analysis = await callOneShotJSON(prompt: analyzePrompt)
            if checkCancelled(location: "after analysis") { break stepLoop }
            AgentDebugConfig.log("[Agent] Analysis: \(analysis.raw)")
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
                Reply JSON: {"done":true|false, "reason":"short"}.
                GOAL: \(goal.goal ?? "")
                CHECKLIST (\(postFixCompletedCount)/\(postFixTotalCount) completed):
                \(postFixChecklistStatus)
                BASE CONTEXT:
                - Current Working Directory: \(self.lastKnownCwd.isEmpty ? "(unknown)" : self.lastKnownCwd)
                - Last Command: \(fixed)
                - Last Output: \((fixOut ?? "").prefix(AgentSettings.shared.maxOutputCapture))
                - Last Exit Code: \(lastExitCodeString())
                CONTEXT:\n\(agentContextLog.joined(separator: "\n"))
                """
                AgentDebugConfig.log("[Agent] Post-fix assess prompt =>\n\(quickAssessPrompt)")
                let quickAssess = await callOneShotJSON(prompt: quickAssessPrompt)
                AgentDebugConfig.log("[Agent] Post-fix assess: \(quickAssess.raw)")
                messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Post-fix assessment", details: quickAssess.raw, command: nil, output: nil, collapsed: true)))
                messages = messages
                persistMessages()
                if quickAssess.done == true {
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
            Reply JSON: {"done":true|false, "reason":"short"}.
            GOAL: \(goal.goal ?? "")
            CHECKLIST (\(completedCount)/\(totalCount) completed):
            \(checklistStatus)
            BASE CONTEXT:
            - Current Working Directory: \(self.lastKnownCwd.isEmpty ? "(unknown)" : self.lastKnownCwd)
            - Last Command: \(commandToRun)
            - Last Output: \((capturedOut ?? "").prefix(AgentSettings.shared.maxOutputCapture))
            - Last Exit Code: \(lastExitCodeString())
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
                    agentPhase = "Verifying"
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
                let summaryPrompt = """
                Summarize concisely what was done to achieve the goal and the result. Reply markdown.
                GOAL: \(goal.goal ?? "")
                CONTEXT:\n\(agentContextLog.joined(separator: "\n"))
                """
                let summaryText = await callOneShotText(prompt: summaryPrompt)
                messages.append(ChatMessage(role: "assistant", content: summaryText))
                messages = messages
                persistMessages()
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
    
    private struct JSONDecision: Decodable { let action: String?; let reason: String? }
    private struct JSONGoal: Decodable { let goal: String? }
    private struct JSONPlan: Decodable { let plan: [String]?; let estimated_commands: Int? }
    
    // Custom wrapper to handle tool_args that may contain mixed types (strings, ints, bools)
    private struct JSONStep: Decodable {
        let step: String?
        let command: String?
        let tool: String?
        let tool_args: [String: String]?
        let checklist_item: Int?
        
        private enum CodingKeys: String, CodingKey {
            case step, command, tool, tool_args, checklist_item
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            step = try container.decodeIfPresent(String.self, forKey: .step)
            command = try container.decodeIfPresent(String.self, forKey: .command)
            tool = try container.decodeIfPresent(String.self, forKey: .tool)
            checklist_item = try container.decodeIfPresent(Int.self, forKey: .checklist_item)
            
            // Try to decode tool_args, converting any non-string values to strings
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
    
    private struct JSONAssess: Decodable { let done: Bool?; let reason: String? }
    private struct JSONCont: Decodable { let decision: String?; let reason: String? }
    private struct JSONAnalyze: Decodable { let outcome: String?; let reason: String?; let next: String?; let fixed_command: String? }
    private struct JSONReflection: Decodable { let progress_percent: Int?; let on_track: Bool?; let completed: [String]?; let remaining: [String]?; let should_adjust: Bool?; let new_approach: String? }
    private struct JSONStuckRecovery: Decodable { let is_stuck: Bool?; let new_approach: String?; let should_stop: Bool? }
    
    private struct RawJSON: Decodable { }
    
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
        
        if let obj = try? JSONDecoder().decode(JSONDecision.self, from: data) { 
            response.action = obj.action
            response.reason = obj.reason 
        }
        if let obj = try? JSONDecoder().decode(JSONGoal.self, from: data) { 
            response.goal = obj.goal 
        }
        if let obj = try? JSONDecoder().decode(JSONPlan.self, from: data) { 
            response.plan = obj.plan
            response.estimatedCommands = obj.estimated_commands
        }
        if let obj = try? JSONDecoder().decode(JSONStep.self, from: data) { 
            response.step = obj.step
            response.command = obj.command
            response.tool = obj.tool
            response.toolArgs = obj.tool_args
            response.checklistItem = obj.checklist_item
        }
        if let obj = try? JSONDecoder().decode(JSONAssess.self, from: data) { 
            response.done = obj.done
            response.reason = obj.reason ?? response.reason 
        }
        if let obj = try? JSONDecoder().decode(JSONCont.self, from: data) { 
            response.decision = obj.decision
            response.reason = obj.reason ?? response.reason 
        }
        if let obj = try? JSONDecoder().decode(JSONAnalyze.self, from: data) { 
            response.outcome = obj.outcome
            response.next = obj.next
            response.fixed_command = obj.fixed_command 
        }
        if let obj = try? JSONDecoder().decode(JSONReflection.self, from: data) {
            response.progressPercent = obj.progress_percent
            response.onTrack = obj.on_track
            response.completed = obj.completed
            response.remaining = obj.remaining
            response.shouldAdjust = obj.should_adjust
            response.newApproach = obj.new_approach
        }
        if let obj = try? JSONDecoder().decode(JSONStuckRecovery.self, from: data) {
            response.isStuck = obj.is_stuck
            response.newApproach = obj.new_approach ?? response.newApproach
            response.shouldStop = obj.should_stop
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
        // Route to appropriate provider
        if case .cloud(let cloudProvider) = providerType {
            switch cloudProvider {
            case .openai:
                return await callOneShotOpenAI(prompt: prompt)
            case .anthropic:
                return await callOneShotAnthropic(prompt: prompt)
            }
        } else {
            return await callOneShotLocal(prompt: prompt)
        }
    }
    
    private func callOneShotLocal(prompt: String) async -> String {
        struct RequestBody: Encodable {
            struct Message: Codable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let stream: Bool
            let temperature: Double
        }
        let url = apiBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let messages = [
            RequestBody.Message(role: "system", content: agentSystemPrompt),
            RequestBody.Message(role: "user", content: prompt)
        ]
        let req = RequestBody(model: model, messages: messages, stream: false, temperature: 0.2)
        do {
            request.httpBody = try JSONEncoder().encode(req)
            let (data, _) = try await URLSession.shared.data(for: request)
            // Try OpenAI-like
            struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
            struct Resp: Decodable { let choices: [Choice] }
            if let decoded = try? JSONDecoder().decode(Resp.self, from: data), let content = decoded.choices.first?.message.content { return content }
            // Try Ollama-like
            struct OR: Decodable { struct Message: Decodable { let content: String? }; let message: Message?; let response: String? }
            if let o = try? JSONDecoder().decode(OR.self, from: data) { return o.message?.content ?? o.response ?? String(data: data, encoding: .utf8) ?? "" }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "{\"error\":\"\(error.localizedDescription)\"}"
        }
    }
    
    private func callOneShotOpenAI(prompt: String) async -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .openai) else {
            return "{\"error\":\"OpenAI API key not found\"}"
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Build request body as dictionary for flexibility
        // Don't limit max_tokens in agent mode - let it generate what it needs
        var bodyDict: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": agentSystemPrompt],
                ["role": "user", "content": prompt]
            ],
            "stream": false
        ]
        
        // For reasoning models, use temperature 1.0; otherwise use agent temperature
        if currentModelSupportsReasoning {
            bodyDict["temperature"] = 1.0
        } else {
            bodyDict["temperature"] = 0.2
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
            let (data, _) = try await URLSession.shared.data(for: request)
            struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
            struct Resp: Decodable { let choices: [Choice] }
            if let decoded = try? JSONDecoder().decode(Resp.self, from: data), let content = decoded.choices.first?.message.content {
                return content
            }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "{\"error\":\"\(error.localizedDescription)\"}"
        }
    }
    
    private func callOneShotAnthropic(prompt: String) async -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        guard let apiKey = CloudAPIKeyManager.shared.getAPIKey(for: .anthropic) else {
            return "{\"error\":\"Anthropic API key not found\"}"
        }
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        // Anthropic requires max_tokens - Claude Sonnet 4 supports up to 64k output tokens
        let bodyDict: [String: Any] = [
            "model": model,
            "max_tokens": 64000,
            "system": agentSystemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
            let (data, _) = try await URLSession.shared.data(for: request)
            
            // Anthropic response format
            struct ContentBlock: Decodable { let type: String; let text: String? }
            struct AnthropicResponse: Decodable { let content: [ContentBlock] }
            
            if let decoded = try? JSONDecoder().decode(AnthropicResponse.self, from: data),
               let textBlock = decoded.content.first(where: { $0.type == "text" }),
               let text = textBlock.text {
                return text
            }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "{\"error\":\"\(error.localizedDescription)\"}"
        }
    }
    
    /// Summarize context when it exceeds size limits
    private func summarizeContext(_ contextLog: [String], maxSize: Int) async -> String {
        let fullContext = contextLog.joined(separator: "\n")
        
        // If already under limit, return as-is
        if fullContext.count <= maxSize {
            return fullContext
        }
        
        // Keep most recent entries intact
        let recentCount = min(contextLog.count, 10)
        let recentEntries = contextLog.suffix(recentCount)
        let olderEntries = contextLog.dropLast(recentCount)
        
        if olderEntries.isEmpty {
            // All entries are recent, just truncate
            return String(fullContext.suffix(maxSize))
        }
        
        // Summarize older entries
        let summarizePrompt = """
        Summarize the following agent execution context, preserving:
        - Key commands that were run and their outcomes
        - Important errors or warnings
        - Significant progress milestones
        - Current state information
        Be concise but preserve critical information.
        
        CONTEXT TO SUMMARIZE:
        \(olderEntries.joined(separator: "\n").prefix(maxSize / 2))
        """
        
        let summary = await callOneShotText(prompt: summarizePrompt)
        let summarized = "[SUMMARIZED HISTORY]\n\(summary)\n\n[RECENT ACTIVITY]\n\(recentEntries.joined(separator: "\n"))"
        
        return String(summarized.suffix(maxSize))
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
        // As a simple fallback, look for the last "OUTPUT: __TERMAI_RC__=N" line we injected into agentContextLog.
        if let line = agentContextLog.last(where: { $0.contains("__TERMAI_RC__=") }) {
            if let idx = line.lastIndex(of: "=") {
                let num = line[line.index(after: idx)...]
                return String(num)
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
        
        return output
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
                
                // Response format structs
                struct OpenAIChoice: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message
                }
                struct OpenAIResponse: Decodable { let choices: [OpenAIChoice] }
                
                struct OllamaResponse: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message?
                    let response: String?
                }
                
                // Anthropic response format
                struct AnthropicContentBlock: Decodable { let type: String; let text: String? }
                struct AnthropicResponse: Decodable { let content: [AnthropicContentBlock] }
                
                var generatedTitle: String? = nil
                
                // Parse based on provider
                if case .cloud(let cloudProvider) = self.providerType, cloudProvider == .anthropic {
                    // Anthropic format
                    if let decoded = try? JSONDecoder().decode(AnthropicResponse.self, from: data),
                       let textBlock = decoded.content.first(where: { $0.type == "text" }),
                       let text = textBlock.text {
                        generatedTitle = text
                    }
                } else {
                    // Try OpenAI format first
                    do {
                        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
                        if let title = decoded.choices.first?.message.content {
                            generatedTitle = title
                        }
                    } catch {
                        // Try Ollama format
                        do {
                            let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
                            generatedTitle = decoded.message?.content ?? decoded.response
                        } catch {
                            // Failed to decode both formats
                        }
                    }
                }
                
                if let title = generatedTitle {
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
        
        return try await streamSSEResponse(request: request, assistantIndex: assistantIndex)
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
            "stream": true
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
        
        return try await streamSSEResponse(request: request, assistantIndex: assistantIndex)
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
        
        return try await streamAnthropicResponse(request: request, assistantIndex: assistantIndex)
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
    private func streamSSEResponse(request: URLRequest, assistantIndex: Int) async throws -> String {
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
        
        return accumulated
    }
    
    // MARK: - Anthropic Response Streaming
    private func streamAnthropicResponse(request: URLRequest, assistantIndex: Int) async throws -> String {
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
        
        return accumulated
    }
    
    // MARK: - Models
    func fetchAvailableModels() async {
        await MainActor.run {
            self.modelFetchError = nil
            self.availableModels = []
        }
        
        // Handle cloud providers - use curated model list
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
        
        // Handle local providers
        switch LocalProvider(rawValue: providerName) {
        case .ollama:
            await fetchOllamaModelsInternal()
        case .lmStudio, .vllm:
            await fetchOpenAIStyleModels()
        default:
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
                await MainActor.run {
                    self.availableModels = names
                    if names.isEmpty {
                        self.modelFetchError = "No models found on Ollama"
                    } else if self.model.isEmpty {
                        // Only auto-select if no model is set; preserve user's persisted model
                        self.model = names.first ?? self.model
                    }
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
                await MainActor.run {
                    self.availableModels = ids
                    if ids.isEmpty {
                        self.modelFetchError = "No models available"
                    } else if self.model.isEmpty {
                        // Only auto-select if no model is set; preserve user's persisted model
                        self.model = ids.first ?? self.model
                    }
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
    
    func persistMessages() {
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
            providerType: providerType
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
        apiBaseURL = provider.defaultBaseURL
        apiKey = nil
        model = "" // Reset model selection
        persistSettings()
        Task { await fetchAvailableModels() }
    }
}

// MARK: - Supporting Types
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
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
    }
    let choices: [Choice]
}

private struct OllamaStreamChunk: Decodable {
    struct Message: Decodable { let content: String? }
    let message: Message?
    let response: String?
}
