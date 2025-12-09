import Foundation
import os.log

private let researchLogger = Logger(subsystem: "com.termai.app", category: "SuggestionResearch")

/// Handles the AI-driven research phase of the suggestion pipeline
/// Uses tools to explore the user's environment and gather context
class SuggestionResearchPhase {
    
    // MARK: - Configuration
    
    /// Maximum number of research steps before stopping
    static let maxResearchSteps = 20
    
    /// Available tools for research phase (subset of agent tools)
    static let researchToolNames = ["read_file", "list_dir", "search_files", "shell"]
    
    /// Number of commands before triggering periodic research
    static let researchCommandThreshold = 5
    
    // MARK: - State Tracking
    
    /// Directory where research was last performed
    private var lastResearchCWD: String? = nil
    
    /// Counter for commands run since last research phase
    private var commandsSinceLastResearch: Int = 0
    
    /// Timestamp of last research phase
    private var lastResearchTimestamp: Date? = nil
    
    /// Callback to update phase status
    var onPhaseUpdate: ((SuggestionPhase) -> Void)?
    
    // MARK: - Public API
    
    /// Determine if research phase should run based on context
    func shouldRunResearch(
        isStartup: Bool,
        terminalContext: TerminalContext,
        gathered: GatheredContext,
        envContext: EnvironmentContext
    ) -> Bool {
        // Always research on startup
        if isStartup {
            researchLogger.info("Research decision: YES (startup)")
            return true
        }
        
        // Research on errors (context needed for fixes)
        if terminalContext.lastExitCode != 0 {
            researchLogger.info("Research decision: YES (error exit code \(terminalContext.lastExitCode))")
            return true
        }
        
        // Research if we've never researched before (first pipeline run)
        guard let lastCWD = lastResearchCWD else {
            researchLogger.info("Research decision: YES (first research, no prior CWD, current=\(terminalContext.cwd, privacy: .public))")
            return true
        }
        
        // Research when CWD changed (new environment to explore)
        researchLogger.debug("CWD check: current='\(terminalContext.cwd, privacy: .public)' last='\(lastCWD, privacy: .public)'")
        if terminalContext.cwd != lastCWD {
            researchLogger.info("Research decision: YES (CWD changed from \(lastCWD, privacy: .public) to \(terminalContext.cwd, privacy: .public))")
            return true
        }
        
        // Research periodically (every N commands)
        if commandsSinceLastResearch >= Self.researchCommandThreshold {
            researchLogger.info("Research decision: YES (periodic, \(self.commandsSinceLastResearch) commands since last research)")
            return true
        }
        
        // Research in unknown environments (original fallback logic)
        if gathered.recentCommands.isEmpty && envContext.projectType == .unknown {
            researchLogger.info("Research decision: YES (unknown environment)")
            return true
        }
        
        researchLogger.info("Research decision: NO (context unchanged, \(self.commandsSinceLastResearch)/\(Self.researchCommandThreshold) commands)")
        return false
    }
    
