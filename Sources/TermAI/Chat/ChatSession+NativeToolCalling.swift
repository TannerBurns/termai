import Foundation
import TermAIModels

// MARK: - Native Tool Calling

extension ChatSession {
    
    /// Result of a native tool calling step
    struct NativeToolStepResult {
        let textResponse: String?
        let toolsExecuted: [(name: String, result: AgentToolResult)]
        let isDone: Bool
        let error: String?
    }
    
    /// Execute a step using native tool calling APIs
    /// Returns when the model either responds with text (no tool calls) or signals completion
    func executeStepWithNativeTools(
        userRequest: String,
        goal: String,
        contextLog: [String],
        checklistContext: String,
        iterations: Int,
        maxIterations: Int
    ) async -> NativeToolStepResult {
        // Build the system prompt with workflow guidance
        let basePlanningGuidance: String
        if iterations == 1 && checklistContext.isEmpty {
            basePlanningGuidance = """
            
            IMPORTANT - START BY PLANNING:
            Before doing any work, call plan_and_track to set your goal and create a task checklist.
            This helps track progress and ensures systematic execution.
            
            Example: plan_and_track(goal="Build a REST API", tasks=["Set up project structure", "Create endpoints", "Add error handling", "Test the API"])
            
            Only skip planning for truly trivial single-command requests (e.g., "run pwd", "list files").
            """
        } else if !checklistContext.isEmpty {
            basePlanningGuidance = """
            
            TASK TRACKING (checklist is already set - do NOT create a new one):
            - The checklist above was extracted from the implementation plan
            - Focus on completing the CURRENT TASK shown above
            - When you finish a task, call plan_and_track with complete_task=<id> to mark it done
            - The next pending task will automatically become current
            - Do NOT call plan_and_track with goal/tasks - the checklist is already set up
            """
        } else {
            basePlanningGuidance = ""
        }
        
        let profilePlanningGuidance = AgentSettings.shared.enablePlanning ? effectiveProfile.planningGuidance(for: agentMode) : ""
        let planningGuidance = basePlanningGuidance + (profilePlanningGuidance.isEmpty ? "" : "\n\n" + profilePlanningGuidance)
        
        // Navigator mode has a special system prompt
        let systemPrompt: String
        if agentMode == .navigator {
            let planExistsContext = currentPlanId != nil ? """
            
            ╔══════════════════════════════════════════════════════════════════╗
            ║ A PLAN ALREADY EXISTS!                                           ║
            ║                                                                  ║
            ║ If user says "build", "implement", "yes", "go ahead", "pilot":  ║
            ║   → Reply ONLY with: <BUILD_MODE>pilot</BUILD_MODE>              ║
            ║                                                                  ║
            ║ If user specifically says "copilot":                             ║
            ║   → Reply ONLY with: <BUILD_MODE>copilot</BUILD_MODE>            ║
            ║                                                                  ║
            ║ DO NOT create another plan. Just output the BUILD_MODE tag.     ║
            ╚══════════════════════════════════════════════════════════════════╝
            """ : ""
            
            systemPrompt = """
            MODE: Navigator - Implementation Planning
            \(planExistsContext)
            
            USER REQUEST: \(userRequest)
            
            You are a Navigator - your role is to create implementation plans.
            You can READ files but CANNOT write files or execute commands.
            
            If asked to build/implement an existing plan, output:
            <BUILD_MODE>pilot</BUILD_MODE> (for pilot mode)
            or <BUILD_MODE>copilot</BUILD_MODE> (for copilot mode)
            
            \(planningGuidance)
            """
        } else {
            systemPrompt = """
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
            - For EXISTING files: use edit_file (search/replace), insert_lines, or delete_lines for surgical changes
            - Only use write_file to CREATE new files or when you need to COMPLETELY rewrite a file
            - Verify your changes by reading files after editing
            - When the task is complete, respond with a summary (no tool calls)
            """
        }
        
        // Build the context as user message
        var contextParts: [String] = []
        
        // Inject the LATEST plan from THIS SESSION for implementation mode
        if agentMode != .navigator {
            if let latestPlan = PlanManager.shared.latestPlan(for: self.id),
               let planContent = PlanManager.shared.getPlanContent(id: latestPlan.id) {
                let planContext = PinnedContext(
                    type: .snippet,
                    path: "plan://\(latestPlan.id.uuidString)",
                    displayName: "Implementation Plan: \(latestPlan.title)",
                    content: planContent
                )
                contextParts.append(formatAttachedContext(planContext))
                AgentDebugConfig.log("[Agent] Injected latest plan for session \(self.id): \(latestPlan.title)")
                
                if currentPlanId != latestPlan.id {
                    currentPlanId = latestPlan.id
                    persistSettings()
                    AgentDebugConfig.log("[Agent] Updated currentPlanId to latest: \(latestPlan.id)")
                }
            }
            else if let planId = currentPlanId,
                    let plan = PlanManager.shared.getPlan(id: planId),
                    plan.sessionId == self.id,
                    let planContent = PlanManager.shared.getPlanContent(id: planId) {
                let planContext = PinnedContext(
                    type: .snippet,
                    path: "plan://\(planId.uuidString)",
                    displayName: "Implementation Plan: \(plan.title)",
                    content: planContent
                )
                contextParts.append(formatAttachedContext(planContext))
                AgentDebugConfig.log("[Agent] Injected plan from currentPlanId: \(plan.title)")
            }
        }
        
        // Add attached contexts from the MOST RECENT user message
        if let lastUserMessage = messages.filter({ $0.role == "user" }).last {
            if let termCtx = lastUserMessage.terminalContext, !termCtx.isEmpty {
                var header = "=== TERMINAL OUTPUT (from user's terminal session) ==="
                if let meta = lastUserMessage.terminalContextMeta, let cwd = meta.cwd, !cwd.isEmpty {
                    header += "\nWorking Directory: \(cwd)"
                }
                header += "\nThe user has shared the following terminal output for you to analyze:"
                contextParts.append("\(header)\n```\n\(termCtx)\n```\n")
                AgentDebugConfig.log("[Agent] Included terminal context (\(termCtx.count) chars) in context")
            }
            
            if let contexts = lastUserMessage.attachedContexts, !contexts.isEmpty {
                for context in contexts {
                    if context.path.hasPrefix("plan://") { continue }
                    contextParts.append(formatAttachedContext(context))
                }
            }
        }
        
        contextParts.append("CONTEXT LOG:\n\(contextLog.joined(separator: "\n"))")
        
        let contextMessage = contextParts.joined(separator: "\n")
        
        var conversationMessages: [[String: Any]] = [
            ["role": "user", "content": contextMessage]
        ]
        
        // Get tool schemas based on provider and agent mode
        let toolSchemas: [[String: Any]]
        switch providerType {
        case .cloud(.anthropic):
            toolSchemas = AgentToolRegistry.shared.schemas(for: agentMode, provider: providerType)
        case .cloud(.google):
            toolSchemas = AgentToolRegistry.shared.tools(for: agentMode).map { $0.schema.toGoogle() }
        default:
            toolSchemas = AgentToolRegistry.shared.schemas(for: agentMode, provider: providerType)
        }
        
        var allToolsExecuted: [(name: String, result: AgentToolResult)] = []
        var lastTextResponse: String? = nil
        var loopCount = 0
        let maxToolLoops = AgentSettings.shared.maxToolCallsPerStep
        
        while loopCount < maxToolLoops {
            loopCount += 1
            
            do {
                let result = try await LLMClient.shared.completeWithTools(
                    systemPrompt: systemPrompt,
                    messages: conversationMessages,
                    tools: toolSchemas,
                    provider: providerType,
                    modelId: model,
                    maxTokens: 64000,
                    timeout: 120
                )
                
                agentSessionTokensUsed += result.totalTokens
                if result.promptTokens > accumulatedContextTokens {
                    accumulatedContextTokens = result.promptTokens
                }
                currentContextTokens = accumulatedContextTokens
                
                if !result.hasToolCalls {
                    lastTextResponse = result.content
                    return NativeToolStepResult(
                        textResponse: lastTextResponse,
                        toolsExecuted: allToolsExecuted,
                        isDone: true,
                        error: nil
                    )
                }
                
                var toolResults: [(id: String, name: String, result: String, isError: Bool)] = []
                
                for toolCall in result.toolCalls {
                    AgentDebugConfig.log("[NativeTools] Executing tool: \(toolCall.name) with args: \(toolCall.arguments)")
                    
                    let isTaskStatusUpdate = toolCall.name == "plan_and_track" &&
                        (toolCall.stringArguments["complete_task"] != nil || toolCall.stringArguments["start_task"] != nil)
                    
                    if !isTaskStatusUpdate {
                        messages.append(ChatMessage(
                            role: "assistant",
                            content: "",
                            agentEvent: AgentEvent(
                                kind: "step",
                                title: toolCall.name,
                                details: nil,
                                command: nil,
                                output: nil,
                                collapsed: true,
                                toolCallId: toolCall.id,
                                toolStatus: "running",
                                eventCategory: "tool"
                            )
                        ))
                        messages = messages
                        persistMessages()
                    }
                    
                    if let tool = AgentToolRegistry.shared.get(toolCall.name) {
                        guard AgentToolRegistry.shared.isToolAvailable(toolCall.name, in: agentMode) else {
                            let errorMsg = "Tool '\(toolCall.name)' is not available in \(agentMode.rawValue) mode"
                            toolResults.append((id: toolCall.id, name: toolCall.name, result: errorMsg, isError: true))
                            agentContextLog.append("TOOL ERROR: \(errorMsg)")
                            
                            if let idx = messages.lastIndex(where: { $0.agentEvent?.toolCallId == toolCall.id }) {
                                var msg = messages[idx]
                                var evt = msg.agentEvent!
                                evt.toolStatus = "failed"
                                evt.output = errorMsg
                                msg.agentEvent = evt
                                messages[idx] = msg
                                messages = messages
                                persistMessages()
                            }
                            continue
                        }
                        
                        var args = toolCall.stringArguments
                        args["_sessionId"] = self.id.uuidString
                        args["_contextTokens"] = String(effectiveContextLimit)
                        
                        let isFileOp = ["write_file", "edit_file", "insert_lines", "delete_lines", "delete_file"].contains(toolCall.name)
                        let toolResult: AgentToolResult
                        if isFileOp {
                            toolResult = await executeFileToolWithApproval(
                                tool: tool,
                                toolName: toolCall.name,
                                args: args,
                                cwd: self.lastKnownCwd.isEmpty ? nil : self.lastKnownCwd,
                                toolCallId: toolCall.id
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
                        
                        if !isTaskStatusUpdate {
                            agentContextLog.append("TOOL: \(toolCall.name) \(toolCall.stringArguments)")
                            let contextType: SmartTruncator.ContentContext = {
                                switch toolCall.name {
                                case "read_file": return .fileContent
                                case "shell": return .commandOutput
                                case "http_request": return .apiResponse
                                default: return .unknown
                                }
                            }()
                            let truncatedResult = SmartTruncator.smartTruncate(
                                resultString,
                                maxChars: effectiveOutputCaptureLimit,
                                context: contextType
                            )
                            agentContextLog.append("RESULT: \(truncatedResult)")
                        }
                        
                        if !isTaskStatusUpdate {
                            if let idx = messages.lastIndex(where: { $0.agentEvent?.toolCallId == toolCall.id }) {
                                var msg = messages[idx]
                                var evt = msg.agentEvent!
                                evt.toolStatus = toolResult.success ? "succeeded" : "failed"
                                evt.output = resultString
                                evt.fileChange = toolResult.fileChange
                                evt.details = "Args: \(toolCall.stringArguments)"
                                msg.agentEvent = evt
                                messages[idx] = msg
                            }
                            messages = messages
                            persistMessages()
                        }
                    } else {
                        let errorMsg = "Unknown tool: \(toolCall.name)"
                        toolResults.append((id: toolCall.id, name: toolCall.name, result: errorMsg, isError: true))
                        agentContextLog.append("TOOL ERROR: \(errorMsg)")
                    }
                    
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
                    let assistantMsg = ToolResultFormatter.assistantMessageWithToolCallsAnthropic(
                        content: result.content,
                        toolCalls: result.toolCalls
                    )
                    conversationMessages.append(assistantMsg)
                    let anthropicResults = toolResults.map { (toolUseId: $0.id, result: $0.result, isError: $0.isError) }
                    conversationMessages.append(ToolResultFormatter.userMessageWithToolResultsAnthropic(results: anthropicResults))
                    
                case .cloud(.google):
                    let assistantMsg = ToolResultFormatter.assistantMessageWithToolCallsOpenAI(
                        content: result.content,
                        toolCalls: result.toolCalls
                    )
                    conversationMessages.append(assistantMsg)
                    let googleResults = toolResults.map { (name: $0.name, result: ["output": $0.result] as [String: Any]) }
                    conversationMessages.append(ToolResultFormatter.functionResponseMessageGoogle(results: googleResults))
                    
                default:
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
        
        return NativeToolStepResult(
            textResponse: "Reached maximum tool calls per step (\(maxToolLoops)). The agent made too many consecutive tool calls without completing. Consider breaking down the task or being more specific.",
            toolsExecuted: allToolsExecuted,
            isDone: true,
            error: nil
        )
    }
}
