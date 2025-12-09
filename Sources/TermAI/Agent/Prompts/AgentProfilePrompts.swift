import Foundation

/// Contains all profile-specific prompt content
/// Separated into a namespace for organization
/// Extensions in separate files add profile-specific prompts
enum AgentProfilePrompts {
    
    // MARK: - General Profile
    
    static func generalSystemPrompt(for mode: AgentMode) -> String {
        if mode == .scout {
            return """
            
            PROFILE: General Assistant (Exploration Mode)
            
            You are exploring and analyzing to help the user understand their codebase or system.
            Focus on providing clear, accurate information about what you find.
            """
        } else {
            return """
            
            PROFILE: General Assistant
            
            You are a balanced, general-purpose assistant. Approach tasks systematically:
            - Break down complex requests into manageable steps
            - Verify each step before moving to the next
            - Communicate progress and any issues clearly
            """
        }
    }
    
    static func generalPlanningGuidance(for mode: AgentMode) -> String {
        if mode == .scout {
            return """
            PLANNING (Exploration):
            - Identify what information the user needs
            - Plan which files/directories to examine
            - Note patterns and relationships to report
            """
        } else {
            return """
            PLANNING:
            - Break the task into numbered steps
            - Identify dependencies between steps
            - Include verification for key milestones
            - Consider what could go wrong
            """
        }
    }
    
    static func generalReflectionPrompt(for mode: AgentMode) -> String {
        return """
        REFLECTION QUESTIONS:
        1. What has been accomplished so far?
        2. Are there any blockers or issues?
        3. Is the current approach working, or should we adjust?
        4. What remains to complete the goal?
        """
    }
    
    // MARK: - Profile Analysis (for Auto mode)
    
    /// Prompt for analyzing what profile best fits the current task
    /// Used during reflection and plan item transitions in Auto mode
    static func profileAnalysisPrompt(
        currentTask: String,
        nextItems: [String],
        recentContext: String,
        currentProfile: AgentProfile
    ) -> String {
        let profileOptions = AgentProfile.specializableProfiles.map { profile in
            "- \(profile.rawValue): \(profile.description)"
        }.joined(separator: "\n")
        
        return """
        Analyze the current work and determine the most appropriate profile.
        
        AVAILABLE PROFILES:
        \(profileOptions)
        - General: Balanced approach for mixed or unclear tasks
        
        CURRENT PROFILE: \(currentProfile.rawValue)
        CURRENT/NEXT TASK: \(currentTask)
        \(nextItems.isEmpty ? "" : "UPCOMING ITEMS:\n" + nextItems.prefix(3).map { "- \($0)" }.joined(separator: "\n"))
        
        RECENT CONTEXT:
        \(recentContext)
        
        Reply with ONLY valid JSON:
        {
            "suggested_profile": "coding|codeReview|testing|debugging|security|refactoring|devops|documentation|productManagement|general",
            "reason": "brief explanation of why this profile fits",
            "confidence": "high|medium|low"
        }
        
        Rules:
        - Only suggest switching if the work clearly fits a different profile
        - Prefer keeping current profile if work is ambiguous or mixed
        
        IMPORTANT DISTINCTION - coding vs codeReview:
        - "coding" = WRITING/IMPLEMENTING new code, creating features, building architecture
        - "codeReview" = READING/REVIEWING/ASSESSING existing code, evaluating quality, giving feedback
        - If the user asks to "review", "assess", "evaluate", "analyze quality of" code → codeReview
        - If the user asks to "build", "implement", "create", "write" code → coding
        
        Other profiles:
        - "testing" for writing tests, test coverage, TDD
        - "debugging" for bug hunting, root cause analysis, investigating issues
        - "security" for vulnerability analysis, security audits, secure coding
        - "refactoring" for code improvement without behavior change, addressing code smells
        - "devops" for infrastructure, deployment, CI/CD, shell scripts
        - "documentation" for README, docs, comments, API documentation
        - "productManagement" for requirements, user stories, acceptance criteria
        - "general" for mixed tasks or when unsure
        """
    }
}