    /// Run the AI-driven research phase to gather additional context
    func runResearchPhase(
        gathered: GatheredContext,
        envContext: EnvironmentContext,
        terminalContext: TerminalContext,
        provider: ProviderType,
        modelId: String
    ) async -> ResearchFindings {
        var findings = ResearchFindings()
        var contextAccumulator: [String] = []
        var consecutiveParseFailures = 0
        let maxConsecutiveFailures = 3
        
        // System prompt for native tool calling
        let systemPrompt = """
        You are a research assistant gathering context to provide helpful terminal command suggestions.
        Explore the user's environment to understand what they might need to do next.
        
        Use the available tools to gather context. After 3-5 tool calls, you should have enough - 
        respond with a text summary of your findings (no tool calls) to indicate you're done.
        
        For shell commands, only use safe exploratory commands like: ls, pwd, git status, which, type, cat, head.
        """
        
        for step in 1...Self.maxResearchSteps {
            // Check for cancellation
            guard !Task.isCancelled else {
                researchLogger.debug("Research phase cancelled at step \(step)")
                break
            }
            
            onPhaseUpdate?(.researching(detail: "Exploring context...", step: step))
            
            // Build the user prompt with accumulated context
            var userPrompt = """
            Current directory: \(terminalContext.cwd)
            Project type: \(envContext.projectType.rawValue)
            """
            
            if let git = envContext.gitInfo {
                userPrompt += "\nGit: branch=\(git.branch), dirty=\(git.isDirty)"
            }
            
            if !gathered.recentCommands.isEmpty {
                userPrompt += "\nRecent commands: \(gathered.recentCommands.prefix(5).joined(separator: ", "))"
            }
            
            if !contextAccumulator.isEmpty {
                userPrompt += "\n\n=== Previous Research ===\n\(contextAccumulator.joined(separator: "\n"))"
            }
            
            userPrompt += "\n\nWhat additional context would help you suggest useful commands? Call a tool or say done."
            
            // Execute research step using native tool calling
            do {
                // Get tool schemas for research tools only
                let researchToolSchemas = Self.researchToolNames.compactMap { toolName -> [String: Any]? in
                    guard let tool = AgentToolRegistry.shared.get(toolName) else { return nil }
                    switch provider {
                    case .cloud(.anthropic):
                        return tool.schema.toAnthropic()
                    case .cloud(.google):
                        return tool.schema.toGoogle()
                    default:
                        return tool.schema.toOpenAI()
                    }
                }
                
                // Build messages for conversation
                var messages: [[String: Any]] = [
                    ["role": "user", "content": userPrompt]
                ]
                
                // Add previous context as prior conversation turns
                if !contextAccumulator.isEmpty {
                    messages.insert(["role": "assistant", "content": "Previous findings: \(contextAccumulator.joined(separator: "; "))"], at: 0)
                }
                
                // Use streaming and collect results
                var accumulatedContent = ""
                var toolCalls: [ParsedToolCall] = []
                
                let stream = LLMClient.shared.completeWithToolsStream(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: researchToolSchemas,
                    provider: provider,
                    modelId: modelId,
                    maxTokens: 500,
                    timeout: 20
                )
                
                for try await event in stream {
                    switch event {
                    case .textDelta(let text):
                        accumulatedContent += text
                    case .toolCallComplete(let toolCall):
                        toolCalls.append(toolCall)
                    default:
                        break
                    }
                }
                
                // Check if model returned text without tool calls (done researching)
                if toolCalls.isEmpty {
                    if !accumulatedContent.isEmpty {
                        researchLogger.info("Research phase complete at step \(step) via native tools: \(accumulatedContent.prefix(100))")
                        findings.discoveries.append(accumulatedContent)
                    }
                    findings.completed = true
                    break
                }
                
                // Execute tool calls
                for toolCall in toolCalls {
                    guard Self.researchToolNames.contains(toolCall.name) else {
                        researchLogger.warning("Research step \(step): Tool '\(toolCall.name)' not in allowed list")
                        continue
                    }
                    
                    guard let tool = AgentToolRegistry.shared.get(toolCall.name) else {
                        researchLogger.error("Research step \(step): Tool '\(toolCall.name)' not in registry")
                        continue
                    }
                    
                    onPhaseUpdate?(.researching(detail: "\(toolCall.name): \(toolCall.stringArguments["path"] ?? toolCall.stringArguments["command"] ?? "...")", step: step))
                    
                    researchLogger.debug("Research step \(step) (native): \(toolCall.name) with args \(toolCall.stringArguments)")
                    
                    let toolResult = await tool.execute(args: toolCall.stringArguments, cwd: terminalContext.cwd)
                    
                    // Track tool call
                    let providerName: String
                    switch provider {
                    case .cloud(let cloudProvider):
                        providerName = cloudProvider == .openai ? "OpenAI" : (cloudProvider == .anthropic ? "Anthropic" : "Google")
                    case .local(let localProvider):
                        providerName = localProvider.rawValue
                    }
                    await TokenUsageTracker.shared.recordToolCall(provider: providerName, model: modelId, command: "research:\(toolCall.name)")
                    
                    if toolResult.success {
                        let truncatedOutput = String(toolResult.output.prefix(1000))
                        contextAccumulator.append("[\(toolCall.name)] \(toolCall.stringArguments): \(truncatedOutput)")
                        
                        // Track findings
                        if toolCall.name == "read_file", let path = toolCall.stringArguments["path"] {
                            let lines = toolResult.output.components(separatedBy: .newlines).count
                            findings.fileInsights.append((path: path, insight: "Read \(lines) lines"))
                        }
                    } else {
                        contextAccumulator.append("[\(toolCall.name)] ERROR: \(toolResult.error ?? "unknown")")
                    }
                }
                findings.stepsTaken = step
                continue
            } catch {
                researchLogger.error("Research step \(step) native tool error: \(error.localizedDescription)")
                consecutiveParseFailures += 1
                if consecutiveParseFailures >= maxConsecutiveFailures {
                    findings.discoveries.append("Research ended: \(error.localizedDescription)")
                    break
                }
                continue
            }
        }
        
        // Check if we hit step limit without completing
        if !findings.completed && findings.stepsTaken >= Self.maxResearchSteps {
            researchLogger.info("Research phase hit step limit (\(Self.maxResearchSteps))")
        }
        
        return findings
    }
    
