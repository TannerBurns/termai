import Foundation

// MARK: - Checkpoint Management

extension ChatSession {
    
    /// Create a new checkpoint at the current message index
    /// Called when a user sends a message to mark a point they can rollback to
    func createCheckpoint(messagePreview: String) {
        let messageIndex = messages.count - 1  // Index of the user message just added
        
        // Finalize any existing checkpoint before creating a new one
        finalizeCurrentCheckpoint()
        
        let checkpoint = Checkpoint(
            messageIndex: messageIndex,
            messagePreview: String(messagePreview.prefix(100))
        )
        
        currentCheckpoint = checkpoint
        AgentDebugConfig.log("[Checkpoint] Created checkpoint at message index \(messageIndex)")
    }
    
    /// Record a file change to the current checkpoint
    /// Should be called BEFORE any file modification to capture the original state
    func recordFileChange(path: String, contentBefore: String?, wasCreated: Bool) {
        guard var checkpoint = currentCheckpoint else {
            AgentDebugConfig.log("[Checkpoint] No current checkpoint - file change not recorded for: \(path)")
            return
        }
        
        // Only record if we haven't already captured this file
        guard checkpoint.fileSnapshots[path] == nil else {
            AgentDebugConfig.log("[Checkpoint] File already recorded in checkpoint: \(path)")
            return
        }
        
        checkpoint.recordFileChange(path: path, contentBefore: contentBefore, wasCreated: wasCreated)
        currentCheckpoint = checkpoint
        AgentDebugConfig.log("[Checkpoint] Recorded file change: \(path) (created: \(wasCreated))")
    }
    
    /// Record a shell command that was executed during this checkpoint
    func recordShellCommand(_ command: String) {
        guard var checkpoint = currentCheckpoint else {
            AgentDebugConfig.log("[Checkpoint] No current checkpoint - shell command not recorded")
            return
        }
        
        checkpoint.recordShellCommand(command)
        currentCheckpoint = checkpoint
        AgentDebugConfig.log("[Checkpoint] Recorded shell command: \(command.prefix(50))...")
    }
    
    /// Finalize the current checkpoint and add it to the checkpoints array
    /// Called when starting a new checkpoint or when the session ends
    func finalizeCurrentCheckpoint() {
        guard let checkpoint = currentCheckpoint else { return }
        
        // Only save checkpoint if it has any recorded changes
        if checkpoint.hasChanges {
            checkpoints.append(checkpoint)
            persistCheckpoints()
            AgentDebugConfig.log("[Checkpoint] Finalized checkpoint with \(checkpoint.modifiedFileCount) files and \(checkpoint.shellCommandsRun.count) commands")
        } else {
            AgentDebugConfig.log("[Checkpoint] Discarding empty checkpoint at message index \(checkpoint.messageIndex)")
        }
        
        currentCheckpoint = nil
    }
    
    /// Get the checkpoint for a specific message index
    func checkpoint(forMessageIndex index: Int) -> Checkpoint? {
        checkpoints.first { $0.messageIndex == index }
    }
    
    /// Get all changes made between a checkpoint and the current state
    /// Returns file changes from this checkpoint through all subsequent checkpoints
    func changesSinceCheckpoint(_ checkpoint: Checkpoint) -> (files: [String: FileSnapshot], commands: [String]) {
        var allFiles: [String: FileSnapshot] = checkpoint.fileSnapshots
        var allCommands: [String] = checkpoint.shellCommandsRun
        
        // Collect changes from all subsequent checkpoints
        for cp in checkpoints where cp.messageIndex > checkpoint.messageIndex {
            for (path, snapshot) in cp.fileSnapshots {
                // Only keep the earliest snapshot for each file
                if allFiles[path] == nil {
                    allFiles[path] = snapshot
                }
            }
            allCommands.append(contentsOf: cp.shellCommandsRun)
        }
        
        // Also include current checkpoint if it exists and is after this checkpoint
        if let current = currentCheckpoint, current.messageIndex > checkpoint.messageIndex {
            for (path, snapshot) in current.fileSnapshots {
                if allFiles[path] == nil {
                    allFiles[path] = snapshot
                }
            }
            allCommands.append(contentsOf: current.shellCommandsRun)
        }
        
        return (allFiles, allCommands)
    }
    
