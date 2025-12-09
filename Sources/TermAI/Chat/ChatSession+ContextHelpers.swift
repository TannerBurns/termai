import Foundation
import TermAIModels

// MARK: - Quick Environment Context

extension ChatSession {
    
    /// Represents quick environment context for agent decision-making
    struct QuickEnvironmentContext {
        let cwd: String
        let directoryContents: [String]
        let gitBranch: String?
        let gitDirty: Bool
        let projectType: String
        
        /// Format context for inclusion in prompts
        func formatted() -> String {
            var lines: [String] = []
            
            lines.append("- Current Directory: \(cwd.isEmpty ? "(unknown)" : cwd)")
            
            if !directoryContents.isEmpty {
                let contents = directoryContents.prefix(20).joined(separator: ", ")
                let suffix = directoryContents.count > 20 ? ", ..." : ""
                lines.append("- Directory Contents: \(contents)\(suffix)")
            }
            
            if let branch = gitBranch {
                let dirtyIndicator = gitDirty ? " (uncommitted changes)" : ""
                lines.append("- Git: branch '\(branch)'\(dirtyIndicator)")
            }
            
            if !projectType.isEmpty && projectType != "unknown" {
                lines.append("- Project Type: \(projectType)")
            }
            
            return lines.joined(separator: "\n")
        }
    }
    
    /// Gather quick environment context for agent decision-making
    /// This provides the agent with enough context to make informed RESPOND vs RUN decisions
    func gatherQuickContext() async -> QuickEnvironmentContext {
        let cwd = lastKnownCwd.isEmpty ? FileManager.default.currentDirectoryPath : lastKnownCwd
        
        // Get directory contents (top-level only, quick)
        var directoryContents: [String] = []
        if !cwd.isEmpty {
            let url = URL(fileURLWithPath: cwd)
            if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                directoryContents = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item in
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return item.lastPathComponent + (isDir ? "/" : "")
                }
            }
        }
        
        // Get git info asynchronously
        var gitBranch: String? = nil
        var gitDirty = false
        if !cwd.isEmpty {
            if let gitInfo = await GitInfoService.shared.fetchGitInfo(for: cwd) {
                gitBranch = gitInfo.branch
                gitDirty = gitInfo.isDirty
            }
        }
        
        // Detect project type from common files
        let projectType = ProjectTypeDetector.detect(from: directoryContents)
        
        return QuickEnvironmentContext(
            cwd: cwd,
            directoryContents: directoryContents,
            gitBranch: gitBranch,
            gitDirty: gitDirty,
            projectType: projectType
        )
    }
    
    /// Summarize context when it exceeds size limits
    /// Uses token estimation with 95% threshold for more accurate context management
    func summarizeContext(_ contextLog: [String], maxSize: Int) async -> String {
        let fullContext = contextLog.joined(separator: "\n")
        
        // Calculate limits using model-specific token estimation with 95% threshold
        let currentTokens = TokenEstimator.estimateTokens(fullContext, model: model)
        let tokenThreshold = Int(Double(effectiveContextLimit) * 0.95)
        let maxChars = maxSize
        
        // Use token-based limit as primary, with character limit as fallback
        let charsPerTokenRatio = TokenEstimator.charsPerToken(for: model)
        let tokenBasedCharLimit = Int(Double(tokenThreshold) * charsPerTokenRatio)
        let effectiveLimit = min(maxChars, tokenBasedCharLimit)
        
        // If already under 95% threshold, return as-is
        if currentTokens <= tokenThreshold {
            return fullContext
        }
        
        // Record that summarization is occurring
        await MainActor.run { recordSummarization() }
        
        // Keep most recent entries intact (preserve more if model supports larger context)
        let recentCount = min(contextLog.count, effectiveContextLimit > 100_000 ? 15 : 10)
        let recentEntries = contextLog.suffix(recentCount)
        let olderEntries = contextLog.dropLast(recentCount)
        
        if olderEntries.isEmpty {
            // All entries are recent, just truncate
            return String(fullContext.suffix(effectiveLimit))
        }
        
        // Summarize older entries
        let olderText = olderEntries.joined(separator: "\n")
        let olderLimit = min(olderText.count, effectiveLimit / 2)
        
        let summarizePrompt = """
        Summarize the following agent execution context, preserving:
        - Key commands that were run and their outcomes
        - Important errors or warnings
        - Significant progress milestones
        - Current state information
        Be concise but preserve critical information.
        
        CONTEXT TO SUMMARIZE:
        \(String(olderText.prefix(olderLimit)))
        """
        
        let summary = await callOneShotText(prompt: summarizePrompt)
        let summarized = "[SUMMARIZED HISTORY]\n\(summary)\n\n[RECENT ACTIVITY]\n\(recentEntries.joined(separator: "\n"))"
        
        // Update context usage after summarization
        await MainActor.run { updateContextUsage() }
        
        return String(summarized.suffix(effectiveLimit))
    }
    
    /// Summarize long command output
    func summarizeOutput(_ output: String, command: String) async -> String {
        let settings = AgentSettings.shared
        let dynamicLimit = effectiveOutputCaptureLimit
        
        // If output is short enough, return as-is
        if output.count <= dynamicLimit {
            return output
        }
        
        // If summarization is disabled, use smart truncation instead
        if !settings.enableOutputSummarization || output.count <= settings.outputSummarizationThreshold {
            return SmartTruncator.smartTruncate(output, maxChars: dynamicLimit, context: .commandOutput)
        }
        
        // Use smart truncation to get the most relevant portion for summarization
        let truncatedForSummary = SmartTruncator.prioritizeErrors(output, maxChars: dynamicLimit)
        
        // Summarize the output
        let summarizePrompt = """
        Summarize this command output concisely, preserving:
        - Errors and warnings (quote exact error messages)
        - Key results/data
        - File paths mentioned
        - Success/failure indicators
        - Any actionable information
        
        COMMAND: \(command)
        OUTPUT (smart truncated from \(output.count) total chars):
        \(truncatedForSummary)
        """
        
        let summary = await callOneShotText(prompt: summarizePrompt)
        return "[SUMMARIZED OUTPUT from '\(command)' (\(output.count) chars)]\n\(summary)"
    }
    
    func lastExitCodeString() -> String {
        // We don't have direct access to PTYModel here; rely on last recorded value from context if present.
        // Look for "EXIT_CODE: N" pattern and extract just the number
        for line in agentContextLog.reversed() {
            if let range = line.range(of: "EXIT_CODE: ") {
                // Extract only the numeric characters immediately following the marker
                var numStr = ""
                var idx = range.upperBound
                while idx < line.endIndex {
                    let char = line[idx]
                    if char.isNumber || (numStr.isEmpty && char == "-") {
                        numStr.append(char)
                    } else {
                        break  // Stop at first non-numeric character
                    }
                    idx = line.index(after: idx)
                }
                if !numStr.isEmpty {
                    return numStr
                }
            }
        }
        return "unknown"
    }
}
