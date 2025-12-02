import Foundation
import os.log

private let historyLogger = Logger(subsystem: "com.termai.app", category: "ShellHistory")

// MARK: - Shell Type Detection

/// Detected shell type
enum ShellType: String {
    case zsh
    case bash
    case fish
    case unknown
    
    /// History file path for this shell
    var historyFilePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .zsh:
            // Check for custom HISTFILE first, fallback to default
            if let customPath = ProcessInfo.processInfo.environment["HISTFILE"] {
                return customPath
            }
            return "\(home)/.zsh_history"
        case .bash:
            return "\(home)/.bash_history"
        case .fish:
            return "\(home)/.local/share/fish/fish_history"
        case .unknown:
            // Try common fallback
            return "\(home)/.histfile"
        }
    }
}

// MARK: - Parsed History Entry

/// A parsed command from shell history
struct ShellHistoryEntry {
    let command: String
    let timestamp: Date?
    let workingDirectory: String?  // Only available in some shells with extended history
    
    init(command: String, timestamp: Date? = nil, workingDirectory: String? = nil) {
        self.command = command
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
    }
}

// MARK: - Command Frequency Data

/// Aggregated frequency data for a command
struct CommandFrequency: Comparable {
    let command: String
    let count: Int
    let lastUsed: Date?
    
    static func < (lhs: CommandFrequency, rhs: CommandFrequency) -> Bool {
        // Sort by count descending, then by lastUsed descending
        if lhs.count != rhs.count {
            return lhs.count > rhs.count
        }
        if let lhsDate = lhs.lastUsed, let rhsDate = rhs.lastUsed {
            return lhsDate > rhsDate
        }
        return lhs.lastUsed != nil
    }
}

/// Statistics about the user's shell history for context gathering
struct HistoryStats {
    let totalEntries: Int
    let uniqueCommands: Int
    let topCommandGroups: [(key: String, value: Int)]  // Base command -> count
    let recentCommands: [String]
    let shellType: ShellType
    
    /// Formatted summary for AI prompts
    var formattedSummary: String {
        var parts: [String] = []
        
        parts.append("Shell: \(shellType.rawValue), \(totalEntries) history entries, \(uniqueCommands) unique commands")
        
        if !topCommandGroups.isEmpty {
            let topFormatted = topCommandGroups.prefix(10).map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
            parts.append("Top commands: \(topFormatted)")
        }
        
        if !recentCommands.isEmpty {
            parts.append("Recent: \(recentCommands.prefix(5).joined(separator: ", "))")
        }
        
        return parts.joined(separator: "\n")
    }
}

// MARK: - Shell History Parser

/// Parses shell history files to extract command frequency data
/// Thread-safe: all cache access is synchronized via a serial queue
final class ShellHistoryParser {
    static let shared = ShellHistoryParser()
    
    // MARK: - Cache
    
    private var cachedEntries: [ShellHistoryEntry] = []
    private var cachedFrequencies: [CommandFrequency] = []
    private var cacheTimestamp: Date?
    private let cacheExpirationSeconds: TimeInterval = 300  // 5 minutes
    
    /// Serial queue for thread-safe cache access
    private let cacheQueue = DispatchQueue(label: "com.termai.shellhistoryparser.cache")
    
    /// Background queue for parsing (to avoid blocking UI)
    private let parseQueue = DispatchQueue(label: "com.termai.shellhistoryparser.parse", qos: .utility)
    
    /// Flag to track if a parse is in progress
    private var isParsingInProgress = false
    
    // MARK: - Configuration
    
    /// Maximum number of history entries to parse (to avoid memory issues with huge history files)
    private let maxEntriesToParse = 10_000
    
    /// Commands to filter out from suggestions
    private let trivialCommands: Set<String> = [
        "cd", "ls", "ll", "la", "pwd", "clear", "exit", "quit",
        "history", "which", "whoami", "date", "cal", "true", "false",
        "echo", "printf", "cat", "less", "more", "head", "tail",
        "man", "help", "alias", "unalias", "export", "source"
    ]
    
