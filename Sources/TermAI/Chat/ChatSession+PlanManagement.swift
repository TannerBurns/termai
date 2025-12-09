import Foundation
import TermAIModels

// MARK: - PlanTrackDelegate Protocol Implementation

extension ChatSession {
    
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
        
        // Auto profile: Analyze if we should switch profiles for this task
        if agentProfile.isAuto, let item = checklist.items.first(where: { $0.id == taskId }) {
            Task { @MainActor in
                // Get remaining items for context
                let remainingItems = checklist.items
                    .filter { $0.status == .pending && $0.id != taskId }
                    .map { $0.description }
                
                if let analysis = await analyzeProfileForTask(
                    currentTask: item.description,
                    nextItems: remainingItems,
                    recentContext: agentContextLog.suffix(5).joined(separator: "\n")
                ) {
                    // Switch on medium or high confidence
                    if analysis.confidence != "low" {
                        switchProfileIfNeeded(to: analysis.profile, reason: analysis.reason)
                    }
                }
            }
        }
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
}

// MARK: - Navigator Mode Build Trigger

extension ChatSession {
    
    /// Extract build mode from a BUILD_MODE tag in the response (Navigator mode)
    func extractBuildMode(from response: String) -> AgentMode? {
        // Pattern: <BUILD_MODE>pilot</BUILD_MODE> or <BUILD_MODE>copilot</BUILD_MODE>
        let pattern = "<BUILD_MODE>(\\w+)</BUILD_MODE>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
              let modeRange = Range(match.range(at: 1), in: response) else {
            return nil
        }
        
        let modeString = String(response[modeRange]).lowercased()
        switch modeString {
        case "pilot": return .pilot
        case "copilot": return .copilot
        default: return nil
        }
    }
    
    /// Start building the current plan with the specified mode
    func startBuildingPlan(with mode: AgentMode) async {
        // Get the LATEST plan for THIS session - more reliable than currentPlanId
        guard let plan = PlanManager.shared.latestPlan(for: self.id),
              let planContent = PlanManager.shared.getPlanContent(id: plan.id) else {
            // Fallback to currentPlanId if no session plan found
            guard let planId = currentPlanId,
                  let planContent = PlanManager.shared.getPlanContent(id: planId),
                  let fallbackPlan = PlanManager.shared.getPlan(id: planId),
                  fallbackPlan.sessionId == self.id else {
                AgentDebugConfig.log("[Navigator] No plan found for session \(self.id)")
                return
            }
            // Use fallback
            await startBuildingPlanInternal(plan: fallbackPlan, planContent: planContent, mode: mode)
            return
        }
        
        // Update currentPlanId to match the latest plan
        currentPlanId = plan.id
        persistSettings()
        AgentDebugConfig.log("[Navigator] Using latest plan for session: \(plan.title) (id: \(plan.id))")
        
        await startBuildingPlanInternal(plan: plan, planContent: planContent, mode: mode)
    }
    
    /// Internal helper to build a plan
    func startBuildingPlanInternal(plan: Plan, planContent: String, mode: AgentMode) async {
        let planId = plan.id
        
        // Add mode switch indicator to chat
        messages.append(ChatMessage(
            role: "assistant",
            content: "",
            agentEvent: AgentEvent(
                kind: "mode_switch",
                title: "Navigator → \(mode.rawValue)",
                details: "Switching to \(mode.rawValue) mode to implement the plan",
                command: nil,
                output: nil,
                collapsed: true
            )
        ))
        messages = messages
        persistMessages()
        
        // Update plan status
        PlanManager.shared.updatePlanStatus(id: planId, status: .implementing)
        
        // Switch to the requested mode
        agentMode = mode
        persistSettings()
        
        // Extract checklist from plan and set it directly
        let checklistItems = extractChecklistFromPlan(planContent)
        if !checklistItems.isEmpty {
            agentChecklist = TaskChecklist(from: checklistItems, goal: "Implement: \(plan.title)")
            
            // Add a checklist message to the UI
            let checklistDisplay = agentChecklist!.displayString
            messages.append(ChatMessage(
                role: "assistant",
                content: "",
                agentEvent: AgentEvent(
                    kind: "checklist",
                    title: "Task Checklist (\(agentChecklist!.completedCount)/\(agentChecklist!.items.count) done)",
                    details: checklistDisplay,
                    command: nil,
                    output: nil,
                    collapsed: false,
                    checklistItems: agentChecklist!.items
                )
            ))
            messages = messages
            persistMessages()
        }
        
        // Attach the plan as context
        let planContext = PinnedContext(
            type: .snippet,
            path: "plan://\(planId.uuidString)",
            displayName: "Implementation Plan: \(plan.title)",
            content: planContent
        )
        pendingAttachedContexts.append(planContext)
        
        // Send the implementation message
        // The checklist is already set, so tell the agent to use it
        let implementationMessage = checklistItems.isEmpty
            ? "Please implement the attached implementation plan. Follow the checklist items in order."
            : "Please implement the attached implementation plan. The checklist has already been extracted from the plan and is ready - use it to track your progress. Focus on completing each item in order. Do NOT call plan_and_track to create a new checklist - it's already set up."
        
        await sendUserMessage(implementationMessage)
    }
    
    /// Extract checklist items from plan markdown content
    /// Looks for lines starting with "- [ ]" in the Checklist section
    func extractChecklistFromPlan(_ content: String) -> [String] {
        var items: [String] = []
        var inChecklistSection = false
        
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Look for Checklist header
            if trimmed.lowercased().contains("## checklist") || trimmed.lowercased() == "checklist" {
                inChecklistSection = true
                continue
            }
            
            // Stop at next section
            if inChecklistSection && trimmed.hasPrefix("##") && !trimmed.lowercased().contains("checklist") {
                break
            }
            
            // Extract checklist items (- [ ] format)
            if inChecklistSection && (trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")) {
                // Remove the checkbox prefix and get the task description
                let item = trimmed
                    .replacingOccurrences(of: "- [ ] ", with: "")
                    .replacingOccurrences(of: "- [x] ", with: "")
                    .replacingOccurrences(of: "- [X] ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                
                if !item.isEmpty {
                    items.append(item)
                }
            }
        }
        
        return items
    }
}

// MARK: - CreatePlanDelegate Protocol Implementation

extension ChatSession {
    
    /// Create a new implementation plan (Navigator mode)
    func createPlan(title: String, content: String) async -> UUID {
        // Create the plan
        let plan = Plan(
            title: title,
            content: content,
            sessionId: id,
            status: .ready
        )
        
        // Save the plan
        PlanManager.shared.savePlan(plan)
        
        // Track as current plan
        currentPlanId = plan.id
        
        // Add a plan_created message to the UI with the special PlanReadyView display
        messages.append(ChatMessage(
            role: "assistant",
            content: "",
            agentEvent: AgentEvent(
                kind: "plan_created",
                title: title,
                details: content,
                command: nil,
                output: nil,
                collapsed: false,
                planId: plan.id
            )
        ))
        messages = messages
        persistMessages()
        persistSettings()
        
        return plan.id
    }
}
