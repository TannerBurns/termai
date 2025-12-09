import Foundation
import TermAIModels

// MARK: - JSON Helper Structs (for decision prompts, not tool execution)

extension ChatSession {
    
    // Legacy JSON tool execution code has been removed.
    // Tool calling now exclusively uses native provider APIs (executeStepWithNativeTools).
    // The structs below are only used for simple decision prompts (RUN vs RESPOND, done assessment, etc.)
    
    // Helper to decode any JSON value and convert to string
    struct AnyCodable: Decodable {
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
    struct UnifiedAgentJSON: Decodable {
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
        
        // Auto profile fields (for profile analysis/suggestion)
        let suggested_profile: String?
        let confidence: String?
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
        
        // Auto profile fields
        var suggestedProfile: String? = nil
        var confidence: String? = nil
    }
    
    func callOneShotJSON(prompt: String) async -> AgentJSONResponse {
        let text = await callOneShotText(prompt: prompt)
        
        // Strip markdown code blocks if present
        var cleaned = text
        if cleaned.contains("```") {
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
            response.suggestedProfile = unified.suggested_profile
            response.confidence = unified.confidence
        }
        
        return response
    }
    
    /// Wrapper around callOneShotJSON with retry logic for network failures or empty responses
    func callOneShotJSONWithRetry(prompt: String, maxRetries: Int = 3) async -> AgentJSONResponse {
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
            
            AgentDebugConfig.log("[Agent] Empty/error response (attempt \(attempt)/\(maxRetries)): \(response.raw.prefix(100))")
            
            if attempt < maxRetries {
                if agentCancelled {
                    AgentDebugConfig.log("[Agent] Cancelled during retry wait")
                    break
                }
                
                let delay = Double(attempt) * 1.0
                AgentDebugConfig.log("[Agent] Retrying in \(delay)s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        AgentDebugConfig.log("[Agent] All \(maxRetries) retries failed, using last response")
        return lastResponse
    }
}

// MARK: - Auto Profile Analysis

extension ChatSession {
    
    /// Analyzes the current task and suggests the most appropriate profile
    /// Returns the suggested profile or nil if no change is needed
    func analyzeProfileForTask(
        currentTask: String,
        nextItems: [String] = [],
        recentContext: String
    ) async -> (profile: AgentProfile, reason: String, confidence: String)? {
        let analysisPrompt = AgentProfilePrompts.profileAnalysisPrompt(
            currentTask: currentTask,
            nextItems: nextItems,
            recentContext: recentContext,
            currentProfile: activeProfile
        )
        
        AgentDebugConfig.log("[Agent] Profile analysis prompt =>\n\(analysisPrompt)")
        let result = await callOneShotJSON(prompt: analysisPrompt)
        AgentDebugConfig.log("[Agent] Profile analysis result: \(result.raw)")
        
        guard let suggestedProfileStr = result.suggestedProfile,
              let suggestedProfile = AgentProfile.fromString(suggestedProfileStr) else {
            AgentDebugConfig.log("[Agent] Could not parse suggested profile from response")
            return nil
        }
        
        let reason = result.reason ?? "Task analysis"
        let confidence = result.confidence ?? "medium"
        
        if suggestedProfile != activeProfile {
            return (suggestedProfile, reason, confidence)
        }
        
        return nil
    }
    
    /// Switches the active profile in Auto mode and notifies the user
    /// Returns true if a switch occurred
    @discardableResult
    func switchProfileIfNeeded(
        to newProfile: AgentProfile,
        reason: String,
        showNotification: Bool = true
    ) -> Bool {
        guard agentProfile.isAuto else { return false }
        guard newProfile != activeProfile else { return false }
        
        let previousProfile = activeProfile
        activeProfile = newProfile
        
        agentContextLog.append("PROFILE SWITCH: \(previousProfile.rawValue) → \(newProfile.rawValue) (\(reason))")
        
        if showNotification {
            let statusMessage = ChatMessage(
                role: "assistant",
                content: "",
                agentEvent: AgentEvent(
                    kind: "status",
                    title: "\(previousProfile.rawValue) → \(newProfile.rawValue)",
                    details: reason,
                    command: nil,
                    output: nil,
                    collapsed: true,
                    eventCategory: "profile"
                )
            )
            messages.append(statusMessage)
            messages = messages
            persistMessages()
        }
        
        return true
    }
}
