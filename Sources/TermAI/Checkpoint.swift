import Foundation

// MARK: - File Snapshot

/// Represents the state of a file before modifications were made
struct FileSnapshot: Codable, Equatable {
    /// The absolute path to the file
    let path: String
    
    /// The content of the file before any changes (nil if file didn't exist)
    let contentBefore: String?
    
    /// Whether this file was created by the agent (didn't exist before)
    let wasCreated: Bool
    
    /// Timestamp when this snapshot was taken
    let timestamp: Date
    
    init(path: String, contentBefore: String?, wasCreated: Bool, timestamp: Date = Date()) {
        self.path = path
        self.contentBefore = contentBefore
        self.wasCreated = wasCreated
        self.timestamp = timestamp
    }
    
    /// The filename without the directory path
    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
    
    /// Whether this snapshot represents a file that existed before
    var fileExistedBefore: Bool {
        !wasCreated
    }
}

// MARK: - Checkpoint

/// Represents a point in the chat where the user can rollback to
/// Each checkpoint is created when a user sends a message, and tracks all
/// file changes made by the agent in response to that message
struct Checkpoint: Identifiable, Codable, Equatable {
    /// Unique identifier for this checkpoint
    let id: UUID
    
    /// The index of the user message this checkpoint is associated with
    let messageIndex: Int
    
    /// The content of the user message (for display purposes)
    let messagePreview: String
    
    /// When this checkpoint was created
    let timestamp: Date
    
    /// File snapshots captured before modifications - keyed by file path
    /// Only contains files that were actually modified during this checkpoint
    var fileSnapshots: [String: FileSnapshot]
    
    /// Shell commands that were executed during this checkpoint (for warning display)
    /// These cannot be automatically rolled back
    var shellCommandsRun: [String]
    
    init(
        id: UUID = UUID(),
        messageIndex: Int,
        messagePreview: String,
        timestamp: Date = Date(),
        fileSnapshots: [String: FileSnapshot] = [:],
        shellCommandsRun: [String] = []
    ) {
        self.id = id
        self.messageIndex = messageIndex
        self.messagePreview = messagePreview
        self.timestamp = timestamp
        self.fileSnapshots = fileSnapshots
        self.shellCommandsRun = shellCommandsRun
    }
    
    // MARK: - Computed Properties
    
    /// Number of files that were modified in this checkpoint
    var modifiedFileCount: Int {
        fileSnapshots.count
    }
    
    /// Whether any shell commands were run (requires warning on rollback)
    var hasShellCommands: Bool {
        !shellCommandsRun.isEmpty
    }
    
    /// Whether this checkpoint has any changes to rollback
    var hasChanges: Bool {
        !fileSnapshots.isEmpty || !shellCommandsRun.isEmpty
    }
    
    /// List of file paths that were modified
    var modifiedFilePaths: [String] {
        Array(fileSnapshots.keys).sorted()
    }
    
    /// List of files that were created (didn't exist before)
    var createdFiles: [FileSnapshot] {
        fileSnapshots.values.filter { $0.wasCreated }
    }
    
    /// List of files that were modified (existed before)
    var modifiedFiles: [FileSnapshot] {
        fileSnapshots.values.filter { !$0.wasCreated }
    }
    
    /// Short description for UI display
    var shortDescription: String {
        let fileCount = modifiedFileCount
        let cmdCount = shellCommandsRun.count
        
        var parts: [String] = []
        if fileCount > 0 {
            parts.append("\(fileCount) file\(fileCount == 1 ? "" : "s")")
        }
        if cmdCount > 0 {
            parts.append("\(cmdCount) command\(cmdCount == 1 ? "" : "s")")
        }
        
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
    
    // MARK: - Mutation Methods
    
    /// Record a file change, capturing the before state
    /// Only captures the first state - subsequent changes to the same file don't overwrite
    mutating func recordFileChange(path: String, contentBefore: String?, wasCreated: Bool) {
        // Only record the first snapshot for each file path
        // This ensures we capture the original state before any modifications
        guard fileSnapshots[path] == nil else { return }
        
        fileSnapshots[path] = FileSnapshot(
            path: path,
            contentBefore: contentBefore,
            wasCreated: wasCreated
        )
    }
    
    /// Record a shell command that was executed
    mutating func recordShellCommand(_ command: String) {
        shellCommandsRun.append(command)
    }
}

// MARK: - Rollback Result

/// Result of a rollback operation
struct RollbackResult {
    /// Whether the rollback was successful overall
    let success: Bool
    
    /// Files that were successfully restored
    let restoredFiles: [String]
    
    /// Files that failed to restore, with error messages
    let failedFiles: [(path: String, error: String)]
    
    /// Number of messages removed from chat
    let messagesRemoved: Int
    
    /// Shell commands that were run and cannot be undone (for user warning)
    let shellCommandsWarning: [String]
    
    /// Human-readable summary
    var summary: String {
        var parts: [String] = []
        
        if !restoredFiles.isEmpty {
            parts.append("Restored \(restoredFiles.count) file\(restoredFiles.count == 1 ? "" : "s")")
        }
        
        if !failedFiles.isEmpty {
            parts.append("Failed to restore \(failedFiles.count) file\(failedFiles.count == 1 ? "" : "s")")
        }
        
        if messagesRemoved > 0 {
            parts.append("Removed \(messagesRemoved) message\(messagesRemoved == 1 ? "" : "s")")
        }
        
        return parts.isEmpty ? "No changes made" : parts.joined(separator: ". ")
    }
}

// MARK: - Checkpoint Action

/// Actions a user can take on a checkpoint
enum CheckpointAction {
    /// Rollback files and truncate chat to this checkpoint
    case rollback
    
    /// Edit the message at this checkpoint, rolling back first
    case editAndRollback(newPrompt: String)
    
    /// Edit the message but keep current file state (branch conversation)
    case editAndKeepChanges(newPrompt: String)
}
