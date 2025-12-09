import Foundation
import os.log

private let generatorLogger = Logger(subsystem: "com.termai.app", category: "SuggestionGenerator")

/// Generates and validates command suggestions
struct SuggestionGenerator {
    
    // MARK: - Generation
    
    /// Generate suggestions based on the plan
    static func generateSuggestionsFromPlan(
        plan: SuggestionPlan,
        gathered: GatheredContext,
        envContext: EnvironmentContext,
        terminalContext: TerminalContext,
        researchFindings: ResearchFindings,
        provider: ProviderType,
        modelId: String
    ) async throws -> [CommandSuggestion] {
        // Build the generation prompt based on plan type
        var prompt = """
        Generate \(plan.suggestionCount) helpful terminal command suggestions.
        
        USER CONTEXT:
        - Intent: \(plan.userIntent)
        - Current directory: \(terminalContext.cwd)
        """
        
        // Add command history patterns (shows what user actually uses)
        if !gathered.frequentCommandsFormatted.isEmpty {
            prompt += "\n- Frequently used: \(gathered.frequentCommandsFormatted)"
        }
        if !gathered.recentCommands.isEmpty {
            prompt += "\n- Recent: \(gathered.recentCommands.prefix(5).joined(separator: ", "))"
        }
        
        // Add research findings if available (AI-discovered context about the project)
        let researchFormatted = researchFindings.formattedForPrompt
        if !researchFormatted.isEmpty {
            prompt += "\n\n\(researchFormatted)"
        }
        
        // Add type-specific context
        switch plan.suggestionType {
        case "error_fix":
            prompt += """
            
            
            🔴 THE LAST COMMAND FAILED (exit code \(terminalContext.lastExitCode))
            Terminal output:
            ```
            \(String(terminalContext.lastOutput.prefix(500)))
            ```
            
            Suggest commands to FIX this error. Be specific about what went wrong.
            """
            
        case "git_workflow":
            if let git = terminalContext.gitInfo {
                prompt += """
                
                
                Git status: branch=\(git.branch), dirty=\(git.isDirty), ahead=\(git.ahead), behind=\(git.behind)
                
                Suggest appropriate git workflow commands.
                """
            }
            
        case "next_step":
            prompt += """
            
            
            Recent commands: \(gathered.recentCommands.prefix(5).joined(separator: ", "))
            
            Suggest the logical next step in their workflow.
            """
            
        case "history_based":
            prompt += """
            
            
            User's frequent commands (filtered for this context): \(gathered.frequentCommandsFormatted)
            
            The user just opened their terminal or is idle. Suggest commands from their frequent usage patterns
            that make sense for the current directory context. Focus on what they commonly do.
            """
            
        default:
            prompt += """
            
            
            Environment: \(envContext.formattedForPrompt)
            Recent: \(gathered.recentCommands.prefix(3).joined(separator: ", "))
            
            Suggest useful commands based on their context.
            """
        }
        
        if let focus = plan.focusArea {
            prompt += "\n\nFocus on: \(focus)"
        }
        
        // Detect if we're in home directory or a non-project directory
        let isHomeDir = terminalContext.cwd == FileManager.default.homeDirectoryForCurrentUser.path
        let hasProjectFiles = envContext.projectType != .unknown || !envContext.projectTechnologies.isEmpty
        
        prompt += """
        
        
        ⚠️ CRITICAL - CURRENT DIRECTORY RULES:
        - Current directory: \(terminalContext.cwd)
        - Is home directory: \(isHomeDir)
        - Has project files: \(hasProjectFiles)
        
        ONLY suggest commands that can ACTUALLY RUN from the current directory!
        - NEVER suggest "cd \(terminalContext.cwd)" or any path that resolves to the current directory - the user is ALREADY THERE!
        - If in home directory with no project files, suggest navigation or general commands
        - Do NOT suggest project commands (npm, cargo, swift build, etc.) unless project files exist HERE
        - Do NOT suggest commands that require being in a different directory
        - If suggesting cd, only suggest cd to a DIFFERENT directory than "\(terminalContext.cwd)"
        
        OTHER RULES:
        - Keep reasons brief (max 6 words)
        - Don't suggest generic commands like 'ls', 'pwd', 'clear'
        
        Reply as JSON array:
        [{"command": "exact command", "reason": "brief reason", "source": "errorAnalysis|gitStatus|projectContext|generalContext"}]
        """
        
        // Use configurable reasoning effort from settings
        let reasoningEffort = AgentSettings.shared.terminalSuggestionsReasoningEffort
        
        let response = try await LLMClient.shared.complete(
            systemPrompt: "You are a helpful terminal assistant. You MUST only suggest commands that work in the user's CURRENT directory. Never suggest project-specific commands unless the user is actually in a project directory.",
            userPrompt: prompt,
            provider: provider,
            modelId: modelId,
            reasoningEffort: reasoningEffort,
            maxTokens: 500,
            timeout: 30,
            requestType: .terminalSuggestion
        )
        
        let suggestions = parseSuggestions(from: response)
        
        // Validate suggestions against CWD
        return validateSuggestionsForCWD(suggestions, cwd: terminalContext.cwd, envContext: envContext)
    }
    
