import Foundation

// MARK: - Data Models

/// A single command execution entry
struct CommandEntry: Codable, Equatable {
    let command: String
    let timestamp: Date
    let exitCode: Int32
    let executionTime: TimeInterval?
    
    init(command: String, exitCode: Int32 = 0, executionTime: TimeInterval? = nil) {
        self.command = command
        self.timestamp = Date()
        self.exitCode = exitCode
        self.executionTime = executionTime
    }
}

/// Command history for a specific directory
struct DirectoryCommandHistory: Codable {
    let path: String
    var commands: [CommandEntry]
    var lastVisited: Date
    
    init(path: String) {
        self.path = path
        self.commands = []
        self.lastVisited = Date()
    }
    
    mutating func addCommand(_ entry: CommandEntry) {
        commands.append(entry)
        lastVisited = Date()
    }
}

// MARK: - Command History Store

/// Singleton store for persisting per-directory command history
/// Thread-safe: all access to histories is synchronized via a serial queue
final class CommandHistoryStore {
    static let shared = CommandHistoryStore()
    
    private var histories: [String: DirectoryCommandHistory] = [:]
    private let fileName = "command-history.json"
    private let maxEntriesPerDirectory = 500
    private let maxAgeDays = 30
    private let saveDebounceInterval: TimeInterval = 2.0
    private var saveTask: DispatchWorkItem?
    
    /// Serial queue for thread-safe access to histories dictionary
    private let queue = DispatchQueue(label: "com.termai.commandhistorystore")
    
    /// Key for detecting if we're already on the queue (to prevent deadlock)
    private static let queueKey = DispatchSpecificKey<Bool>()
    
    private init() {
        queue.setSpecific(key: Self.queueKey, value: true)
        loadFromDisk()
    }
    