    private init() {}
    
    // MARK: - Public API
    
    /// Detect the user's shell type from $SHELL environment variable
    func detectShellType() -> ShellType {
        guard let shellPath = ProcessInfo.processInfo.environment["SHELL"] else {
            return .unknown
        }
        
        let shellName = (shellPath as NSString).lastPathComponent.lowercased()
        
        if shellName.contains("zsh") {
            return .zsh
        } else if shellName.contains("bash") {
            return .bash
        } else if shellName.contains("fish") {
            return .fish
        }
        
        return .unknown
    }
    
    /// Get the path to the user's shell history file
    func getHistoryFilePath() -> String? {
        let shellType = detectShellType()
        historyLogger.info("Detected shell type: \(shellType.rawValue)")
        
        guard let path = shellType.historyFilePath else { 
            historyLogger.warning("No history path for shell type: \(shellType.rawValue)")
            return nil 
        }
        
        historyLogger.info("Checking history path: \(path)")
        
        // Verify file exists
        if FileManager.default.fileExists(atPath: path) {
            historyLogger.info("Found history file at: \(path)")
            return path
        }
        
        historyLogger.warning("History file not found at expected path: \(path)")
        
        // Try fallback paths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbacks = [
            "\(home)/.zsh_history",
            "\(home)/.bash_history",
            "\(home)/.histfile"
        ]
        
        for fallback in fallbacks {
            historyLogger.debug("Trying fallback: \(fallback)")
            if FileManager.default.fileExists(atPath: fallback) {
                historyLogger.info("Found history file at fallback: \(fallback)")
                return fallback
            }
        }
        
