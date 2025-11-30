import Foundation
import SwiftUI

// MARK: - Chat Message Types

struct AgentEvent: Codable, Equatable {
    var kind: String // "status", "step", "summary"
    var title: String
    var details: String? = nil
    var command: String? = nil
    var output: String? = nil
    var collapsed: Bool? = true
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
        agentCancelled = true
        isAgentRunning = false
        
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
    
    private func runAgentOrchestration(for userPrompt: String) async {
        // Reset cancellation state and mark agent as running
        agentCancelled = false
        isAgentRunning = true
        defer { isAgentRunning = false }
        
        // Append user message first
        appendUserMessage(userPrompt)
        
        // Add an agent status message (collapsed) indicating decision in progress
        messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Agent deciding next action…", details: "Evaluating whether to run commands or reply directly.", command: nil, output: nil, collapsed: true)))
        messages = messages
        persistMessages()
        
        // Ask the model whether to run commands or reply
        let decisionPrompt = """
        You are operating in an agent mode inside a terminal-centric app. Given the user's request below, decide one of two actions: either respond directly (RESPOND) or run one or more shell commands (RUN). 
        Reply strictly in JSON on one line with keys: {"action":"RESPOND|RUN", "reason":"short sentence"}.
        User: \(userPrompt)
        """
        let decision = await callOneShotJSON(prompt: decisionPrompt)
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
        let goalPrompt = """
        Convert the user's request below into a concise actionable goal a shell-capable agent should accomplish.
        Reply as JSON: {"goal":"short goal phrase"}.
        User: \(userPrompt)
        """
        let goal = await callOneShotJSON(prompt: goalPrompt)
        messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Goal", details: goal.raw, command: nil, output: nil, collapsed: true)))
        messages = messages
        persistMessages()
        
        // Agent context maintained as a growing log we pass to the model
        agentContextLog = []
        agentContextLog.append("GOAL: \(goal.goal ?? "")")
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
        stepLoop: while iterations < maxIterations {
            // Check for cancellation
            if agentCancelled {
                AgentDebugConfig.log("[Agent] Cancelled by user")
                break stepLoop
            }
            
            iterations += 1
            // Ask next step
            let contextBlob = agentContextLog.joined(separator: "\n")
            let stepPrompt = """
            You are a terminal agent. Based on the GOAL and CONTEXT below, suggest the next step and a single shell command to run.
            Constraints:
            - Output strictly JSON on one line.
            - Do NOT include placeholders like <DIR> or <VENV_DIR>. Use explicit paths under the current project dir if appropriate (e.g., ./venv), or skip the command if user input would be required.
            - If you cannot safely determine values, return an empty command and explain in the step.
            Reply JSON: {"step":"what you will do", "command":"bash to run or empty string"}.
            ---
            ENVIRONMENT:
            - Current Working Directory: \(self.lastKnownCwd.isEmpty ? "(unknown)" : self.lastKnownCwd)
            - Shell: /bin/zsh
            GOAL: \(goal.goal ?? "")
            CONTEXT:\n\(contextBlob)
            """
            AgentDebugConfig.log("[Agent] Step prompt =>\n\(stepPrompt)")
            let step = await callOneShotJSON(prompt: stepPrompt)
            let commandToRun = step.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "step", title: step.step ?? "Next step", details: nil, command: commandToRun, output: nil, collapsed: true)))
            messages = messages
            persistMessages()
            
            guard !commandToRun.isEmpty else { break }
            
            // Execute command with optional approval flow
            let capturedOut: String?
            if AgentSettings.shared.requireCommandApproval && !AgentSettings.shared.shouldAutoApprove(commandToRun) {
                // Use approval flow
                capturedOut = await executeCommandWithApproval(commandToRun)
                
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
                if let out = capturedOut, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    agentContextLog.append("OUTPUT: \(out.prefix(AgentSettings.shared.maxOutputCapture))")
                }
            }
            
            AgentDebugConfig.log("[Agent] Command finished. cwd=\(self.lastKnownCwd), exit=\(lastExitCodeString())\nOutput (first 500 chars):\n\((capturedOut ?? "(no output)").prefix(500))")
            
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
                    if let out = fixOut, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        agentContextLog.append("OUTPUT: \(out.prefix(AgentSettings.shared.maxOutputCapture))")
                    }
                }
                // Immediately reassess after a fix attempt based on exit code and output
                let quickAssessPrompt = """
                Decide if the GOAL is now achieved after the fix attempt. Reply JSON: {"done":true|false, "reason":"short"}.
                GOAL: \(goal.goal ?? "")
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
            
            // Ask if goal achieved, with latest context
            let assessPrompt = """
            Given the GOAL and CONTEXT, decide if the goal is accomplished. Reply JSON: {"done":true|false, "reason":"short"}.
            GOAL: \(goal.goal ?? "")
            BASE CONTEXT:
            - Current Working Directory: \(self.lastKnownCwd.isEmpty ? "(unknown)" : self.lastKnownCwd)
            - Last Command: \(commandToRun)
            - Last Output: \((capturedOut ?? "").prefix(AgentSettings.shared.maxOutputCapture))
            - Last Exit Code: \(lastExitCodeString())
            CONTEXT:\n\(agentContextLog.joined(separator: "\n"))
            """
            AgentDebugConfig.log("[Agent] Assess prompt =>\n\(assessPrompt)")
            let assess = await callOneShotJSON(prompt: assessPrompt)
            AgentDebugConfig.log("[Agent] Assess result => \(assess.raw)")
            messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Assessment", details: assess.raw, command: nil, output: nil, collapsed: true)))
            messages = messages
            persistMessages()
            
            if assess.done == true {
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
                // Decide to continue or stop and summarize
                let contPrompt = """
                Decide whether to CONTINUE or STOP given diminishing returns. Reply JSON: {"decision":"CONTINUE|STOP", "reason":"short"}.
                GOAL: \(goal.goal ?? "")
                CONTEXT:\n\(agentContextLog.joined(separator: "\n"))
                """
                let cont = await callOneShotJSON(prompt: contPrompt)
                messages.append(ChatMessage(role: "assistant", content: "", agentEvent: AgentEvent(kind: "status", title: "Continue?", details: cont.raw, command: nil, output: nil, collapsed: true)))
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
        }
    }
    
    private struct JSONDecision: Decodable { let action: String?; let reason: String? }
    private struct JSONGoal: Decodable { let goal: String? }
    private struct JSONStep: Decodable { let step: String?; let command: String? }
    private struct JSONAssess: Decodable { let done: Bool?; let reason: String? }
    private struct JSONCont: Decodable { let decision: String?; let reason: String? }
    private struct JSONAnalyze: Decodable { let outcome: String?; let reason: String?; let next: String?; let fixed_command: String? }
    
    private struct RawJSON: Decodable { }
    
    private func callOneShotJSON(prompt: String) async -> (raw: String, action: String?, reason: String?, goal: String?, step: String?, command: String?, done: Bool?, decision: String?, outcome: String?, next: String?, fixed_command: String?) {
        let text = await callOneShotText(prompt: prompt)
        let compact = text.replacingOccurrences(of: "\n", with: " ")
        let data = compact.data(using: .utf8) ?? Data()
        var action: String? = nil, reason: String? = nil, goal: String? = nil, step: String? = nil, command: String? = nil, done: Bool? = nil, decision: String? = nil, outcome: String? = nil, next: String? = nil, fixed: String? = nil
        if let obj = try? JSONDecoder().decode(JSONDecision.self, from: data) { action = obj.action; reason = obj.reason }
        if let obj = try? JSONDecoder().decode(JSONGoal.self, from: data) { goal = obj.goal }
        if let obj = try? JSONDecoder().decode(JSONStep.self, from: data) { step = obj.step; command = obj.command }
        if let obj = try? JSONDecoder().decode(JSONAssess.self, from: data) { done = obj.done; reason = obj.reason ?? reason }
        if let obj = try? JSONDecoder().decode(JSONCont.self, from: data) { decision = obj.decision; reason = obj.reason ?? reason }
        if let obj = try? JSONDecoder().decode(JSONAnalyze.self, from: data) { outcome = obj.outcome; next = obj.next; fixed = obj.fixed_command ?? fixed }
        return (raw: compact, action: action, reason: reason, goal: goal, step: step, command: command, done: done, decision: decision, outcome: outcome, next: next, fixed_command: fixed)
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
            RequestBody.Message(role: "system", content: systemPrompt),
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
        var bodyDict: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "stream": false,
            "max_completion_tokens": 1024
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
        
        let bodyDict: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
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
            var resolved = false
            func finish(_ value: String?) {
                guard !resolved else { return }
                resolved = true
                if let t = token { NotificationCenter.default.removeObserver(t) }
                token = nil
                continuation.resume(returning: value)
            }
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
            var resolved = false
            
            func finish(_ value: String?) {
                guard !resolved else { return }
                resolved = true
                if let t = token { NotificationCenter.default.removeObserver(t) }
                token = nil
                continuation.resume(returning: value)
            }
            
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
        
        // Record in context log
        agentContextLog.append("RAN: \(approvedCommand)")
        if let out = output, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            agentContextLog.append("OUTPUT: \(out.prefix(AgentSettings.shared.maxOutputCapture))")
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
        
        var result = [SimpleMessage(role: "system", content: systemPrompt)]
        result += conversational.map { msg in
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