    /// Update research tracking state after successful research
    func updateResearchState(cwd: String) {
        lastResearchCWD = cwd
        commandsSinceLastResearch = 0
        lastResearchTimestamp = Date()
    }
    
    /// Increment command counter for periodic research triggering
    func recordCommand() {
        commandsSinceLastResearch += 1
        researchLogger.debug("Commands since last research: \(self.commandsSinceLastResearch)/\(Self.researchCommandThreshold)")
    }
    
    /// Reset research tracking state
    func reset() {
        lastResearchCWD = nil
        commandsSinceLastResearch = 0
        lastResearchTimestamp = nil
    }
    
    // MARK: - Response Parsing Helpers
    
    /// Parse a value as boolean
    static func parseBoolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let str = value as? String {
            let lower = str.lowercased()
            if ["true", "yes", "done", "1"].contains(lower) { return true }
            if ["false", "no", "0"].contains(lower) { return false }
        }
        if let num = value as? Int { return num != 0 }
        return nil
    }
    
    /// Parse a value as string
    static func parseStringValue(_ value: Any?) -> String? {
        if let str = value as? String, !str.isEmpty { return str }
        if let num = value as? Int { return String(num) }
        if let num = value as? Double { return String(num) }
        return nil
    }
    
    /// Convert any value to string
    static func stringifyValue(_ value: Any) -> String {
        if let str = value as? String { return str }
        if let num = value as? Int { return String(num) }
        if let num = value as? Double { return String(num) }
        if let bool = value as? Bool { return String(bool) }
        return String(describing: value)
    }
    
    /// Extract a brief insight from file contents
    static func extractFileInsight(from content: String, path: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        let lineCount = lines.count
        
        // For package.json, extract name and scripts
        if path.hasSuffix("package.json") {
            if content.contains("\"scripts\"") {
                return "Node.js project with \(lineCount) lines, has scripts defined"
            }
            return "Node.js package.json with \(lineCount) lines"
        }
        
        // For Cargo.toml
        if path.hasSuffix("Cargo.toml") {
            return "Rust project manifest with \(lineCount) lines"
        }
        
        // For go.mod
        if path.hasSuffix("go.mod") {
            return "Go module with \(lineCount) lines"
        }
        
        // For Makefile
        if path.hasSuffix("Makefile") || path.hasSuffix("makefile") {
            let targets = lines.filter { $0.contains(":") && !$0.hasPrefix("\t") && !$0.hasPrefix("#") }.count
            return "Makefile with ~\(targets) targets"
        }
        
        // Generic insight
        if lineCount > 100 {
            return "Large file (\(lineCount) lines)"
        } else if lineCount > 0 {
            return "File with \(lineCount) lines"
        }
        return "Empty or binary file"
    }
}