    // MARK: - Parsing
    
    /// Parse suggestions from AI response
    static func parseSuggestions(from response: String) -> [CommandSuggestion] {
        // Extract JSON array from response (handle markdown code blocks)
        var jsonString = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code block if present
        if jsonString.hasPrefix("```") {
            let lines = jsonString.components(separatedBy: "\n")
            var inCodeBlock = false
            var jsonLines: [String] = []
            
            for line in lines {
                if line.hasPrefix("```") {
                    inCodeBlock.toggle()
                    continue
                }
                if inCodeBlock {
                    jsonLines.append(line)
                }
            }
            jsonString = jsonLines.joined(separator: "\n")
        }
        
        // Find the JSON array in the response
        if let startIdx = jsonString.firstIndex(of: "["),
           let endIdx = jsonString.lastIndex(of: "]") {
            jsonString = String(jsonString[startIdx...endIdx])
        }
        
        guard let data = jsonString.data(using: .utf8) else { return [] }
        
        struct RawSuggestion: Decodable {
            let command: String
            let reason: String
            let source: String?
        }
        
        guard let raw = try? JSONDecoder().decode([RawSuggestion].self, from: data) else { return [] }
        
        return raw.prefix(3).compactMap { item in
            let source = SuggestionSource(rawValue: item.source ?? "generalContext") ?? .generalContext
            return CommandSuggestion(
                command: item.command,
                reason: String(item.reason.prefix(35)),  // Keep reasons concise
                confidence: 0.8,
                source: source
            )
        }
    }
    
    // MARK: - Validation
    
