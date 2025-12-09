import Foundation
import os.log

private let planningLogger = Logger(subsystem: "com.termai.app", category: "SuggestionPlanning")

/// Handles the planning phase of the suggestion pipeline
/// Uses heuristics first to skip AI calls when possible, then falls back to AI for ambiguous contexts
struct SuggestionPlanningPhase {
    
    // MARK: - Public API
    
    /// Plan suggestions based on context
    /// Uses heuristics first to skip AI call when possible (saves latency and tokens)
    static func planSuggestions(
        gathered: GatheredContext,
        envContext: EnvironmentContext,
        terminalContext: TerminalContext,
        researchFindings: ResearchFindings,
        provider: ProviderType,
        modelId: String
    ) async -> SuggestionPlan {
        var plan = SuggestionPlan()
        
        // ═══════════════════════════════════════════════════════════════════
        // HEURISTIC-BASED PLANNING (Skip AI call when we can determine intent)
        // ═══════════════════════════════════════════════════════════════════
        
        // CASE 1: Error recovery - highest priority, skip AI call
        if terminalContext.lastExitCode != 0 {
            plan.suggestionType = "error_fix"
            plan.userIntent = "Fixing a command error"
            plan.shouldSuggest = true
            plan.suggestionCount = 2
            planningLogger.info("Planning (heuristic): Error detected (exit \(terminalContext.lastExitCode)), focusing on error_fix")
            return plan
        }
        
        // CASE 2: Git dirty state - clear action needed, skip AI call
        if let git = terminalContext.gitInfo, git.isDirty {
            plan.suggestionType = "git_workflow"
            plan.userIntent = "Managing uncommitted changes"
            plan.focusArea = "git"
            plan.shouldSuggest = true
            plan.suggestionCount = 2
            planningLogger.info("Planning (heuristic): Git dirty, focusing on git_workflow")
            return plan
        }
        
        // CASE 3: Git ahead of remote - push suggested, skip AI call
        if let git = terminalContext.gitInfo, git.ahead > 0 {
            plan.suggestionType = "git_workflow"
            plan.userIntent = "Pushing committed changes"
            plan.focusArea = "git push"
            plan.shouldSuggest = true
            plan.suggestionCount = 1
            planningLogger.info("Planning (heuristic): Git ahead by \(git.ahead), suggesting push")
            return plan
        }
        
        // CASE 4: Git behind remote - pull suggested, skip AI call
        if let git = terminalContext.gitInfo, git.behind > 0 {
            plan.suggestionType = "git_workflow"
            plan.userIntent = "Syncing with remote"
            plan.focusArea = "git pull"
            plan.shouldSuggest = true
            plan.suggestionCount = 1
            planningLogger.info("Planning (heuristic): Git behind by \(git.behind), suggesting pull")
            return plan
        }
        
        // CASE 5: Known project type with no recent activity - suggest build/run
        if envContext.projectType != .unknown && gathered.recentCommands.isEmpty {
            plan.suggestionType = "workflow"
            plan.userIntent = "Starting work on \(envContext.projectType.rawValue) project"
            plan.focusArea = envContext.projectType.rawValue
            plan.shouldSuggest = true
            plan.suggestionCount = 2
            planningLogger.info("Planning (heuristic): Fresh \(envContext.projectType.rawValue) project, suggesting common commands")
            return plan
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // AI-BASED PLANNING (Only for ambiguous contexts)
        // ═══════════════════════════════════════════════════════════════════
        
        planningLogger.info("Planning: Using AI for nuanced context analysis")
        
        // Build prompt with optional research findings
        var contextSection = """
        CONTEXT:
        \(gathered.formattedForPrompt)
        
        ENVIRONMENT:
        \(envContext.formattedForPrompt)
        """
        
        // Add research findings if available
        let researchFormatted = researchFindings.formattedForPrompt
        if !researchFormatted.isEmpty {
            contextSection += "\n\n\(researchFormatted)"
        }
        
        // Determine if this appears to be an idle/startup context
        let isIdleContext = gathered.terminalOutput.isEmpty &&
                           gathered.lastExitCode == 0 &&
                           gathered.recentCommands.filter { !$0.contains("✓") && !$0.contains("✗") }.isEmpty
        
        let planPrompt = """
        Analyze this terminal context and plan helpful command suggestions.
        
        \(contextSection)
        
        SITUATION: \(isIdleContext ? "User just opened terminal or is idle - suggest useful commands based on their frequent usage patterns and current directory." : "User is actively working - suggest helpful next steps based on their activity.")
        
        Your goal is to ALWAYS provide helpful suggestions. Consider:
        1. What is the user's apparent intent or workflow?
        2. What type of suggestions fit best: "error_fix", "next_step", "workflow", "history_based", or "general"
        3. Focus area (if any specific tool/task is relevant)
        
        IMPORTANT GUIDELINES:
        - For IDLE/STARTUP: Suggest commands from their frequent history that are RELEVANT to the current directory. Don't suggest project-specific commands (npm, cargo, swift) if they're in home directory or a non-project folder.
        - For ACTIVE WORK: Suggest logical next steps based on what they just did.
        - For ERRORS: Focus on fixing the error.
        - ALWAYS suggest something helpful - never leave the user without suggestions.
        
        Reply as JSON:
        {"user_intent": "brief description", "should_suggest": true, "suggestion_type": "type", "focus_area": "optional focus", "suggestion_count": 2}
        """
        
        do {
            let response = try await LLMClient.shared.complete(
                systemPrompt: "You are a terminal assistant analyzing user context to plan helpful suggestions.",
                userPrompt: planPrompt,
                provider: provider,
                modelId: modelId,
                reasoningEffort: .none,
                maxTokens: 300,
                timeout: 20,
                requestType: .terminalSuggestion
            )
            
            // Parse the response
            if let parsed = parsePlanResponse(response) {
                plan.userIntent = parsed.userIntent ?? plan.userIntent
                // ALWAYS suggest - don't let AI opt out. We filtered history to be context-relevant.
                plan.shouldSuggest = true
                plan.suggestionType = parsed.suggestionType ?? plan.suggestionType
                plan.focusArea = parsed.focusArea ?? plan.focusArea
                plan.suggestionCount = max(1, parsed.suggestionCount ?? plan.suggestionCount)
            }
            
            planningLogger.info("Planning (AI): intent='\(plan.userIntent)', type=\(plan.suggestionType), suggest=\(plan.shouldSuggest) (forced true)")
        } catch {
            planningLogger.error("Planning AI call failed: \(error.localizedDescription)")
            // Fall back to heuristics - still suggest general commands
            plan.shouldSuggest = true
            plan.suggestionType = "general"
        }
        
        return plan
    }
    
    // MARK: - Response Parsing
    
    /// Parse the planning response JSON
    static func parsePlanResponse(_ response: String) -> (userIntent: String?, shouldSuggest: Bool?, suggestionType: String?, focusArea: String?, suggestionCount: Int?)? {
        var jsonString = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code block if present
        if jsonString.hasPrefix("```") {
            let lines = jsonString.components(separatedBy: "\n")
            var jsonLines: [String] = []
            var inBlock = false
            for line in lines {
                if line.hasPrefix("```") { inBlock.toggle(); continue }
                if inBlock { jsonLines.append(line) }
            }
            jsonString = jsonLines.joined(separator: "\n")
        }
        
        // Find JSON object
        if let start = jsonString.firstIndex(of: "{"),
           let end = jsonString.lastIndex(of: "}") {
            jsonString = String(jsonString[start...end])
        }
        
        guard let data = jsonString.data(using: .utf8) else { return nil }
        
        struct PlanJSON: Decodable {
            let user_intent: String?
            let should_suggest: Bool?
            let suggestion_type: String?
            let focus_area: String?
            let suggestion_count: Int?
        }
        
        guard let parsed = try? JSONDecoder().decode(PlanJSON.self, from: data) else { return nil }
        
        return (parsed.user_intent, parsed.should_suggest, parsed.suggestion_type, parsed.focus_area, parsed.suggestion_count)
    }
}