        historyLogger.error("No history file found in any location")
        return nil
    }
    
    /// Parse shell history and return frequent commands
    /// - Parameter limit: Maximum number of commands to return
    /// - Returns: Array of frequently used commands sorted by frequency (from cache, triggers async refresh if stale)
    func getFrequentCommands(limit: Int = 10) -> [CommandFrequency] {
        return cacheQueue.sync {
            // Check cache validity
            if let timestamp = cacheTimestamp,
               Date().timeIntervalSince(timestamp) < cacheExpirationSeconds,
               !cachedFrequencies.isEmpty {
                return Array(cachedFrequencies.prefix(limit))
            }
            
            // Return current cache (even if stale) and trigger async refresh
            let result = Array(cachedFrequencies.prefix(limit))
            triggerAsyncParse()
            return result
        }
    }
    
    /// Get frequent commands filtered for a specific directory
    /// Only works for zsh with extended history format that includes directory info
    func getFrequentCommands(for directory: String, limit: Int = 5) -> [CommandFrequency] {
        return cacheQueue.sync {
            // Check cache validity and trigger refresh if needed
            if cacheTimestamp == nil || Date().timeIntervalSince(cacheTimestamp!) >= cacheExpirationSeconds {
                triggerAsyncParse()
            }
            
            // Filter entries by directory
            let normalizedDir = normalizePath(directory)
            let directoryEntries = cachedEntries.filter { entry in
                guard let entryDir = entry.workingDirectory else { return false }
                return normalizePath(entryDir) == normalizedDir
            }
            
            // Build frequency map for this directory
            var counts: [String: (count: Int, lastUsed: Date?)] = [:]
            for entry in directoryEntries {
                let cmd = normalizeCommand(entry.command)
                guard shouldIncludeCommand(cmd) else { continue }
                
                let current = counts[cmd] ?? (0, nil)
                let newLastUsed: Date?
                if let entryTime = entry.timestamp, let currentTime = current.lastUsed {
                    newLastUsed = entryTime > currentTime ? entryTime : currentTime
                } else {
                    newLastUsed = entry.timestamp ?? current.lastUsed
                }
                counts[cmd] = (current.count + 1, newLastUsed)
            }
            
            // Convert to array and sort
            let frequencies = counts.map { CommandFrequency(command: $0.key, count: $0.value.count, lastUsed: $0.value.lastUsed) }
            return Array(frequencies.sorted().prefix(limit))
        }
    }
    
    /// Check if shell history parsing is available
    func isAvailable() -> Bool {
        return getHistoryFilePath() != nil
    }
    
    /// Get formatted history context for the suggestion pipeline
    /// Returns a tuple of (frequentCommandsFormatted, recentCommands)
    /// - frequentCommandsFormatted: "git (42), npm (28), docker (15), ..."
    /// - recentCommands: Array of last N commands
    func getFormattedHistoryContext(topN: Int = 10, recentN: Int = 10) -> (frequentFormatted: String, recent: [String]) {
        // Check if cache needs refresh OUTSIDE the sync block to avoid deadlock
        let (needsRefresh, cacheIsEmpty) = cacheQueue.sync { () -> (Bool, Bool) in
            let stale = cacheTimestamp == nil || Date().timeIntervalSince(cacheTimestamp!) >= cacheExpirationSeconds
            let empty = cachedEntries.isEmpty
            return (stale, empty)
        }
        
        if needsRefresh {
            if cacheIsEmpty {
                // First time - parse synchronously so we have data to return
                parseHistorySynchronously()
            } else {
                // Cache exists but stale - refresh in background
                triggerAsyncParse()
            }
        }
        
        return cacheQueue.sync {
            // Format top N frequent commands with counts
            let topCommands = cachedFrequencies.prefix(topN)
            let frequentFormatted: String
            if topCommands.isEmpty {
                frequentFormatted = "(no history available)"
            } else {
                frequentFormatted = topCommands.map { freq in
                    // Use full command (truncate if very long)
                    let cmd = freq.command.count > 50 ? String(freq.command.prefix(47)) + "..." : freq.command
                    return "\(cmd) (\(freq.count))"
                }.joined(separator: ", ")
            }
            
            // Get recent N commands (most recent first)
            let recentCommands = cachedEntries.suffix(recentN).reversed().map { $0.command }
            
            return (frequentFormatted, Array(recentCommands))
        }
    }
    
    /// Synchronous parse for initial population when cache is empty
    /// This blocks but ensures we have data to return
    private func parseHistorySynchronously() {
        // Use parseQueue.sync to wait for completion
        parseQueue.sync { [weak self] in
            self?.parseHistoryAsync()
        }
    }
    
    /// Get detailed history statistics for context
    /// Returns structured data for the suggestion pipeline
    func getHistoryStats() -> HistoryStats {
        // Check if cache needs refresh OUTSIDE the sync block to avoid deadlock
        let (needsRefresh, cacheIsEmpty) = cacheQueue.sync { () -> (Bool, Bool) in
            let stale = cacheTimestamp == nil || Date().timeIntervalSince(cacheTimestamp!) >= cacheExpirationSeconds
            let empty = cachedEntries.isEmpty
            return (stale, empty)
        }
        
        if needsRefresh {
            if cacheIsEmpty {
                // First time - parse synchronously so we have data to return
                parseHistorySynchronously()
            } else {
                // Cache exists but stale - refresh in background
                triggerAsyncParse()
            }
        }
        
        return cacheQueue.sync {
            // Count commands by base command
            var commandGroups: [String: Int] = [:]
            for freq in cachedFrequencies {
                let baseCmd = freq.command.components(separatedBy: " ").first ?? freq.command
                commandGroups[baseCmd, default: 0] += freq.count
            }
            
            // Sort by frequency
            let sortedGroups = commandGroups.sorted { $0.value > $1.value }
            
            return HistoryStats(
                totalEntries: cachedEntries.count,
                uniqueCommands: cachedFrequencies.count,
                topCommandGroups: Array(sortedGroups.prefix(15)),
                recentCommands: Array(cachedEntries.suffix(10).reversed().map { $0.command }),
                shellType: detectShellType()
            )
        }
    }
    
    /// Force refresh the cache asynchronously
    func refreshCache() {
        cacheQueue.async { [weak self] in
            self?.cacheTimestamp = nil
        }
        triggerAsyncParse()
    }
    
    /// Get info about the history file for display in settings
    /// Note: This performs synchronous file I/O - use sparingly
    func getHistoryFileInfo() -> (path: String, shellType: ShellType, entryCount: Int)? {
        historyLogger.info("getHistoryFileInfo called")
        
        guard let path = getHistoryFilePath() else { 
            historyLogger.warning("getHistoryFileInfo: no path returned")
            return nil 
        }
        let shellType = detectShellType()
        
        // Quick line count - read only a portion for large files
        guard let handle = FileHandle(forReadingAtPath: path) else { 
            historyLogger.error("getHistoryFileInfo: failed to open file handle for: \(path)")
            return nil 
        }
        defer { try? handle.close() }
        
        // Read up to 1MB to estimate line count
        let maxReadSize = 1024 * 1024
        guard let data = try? handle.read(upToCount: maxReadSize) else {
            historyLogger.error("getHistoryFileInfo: failed to read data from: \(path)")
            return nil
        }
        
        // Try multiple encodings - zsh history can sometimes have non-UTF8 characters
        var content: String? = String(data: data, encoding: .utf8)
        if content == nil {
            historyLogger.debug("UTF8 decoding failed, trying ISO Latin 1")
            content = String(data: data, encoding: .isoLatin1)
        }
        if content == nil {
            historyLogger.debug("ISO Latin 1 failed, trying ASCII")
            content = String(data: data, encoding: .ascii)
        }
        
        guard let fileContent = content else { 
            historyLogger.error("getHistoryFileInfo: failed to decode content from: \(path)")
            return nil 
        }
        
        let lineCount = fileContent.components(separatedBy: .newlines).count
        historyLogger.info("getHistoryFileInfo: found \(lineCount) lines in history file")
        
        // If we read less than the max, this is the actual count
        // Otherwise, estimate based on file size
        if data.count < maxReadSize {
            return (path, shellType, lineCount)
        } else {
            // Estimate: extrapolate from sample
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let fileSize = (attributes?[.size] as? Int) ?? data.count
            let estimatedLines = Int(Double(lineCount) * Double(fileSize) / Double(data.count))
            return (path, shellType, estimatedLines)
        }
    }
    
    /// Trigger async parsing if not already in progress
    /// Thread-safe: can be called from any queue
    private func triggerAsyncParse() {
        // Check and set flag atomically using cacheQueue
        let shouldParse = cacheQueue.sync { () -> Bool in
            guard !isParsingInProgress else { return false }
            isParsingInProgress = true
            return true
        }
        
        guard shouldParse else { return }
        
        parseQueue.async { [weak self] in
            self?.parseHistoryAsync()
        }
    }
    
    // MARK: - Private Parsing Methods
    
    /// Async version of parseHistory - called on parseQueue
    private func parseHistoryAsync() {
        defer {
            cacheQueue.async { [weak self] in
                self?.isParsingInProgress = false
            }
        }
        
        guard let historyPath = getHistoryFilePath() else {
            cacheQueue.async { [weak self] in
                self?.cachedEntries = []
                self?.cachedFrequencies = []
                self?.cacheTimestamp = Date()
            }
            return
        }
        
        let shellType = detectShellType()
        
        // Try multiple encodings - zsh history can have non-UTF8 characters
        var content: String?
        
        // Try UTF-8 first
        content = try? String(contentsOfFile: historyPath, encoding: .utf8)
        
        // Fallback to ISO Latin 1
        if content == nil {
            historyLogger.debug("UTF8 failed for history parsing, trying ISO Latin 1")
            content = try? String(contentsOfFile: historyPath, encoding: .isoLatin1)
        }
        
        // Fallback to reading raw data and filtering invalid bytes
        if content == nil {
            historyLogger.debug("ISO Latin 1 failed, trying raw data with lossy conversion")
            if let data = FileManager.default.contents(atPath: historyPath) {
                content = String(data: data, encoding: .utf8) 
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? String(decoding: data, as: UTF8.self)  // Lossy conversion
            }
        }
        
        guard let fileContent = content else {
            historyLogger.error("Failed to read history file with any encoding: \(historyPath)")
            cacheQueue.async { [weak self] in
                self?.cachedEntries = []
                self?.cachedFrequencies = []
                self?.cacheTimestamp = Date()
            }
            return
        }
        
        let entries: [ShellHistoryEntry]
        switch shellType {
        case .zsh:
            entries = parseZshHistory(fileContent)
        case .bash:
            entries = parseBashHistory(fileContent)
        case .fish:
            entries = parseFishHistory(fileContent)
        case .unknown:
            // Try zsh format first, fallback to bash
            let zshEntries = parseZshHistory(fileContent)
            entries = zshEntries.isEmpty ? parseBashHistory(fileContent) : zshEntries
        }
        
        historyLogger.info("Parsed \(entries.count) history entries")
        
        // Build frequency map
        let frequencies = buildFrequencyMap(from: entries)
        historyLogger.info("Built frequency map with \(frequencies.count) unique commands")
        
        // Update cache thread-safely
        cacheQueue.async { [weak self] in
            self?.cachedEntries = entries
            self?.cachedFrequencies = frequencies
            self?.cacheTimestamp = Date()
        }
    }
    
    /// Parse zsh history file
    /// Format can be:
    /// - Simple: just commands
    /// - Extended: `: timestamp:duration;command`
    private func parseZshHistory(_ content: String) -> [ShellHistoryEntry] {
        var entries: [ShellHistoryEntry] = []
        let lines = content.components(separatedBy: .newlines)
        
        // Take only the most recent entries
        let linesToParse = lines.suffix(maxEntriesToParse)
        
        // Regex for zsh extended history format: ": timestamp:duration;command"
        let extendedPattern = try? NSRegularExpression(pattern: #"^: (\d+):\d+;(.+)$"#)
        
        var multilineCommand = ""
        var multilineTimestamp: Date?
        
        for line in linesToParse {
            // Handle continuation lines (ending with \)
            if !multilineCommand.isEmpty {
                if line.hasSuffix("\\") {
                    multilineCommand += "\n" + String(line.dropLast())
                    continue
                } else {
                    multilineCommand += "\n" + line
                    entries.append(ShellHistoryEntry(
                        command: multilineCommand,
                        timestamp: multilineTimestamp
                    ))
                    multilineCommand = ""
                    multilineTimestamp = nil
                    continue
                }
            }
            
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            
            // Try extended format first
            if let match = extendedPattern?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                if let timestampRange = Range(match.range(at: 1), in: line),
                   let commandRange = Range(match.range(at: 2), in: line) {
                    let timestampStr = String(line[timestampRange])
                    let command = String(line[commandRange])
                    
                    let timestamp: Date?
                    if let ts = TimeInterval(timestampStr) {
                        timestamp = Date(timeIntervalSince1970: ts)
                    } else {
                        timestamp = nil
                    }
                    
                    // Check for multiline
                    if command.hasSuffix("\\") {
                        multilineCommand = String(command.dropLast())
                        multilineTimestamp = timestamp
                        continue
                    }
                    
                    entries.append(ShellHistoryEntry(command: command, timestamp: timestamp))
                }
            } else {
                // Simple format - just the command
                let command = trimmed
                
                // Check for multiline
                if command.hasSuffix("\\") {
                    multilineCommand = String(command.dropLast())
                    continue
                }
                
                entries.append(ShellHistoryEntry(command: command))
            }
        }
        
        return entries
    }
    
    /// Parse bash history file (simple format: one command per line)
    private func parseBashHistory(_ content: String) -> [ShellHistoryEntry] {
        var entries: [ShellHistoryEntry] = []
        let lines = content.components(separatedBy: .newlines)
        
        // Take only the most recent entries
        let linesToParse = lines.suffix(maxEntriesToParse)
        
        // Bash with HISTTIMEFORMAT might have timestamps as comments: #timestamp
        var pendingTimestamp: Date?
        
        for line in linesToParse {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            
            // Check for timestamp comment
            if trimmed.hasPrefix("#") {
                let timestampStr = String(trimmed.dropFirst())
                if let ts = TimeInterval(timestampStr) {
                    pendingTimestamp = Date(timeIntervalSince1970: ts)
                }
                continue
            }
            
            entries.append(ShellHistoryEntry(command: trimmed, timestamp: pendingTimestamp))
            pendingTimestamp = nil
        }
        
        return entries
    }
    
    /// Parse fish history file (YAML-like format)
    private func parseFishHistory(_ content: String) -> [ShellHistoryEntry] {
        var entries: [ShellHistoryEntry] = []
        let lines = content.components(separatedBy: .newlines)
        
        var currentCommand: String?
        var currentTimestamp: Date?
        
        for line in lines.suffix(maxEntriesToParse * 3) {  // Fish has multiple lines per entry
            if line.hasPrefix("- cmd: ") {
                // Save previous entry
                if let cmd = currentCommand {
                    entries.append(ShellHistoryEntry(command: cmd, timestamp: currentTimestamp))
                }
                currentCommand = String(line.dropFirst(7))
                currentTimestamp = nil
            } else if line.hasPrefix("  when: ") {
                let timestampStr = String(line.dropFirst(8))
                if let ts = TimeInterval(timestampStr) {
                    currentTimestamp = Date(timeIntervalSince1970: ts)
                }
            }
        }
        
        // Don't forget the last entry
        if let cmd = currentCommand {
            entries.append(ShellHistoryEntry(command: cmd, timestamp: currentTimestamp))
        }
        
        return Array(entries.suffix(maxEntriesToParse))
    }
    
    /// Build frequency map from parsed entries
    private func buildFrequencyMap(from entries: [ShellHistoryEntry]) -> [CommandFrequency] {
        var counts: [String: (count: Int, lastUsed: Date?)] = [:]
        
        for entry in entries {
            let cmd = normalizeCommand(entry.command)
            guard shouldIncludeCommand(cmd) else { continue }
            
            let current = counts[cmd] ?? (0, nil)
            let newLastUsed: Date?
            if let entryTime = entry.timestamp, let currentTime = current.lastUsed {
                newLastUsed = entryTime > currentTime ? entryTime : currentTime
            } else {
                newLastUsed = entry.timestamp ?? current.lastUsed
            }
            counts[cmd] = (current.count + 1, newLastUsed)
        }
        
        // Convert to array and sort
        return counts
            .map { CommandFrequency(command: $0.key, count: $0.value.count, lastUsed: $0.value.lastUsed) }
            .sorted()
    }
    
    // MARK: - Helpers
    
    /// Normalize command for comparison (trim, collapse whitespace)
    private func normalizeCommand(_ command: String) -> String {
        return command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    
    /// Normalize path for comparison
    private func normalizePath(_ path: String) -> String {
        var normalized = path
        if normalized.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            normalized = home + normalized.dropFirst()
        }
        if normalized.hasSuffix("/") && normalized.count > 1 {
            normalized = String(normalized.dropLast())
        }
        return normalized
    }
    
    /// Check if a command should be included in suggestions
    private func shouldIncludeCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Skip empty or very short commands
        guard trimmed.count >= 2 else { return false }
        
        // Extract the base command (first word)
        let baseCommand = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        
        // Skip trivial commands without arguments
        if trivialCommands.contains(baseCommand.lowercased()) && !trimmed.contains(" ") {
            return false
        }
        
        // Skip commands that are just changing directory without useful args
        if baseCommand == "cd" {
            let args = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            // Skip cd with no args, ~, -, .., or single dots
            if args.isEmpty || args == "~" || args == "-" || args == ".." || args == "." {
                return false
            }
        }
        
        return true
    }
}