    /// Validate that suggestions make sense for the current working directory
    /// Filters out commands that require being in a specific directory
    static func validateSuggestionsForCWD(_ suggestions: [CommandSuggestion], cwd: String, envContext: EnvironmentContext) -> [CommandSuggestion] {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.path
        let isHomeDir = cwd == homeDir
        let hasProjectFiles = envContext.projectType != .unknown
        
        // Normalize CWD for comparison (resolve symlinks, remove trailing slash)
        let normalizedCWD = (cwd as NSString).standardizingPath
        
        // Commands that require being in a project directory
        let projectCommands = [
            "npm", "yarn", "pnpm", "npx",           // Node.js
            "cargo", "rustc",                        // Rust
            "swift build", "swift run", "swift test", // Swift
            "go build", "go run", "go test",         // Go
            "mvn", "gradle", "./gradlew",            // Java
            "dotnet build", "dotnet run",            // .NET
            "bundle", "rake", "rails",               // Ruby
            "pip install -r", "pytest",              // Python (project-specific)
            "make", "./configure"                    // Build systems
        ]
        
        return suggestions.filter { suggestion in
            let cmd = suggestion.command.lowercased()
            
            // Filter out "cd" commands that would cd into the current directory
            if cmd.hasPrefix("cd ") {
                let cdTarget = String(suggestion.command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                
                // Skip empty cd or just "cd" (goes to home)
                if cdTarget.isEmpty || cdTarget == "~" {
                    if normalizedCWD == (homeDir as NSString).standardizingPath {
                        generatorLogger.info("Filtered out '\(suggestion.command, privacy: .public)' - already in home directory")
                        return false
                    }
                } else {
                    // Expand ~ to home directory properly
                    let expandedTarget: String
                    if cdTarget.hasPrefix("~/") {
                        // ~/path → home + path (without the ~/)
                        expandedTarget = (homeDir as NSString).appendingPathComponent(String(cdTarget.dropFirst(2)))
                    } else if cdTarget.hasPrefix("~") {
                        // ~username style (rare) - just use as is
                        expandedTarget = cdTarget
                    } else if cdTarget.hasPrefix("/") {
                        // Absolute path
                        expandedTarget = cdTarget
                    } else if cdTarget.hasPrefix("./") {
                        // Explicit relative path
                        expandedTarget = (cwd as NSString).appendingPathComponent(String(cdTarget.dropFirst(2)))
                    } else if cdTarget == "." {
                        // Current directory
                        generatorLogger.debug("Filtered out '\(suggestion.command)' - cd to current directory")
                        return false
                    } else if cdTarget == ".." {
                        // Parent directory - don't filter
                        expandedTarget = (cwd as NSString).deletingLastPathComponent
                    } else {
                        // Relative path - resolve from CWD
                        expandedTarget = (cwd as NSString).appendingPathComponent(cdTarget)
                    }
                    
                    let normalizedTarget = (expandedTarget as NSString).standardizingPath
                    
                    generatorLogger.debug("CD filter: target='\(cdTarget, privacy: .public)' expanded='\(expandedTarget, privacy: .public)' normalized='\(normalizedTarget, privacy: .public)' cwd='\(normalizedCWD, privacy: .public)'")
                    
                    if normalizedTarget == normalizedCWD {
                        generatorLogger.info("Filtered out '\(suggestion.command, privacy: .public)' - already in that directory (target: \(normalizedTarget, privacy: .public))")
                        return false
                    }
                }
            } else if cmd == "cd" {
                // Just "cd" with no args goes to home
                if normalizedCWD == (homeDir as NSString).standardizingPath {
                    return false
                }
            }
            
            // If we're in home directory with no project, filter out project commands
            if isHomeDir && !hasProjectFiles {
                for projectCmd in projectCommands {
                    if cmd.hasPrefix(projectCmd.lowercased()) {
                        generatorLogger.debug("Filtered out '\(suggestion.command)' - project command in home dir")
                        return false
                    }
                }
            }
            
            // Check if command references a file that should exist
            // e.g., "cat README.md" - check if README.md exists
            let parts = suggestion.command.components(separatedBy: " ")
            if parts.count >= 2 {
                let potentialPath = parts.last ?? ""
                // Only check if it looks like a relative path (not a flag or URL)
                if !potentialPath.hasPrefix("-") && !potentialPath.contains("://") && !potentialPath.hasPrefix("$") {
                    let fullPath = (cwd as NSString).appendingPathComponent(potentialPath)
                    // If it looks like a specific file reference, check if it exists
                    if potentialPath.contains(".") || potentialPath.contains("/") {
                        if !fm.fileExists(atPath: fullPath) && !fm.fileExists(atPath: potentialPath) {
                            // File doesn't exist - but allow commands that might create files
                            let creationCommands = ["touch", "mkdir", "echo", "cat >", "vim", "nano", "code"]
                            let isCreationCmd = creationCommands.contains { cmd.hasPrefix($0) }
                            if !isCreationCmd {
                                generatorLogger.debug("Filtered out '\(suggestion.command)' - references non-existent path")
                                return false
                            }
                        }
                    }
                }
            }
            
            return true
        }
    }
}