    /// Persist checkpoints to disk
    func persistCheckpoints() {
        let checkpointsToSave = checkpoints
        let fileName = checkpointsFileName
        PersistenceService.saveJSONInBackground(checkpointsToSave, to: fileName)
    }
    
    /// Load checkpoints from disk
    func loadCheckpoints() {
        if let loaded = try? PersistenceService.loadJSON([Checkpoint].self, from: checkpointsFileName) {
            checkpoints = loaded
            AgentDebugConfig.log("[Checkpoint] Loaded \(checkpoints.count) checkpoints")
        }
    }
    
    /// Clear all checkpoints (used when clearing chat)
    func clearCheckpoints() {
        checkpoints.removeAll()
        currentCheckpoint = nil
        
        // Delete the checkpoints file
        if let dir = try? PersistenceService.appSupportDirectory() {
            let file = dir.appendingPathComponent(checkpointsFileName)
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - File Change History

extension ChatSession {
    
    /// Get all file changes from the current session as a navigable history
    /// Extracts FileChange objects from messages with agentEvent.fileChange
    var fileChangeHistory: [DiffHistoryEntry] {
        var entries: [DiffHistoryEntry] = []
        var sequenceNumber = 0
        
        for message in messages {
            guard let event = message.agentEvent,
                  let fileChange = event.fileChange else {
                continue
            }
            
            // Only include actual file changes (not pending approvals without resolution)
            // Check if this is a completed file change event
            let isCompletedChange = event.kind == "status" || 
                                    (event.kind == "file_change" && event.pendingApprovalId == nil)
            
            if isCompletedChange {
                // Find the associated checkpoint if any
                let checkpointId = checkpoints.first { cp in
                    cp.fileSnapshots.keys.contains(fileChange.filePath)
                }?.id
                
                entries.append(DiffHistoryEntry(
                    fileChange: fileChange,
                    checkpointId: checkpointId,
                    sequenceNumber: sequenceNumber
                ))
                sequenceNumber += 1
            }
        }
        
        return entries
    }
    
    /// Get the index of a file change in the history
    func historyIndex(for fileChange: FileChange) -> Int? {
        fileChangeHistory.firstIndex { $0.fileChange.id == fileChange.id }
    }
    
    /// Get the previous file change in history (for navigation)
    func previousFileChange(from current: FileChange) -> FileChange? {
        guard let currentIndex = historyIndex(for: current),
              currentIndex > 0 else {
            return nil
        }
        return fileChangeHistory[currentIndex - 1].fileChange
    }
    
    /// Get the next file change in history (for navigation)
    func nextFileChange(from current: FileChange) -> FileChange? {
        guard let currentIndex = historyIndex(for: current),
              currentIndex < fileChangeHistory.count - 1 else {
            return nil
        }
        return fileChangeHistory[currentIndex + 1].fileChange
    }
}

// MARK: - Rollback and Branching

extension ChatSession {
    
    /// Rollback to a specific checkpoint, restoring files and truncating messages
    /// - Parameters:
    ///   - checkpoint: The checkpoint to rollback to
    ///   - removeUserMessage: If true, also removes the user message at this checkpoint (for edit scenarios)
    /// - Returns: A RollbackResult describing what was done
    func rollbackToCheckpoint(_ checkpoint: Checkpoint, removeUserMessage: Bool = false) -> RollbackResult {
        // Cancel any ongoing streaming or agent work
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageId = nil
        if isAgentRunning {
            cancelAgent()
        }
        
        // Collect all file changes from this checkpoint onwards
        let (allFiles, allCommands) = changesSinceCheckpoint(checkpoint)
        
        // Restore files to their original state
        var restoredFiles: [String] = []
        var failedFiles: [(path: String, error: String)] = []
        
        for (path, snapshot) in allFiles {
            do {
                if snapshot.wasCreated {
                    // File was created by agent - delete it
                    if FileManager.default.fileExists(atPath: path) {
                        try FileManager.default.removeItem(atPath: path)
                        restoredFiles.append(path)
                        AgentDebugConfig.log("[Rollback] Deleted created file: \(path)")
                    }
                } else if let originalContent = snapshot.contentBefore {
                    // File existed before - restore original content
                    try originalContent.write(toFile: path, atomically: true, encoding: .utf8)
                    restoredFiles.append(path)
                    AgentDebugConfig.log("[Rollback] Restored file: \(path)")
                }
            } catch {
                failedFiles.append((path: path, error: error.localizedDescription))
                AgentDebugConfig.log("[Rollback] Failed to restore \(path): \(error)")
            }
        }
        
        // Truncate messages to the checkpoint's message index
        // If removeUserMessage is true, remove the user message too (for edit scenarios)
        let targetMessageCount = removeUserMessage ? checkpoint.messageIndex : checkpoint.messageIndex + 1
        let messagesRemoved = messages.count - targetMessageCount
        if messages.count > targetMessageCount {
            messages = Array(messages.prefix(targetMessageCount))
            persistMessages()
            AgentDebugConfig.log("[Rollback] Truncated messages from \(messages.count + messagesRemoved) to \(messages.count)")
        }
        
        // Remove checkpoints after this one
        checkpoints.removeAll { $0.messageIndex >= checkpoint.messageIndex }
        currentCheckpoint = nil
        persistCheckpoints()
        
        // Reset agent-related state
        agentContextLog.removeAll()
        agentChecklist = nil
        resetContextTracking()
        
        let result = RollbackResult(
            success: failedFiles.isEmpty,
            restoredFiles: restoredFiles,
            failedFiles: failedFiles,
            messagesRemoved: messagesRemoved,
            shellCommandsWarning: allCommands
        )
        
        AgentDebugConfig.log("[Rollback] Completed: \(result.summary)")
        return result
    }
    
    /// Branch from a checkpoint with a new prompt, keeping the current file state
    /// - Parameters:
    ///   - checkpoint: The checkpoint to branch from
    ///   - newPrompt: The new user message to start the branch with
    func branchFromCheckpoint(_ checkpoint: Checkpoint, newPrompt: String) {
        // Cancel any ongoing streaming or agent work
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageId = nil
        if isAgentRunning {
            cancelAgent()
        }
        
        // Truncate messages to the checkpoint's message index (remove the original user message too)
        if messages.count > checkpoint.messageIndex {
            messages = Array(messages.prefix(checkpoint.messageIndex))
            persistMessages()
            AgentDebugConfig.log("[Branch] Truncated messages to index \(checkpoint.messageIndex)")
        }
        
        // Remove this checkpoint and all after it (we're creating a new branch)
        checkpoints.removeAll { $0.messageIndex >= checkpoint.messageIndex }
        currentCheckpoint = nil
        persistCheckpoints()
        
        // Reset agent-related state
        agentContextLog.removeAll()
        agentChecklist = nil
        resetContextTracking()
        
        AgentDebugConfig.log("[Branch] Created branch from checkpoint at message \(checkpoint.messageIndex)")
        
        // Note: The caller should then call sendUserMessage(newPrompt) to continue
    }
    
    /// Get summary of what would be affected by rolling back to a checkpoint
    /// Useful for showing confirmation dialog
    func rollbackPreview(for checkpoint: Checkpoint) -> (filesToRestore: [FileSnapshot], shellCommands: [String], messagesToRemove: Int) {
        let (allFiles, allCommands) = changesSinceCheckpoint(checkpoint)
        let snapshots = Array(allFiles.values)
        let messagesToRemove = messages.count - (checkpoint.messageIndex + 1)
        return (snapshots, allCommands, max(0, messagesToRemove))
    }
}