    /// Check if we're currently executing on our queue
    private var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) == true
    }
    
    // MARK: - Public API
    
    /// Record a command execution for a directory
    func recordCommand(
        _ command: String,
        cwd: String,
        exitCode: Int32,
        executionTime: TimeInterval? = nil
    ) {
        // Normalize the path
        let normalizedPath = normalizePath(cwd)
        
        // Skip empty or trivial commands
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isTrivialCommand(trimmed) else { return }
        
        // Create entry
        let entry = CommandEntry(
            command: trimmed,
            exitCode: exitCode,
            executionTime: executionTime
        )
        
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Add to history
            if var history = self.histories[normalizedPath] {
                history.addCommand(entry)
                self.histories[normalizedPath] = history
            } else {
                var newHistory = DirectoryCommandHistory(path: normalizedPath)
                newHistory.addCommand(entry)
                self.histories[normalizedPath] = newHistory
            }
            
            // Prune if needed
            self.pruneHistoryIfNeeded(for: normalizedPath)
            
            // Schedule debounced save
            self.scheduleSave()
        }
    }
    
    /// Get recent commands for a directory
    func getRecentCommands(for cwd: String, limit: Int = 5) -> [CommandEntry] {
        let normalizedPath = normalizePath(cwd)
        
        return queue.sync {
            guard let history = histories[normalizedPath] else { return [] }
            
            // Return most recent commands, deduplicated by command string
            var seen = Set<String>()
            var result: [CommandEntry] = []
            
            for entry in history.commands.reversed() {
                if !seen.contains(entry.command) {
                    seen.insert(entry.command)
                    result.append(entry)
                    if result.count >= limit { break }
                }
            }
            
            return result
        }
    }
    
    /// Get the last successful command for a directory
    func getLastSuccessfulCommand(for cwd: String) -> CommandEntry? {
        let normalizedPath = normalizePath(cwd)
        
        return queue.sync {
            guard let history = histories[normalizedPath] else { return nil }
            return history.commands.last { $0.exitCode == 0 }
        }
    }
    
    /// Get frequently used commands for a directory
    func getFrequentCommands(for cwd: String, limit: Int = 3) -> [String] {
        let normalizedPath = normalizePath(cwd)
        
        return queue.sync {
            guard let history = histories[normalizedPath] else { return [] }
            
            // Count command occurrences
            var counts: [String: Int] = [:]
            for entry in history.commands {
                counts[entry.command, default: 0] += 1
            }
            
            // Sort by frequency and return top commands
            return counts
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { $0.key }
        }
    }
    
    /// Update the last visited timestamp for a directory
    func markVisited(_ cwd: String) {
        let normalizedPath = normalizePath(cwd)
        
        queue.async { [weak self] in
            guard let self = self else { return }
            if var history = self.histories[normalizedPath] {
                history.lastVisited = Date()
                self.histories[normalizedPath] = history
            }
        }
    }
    
    /// Check if we have any history for a directory
    func hasHistory(for cwd: String) -> Bool {
        let normalizedPath = normalizePath(cwd)
        
        return queue.sync {
            guard let history = histories[normalizedPath] else { return false }
            return !history.commands.isEmpty
        }
    }
    
    // MARK: - Private Helpers
    
    private func normalizePath(_ path: String) -> String {
        // Expand ~ and resolve symlinks for consistent keys
        var normalized = path
        if normalized.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            normalized = home + normalized.dropFirst()
        }
        // Remove trailing slash for consistency
        if normalized.hasSuffix("/") && normalized.count > 1 {
            normalized = String(normalized.dropLast())
        }
        return normalized
    }
    
    private func isTrivialCommand(_ command: String) -> Bool {
        // Skip single-letter commands, cd without args, clear, etc.
        let trivial = ["cd", "ls", "pwd", "clear", "exit", ""]
        let firstWord = command.split(separator: " ").first.map(String.init) ?? command
        return trivial.contains(firstWord) && !command.contains(" ")
    }
    
    private func pruneHistoryIfNeeded(for path: String) {
        guard var history = histories[path] else { return }
        
        // Remove entries older than maxAgeDays
        let cutoffDate = Date().addingTimeInterval(-Double(maxAgeDays) * 24 * 60 * 60)
        history.commands = history.commands.filter { $0.timestamp > cutoffDate }
        
        // Trim to maxEntriesPerDirectory (keep most recent)
        if history.commands.count > maxEntriesPerDirectory {
            history.commands = Array(history.commands.suffix(maxEntriesPerDirectory))
        }
        
        histories[path] = history
    }
    
    private func pruneAllHistories() {
        // Remove directories not visited in maxAgeDays
        let cutoffDate = Date().addingTimeInterval(-Double(maxAgeDays) * 24 * 60 * 60)
        histories = histories.filter { $0.value.lastVisited > cutoffDate }
        
        // Prune each remaining history
        for path in histories.keys {
            pruneHistoryIfNeeded(for: path)
        }
    }
    
    // MARK: - Persistence
    
    /// Schedule a debounced save (must be called from within the queue)
    private func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.performSave()
        }
        saveTask = task
        // Dispatch to the same queue after delay to maintain thread safety
        queue.asyncAfter(deadline: .now() + saveDebounceInterval, execute: task)
    }
    
    /// Actually perform the save operation (must be called from within the queue)
    private func performSave() {
        // Prune before saving
        pruneAllHistories()
        
        // Convert to array for JSON encoding
        let historyArray = Array(histories.values)
        
        // Perform I/O off the queue to avoid blocking
        let fileName = self.fileName
        DispatchQueue.global(qos: .utility).async {
            do {
                try PersistenceService.saveJSON(historyArray, to: fileName)
            } catch {
                print("CommandHistoryStore: Failed to save: \(error)")
            }
        }
    }
    
    private func loadFromDisk() {
        // Load synchronously during init (before any concurrent access)
        do {
            let historyArray = try PersistenceService.loadJSON([DirectoryCommandHistory].self, from: fileName)
            histories = Dictionary(uniqueKeysWithValues: historyArray.map { ($0.path, $0) })
            // Prune stale entries on load
            pruneAllHistories()
        } catch {
            // File doesn't exist or is corrupted - start fresh
            histories = [:]
        }
    }
    
    /// Force save (used when app is about to terminate)
    /// Safe to call from any thread - will not deadlock if already on queue
    func forceSave() {
        let saveBlock = {
            self.saveTask?.cancel()
            // Prune before saving
            self.pruneAllHistories()
            
            // Convert to array for JSON encoding
            let historyArray = Array(self.histories.values)
            
            // Save synchronously since app is terminating
            do {
                try PersistenceService.saveJSON(historyArray, to: self.fileName)
            } catch {
                print("CommandHistoryStore: Failed to force save: \(error)")
            }
        }
        
        // Avoid deadlock if already on queue
        if isOnQueue {
            saveBlock()
        } else {
            queue.sync {
                saveBlock()
            }
        }
    }
}

