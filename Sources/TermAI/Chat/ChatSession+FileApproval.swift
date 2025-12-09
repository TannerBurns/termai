import Foundation

// MARK: - File Change Approval Types

extension ChatSession {
    
    /// Result of a file change approval request
    enum FileChangeApprovalResult {
        /// User rejected all changes
        case rejected
        /// User approved all changes
        case approved
        /// User approved some hunks but rejected others, with the resulting modified content
        case partiallyApproved(modifiedContent: String)
        
        var isApproved: Bool {
            switch self {
            case .rejected: return false
            case .approved, .partiallyApproved: return true
            }
        }
    }
}

// MARK: - File Change Approval

extension ChatSession {
    
    /// Request user approval for a file change before applying it
    /// - Parameters:
    ///   - fileChange: The file change to approve
    ///   - toolName: Name of the tool requesting the change
    ///   - toolArgs: Arguments passed to the tool
    ///   - forceApproval: If true, always require approval regardless of settings (for destructive operations)
    ///   - toolCallId: The tool call ID to update the existing tool event message
    /// - Returns: Approval result including partial approval with modified content
    func requestFileChangeApproval(fileChange: FileChange, toolName: String, toolArgs: [String: String], forceApproval: Bool = false, toolCallId: String) async -> FileChangeApprovalResult {
        // Check if approval is required
        // Always require approval if forceApproval is true (for destructive operations like delete_file)
        guard AgentSettings.shared.requireFileEditApproval || forceApproval else {
            return .approved
        }
        
        // Post notification requesting approval
        let approvalId = UUID()
        let approval = PendingFileChangeApproval(
            id: approvalId,
            sessionId: self.id,
            fileChange: fileChange,
            toolName: toolName,
            toolArgs: toolArgs
        )
        
        NotificationCenter.default.post(
            name: .TermAIFileChangePendingApproval,
            object: nil,
            userInfo: [
                "sessionId": self.id,
                "approvalId": approvalId,
                "approval": approval
            ]
        )
        
        // Update the existing tool event message to show pending approval
        // (instead of creating a new message)
        // Make operation type prominent - especially for destructive operations
        let isDestructive = fileChange.operationType == .deleteFile
        let approvalTitle: String
        if isDestructive {
            approvalTitle = "⚠️ Delete file?"
        } else {
            approvalTitle = "Approve \(fileChange.operationType.description.lowercased())?"
        }
        
        if let idx = messages.lastIndex(where: { $0.agentEvent?.toolCallId == toolCallId }) {
            var msg = messages[idx]
            var evt = msg.agentEvent!
            evt.kind = "file_change"
            evt.title = approvalTitle
            evt.details = fileChange.fileName
            evt.fileChange = fileChange
            evt.pendingApprovalId = approvalId
            evt.pendingToolName = toolName
            evt.toolStatus = nil // Clear running status while awaiting
            evt.collapsed = false // Expand to show approval buttons
            msg.agentEvent = evt
            messages[idx] = msg
        }
        messages = messages
        persistMessages()
        
        // Post macOS system notification if user is away
        SystemNotificationService.shared.postFileChangeApprovalNotification(
            fileName: fileChange.fileName,
            operation: fileChange.operationType.description,
            sessionId: self.id
        )
        
        // Wait for approval response
        return await withCheckedContinuation { (continuation: CheckedContinuation<FileChangeApprovalResult, Never>) in
            var token: NSObjectProtocol?
            var cancelCheckTimer: DispatchSourceTimer?
            var resolved = false
            
            func finish(_ result: FileChangeApprovalResult) {
                guard !resolved else { return }
                resolved = true
                cancelCheckTimer?.cancel()
                cancelCheckTimer = nil
                if let t = token { NotificationCenter.default.removeObserver(t) }
                token = nil
                continuation.resume(returning: result)
            }
            
            // Check for cancellation periodically
            cancelCheckTimer = DispatchSource.makeTimerSource(queue: .main)
            cancelCheckTimer?.schedule(deadline: .now() + 0.5, repeating: 0.5)
            cancelCheckTimer?.setEventHandler { [weak self] in
                if self?.agentCancelled == true {
                    AgentDebugConfig.log("[Agent] File change approval wait cancelled by user")
                    finish(.rejected)
                }
            }
            cancelCheckTimer?.resume()
            
            token = NotificationCenter.default.addObserver(
                forName: .TermAIFileChangeApprovalResponse,
                object: nil,
                queue: .main
            ) { note in
                guard let noteApprovalId = note.userInfo?["approvalId"] as? UUID,
                      noteApprovalId == approvalId else { return }
                
                let approved = note.userInfo?["approved"] as? Bool ?? false
                
                if !approved {
                    finish(.rejected)
                    return
                }
                
                // Check for partial approval with modified content
                if let isPartial = note.userInfo?["partialApproval"] as? Bool,
                   isPartial,
                   let modifiedContent = note.userInfo?["modifiedContent"] as? String {
                    finish(.partiallyApproved(modifiedContent: modifiedContent))
                } else {
                    finish(.approved)
                }
            }
            
            // Timeout after 5 minutes (user might be away)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                finish(.rejected)
            }
        }
    }
    
    /// Execute a file operation tool with optional approval flow
    func executeFileToolWithApproval(
        tool: AgentTool,
        toolName: String,
        args: [String: String],
        cwd: String?,
        toolCallId: String
    ) async -> AgentToolResult {
        // Check if this is a FileOperationTool that can provide previews
        // Always require approval for RequiresApprovalTool (like delete_file)
        let alwaysRequiresApproval = (tool as? RequiresApprovalTool)?.alwaysRequiresApproval ?? false
        
        // Get the preview of changes (needed for approval flow)
        var fileChange: FileChange?
        if let fileOpTool = tool as? FileOperationTool {
            fileChange = await fileOpTool.prepareChange(args: args, cwd: cwd)
        }
        
        // Track if we have modified content from partial approval
        var modifiedArgs = args
        var partialApprovalApplied = false
        
        // Handle approval flow if required
        if tool is FileOperationTool,
           (AgentSettings.shared.requireFileEditApproval || alwaysRequiresApproval),
           let change = fileChange {
            // Request approval (force approval for destructive operations)
            let approvalResult = await requestFileChangeApproval(
                fileChange: change,
                toolName: toolName,
                toolArgs: args,
                forceApproval: alwaysRequiresApproval,
                toolCallId: toolCallId
            )
            
            // Find the tool event message to update in place (by toolCallId)
            let toolMsgIndex = messages.lastIndex(where: { $0.agentEvent?.toolCallId == toolCallId })
            
            switch approvalResult {
            case .rejected:
                // File change was rejected - update existing message
                if let idx = toolMsgIndex {
                    var msg = messages[idx]
                    var evt = msg.agentEvent!
                    evt.kind = "step"
                    evt.title = "\(toolName) rejected"
                    evt.details = "User declined: \(change.fileName)"
                    evt.toolStatus = "failed"
                    evt.pendingApprovalId = nil
                    evt.collapsed = true
                    msg.agentEvent = evt
                    messages[idx] = msg
                }
                messages = messages
                persistMessages()
                return .failure("File change rejected by user")
                
            case .partiallyApproved(let modifiedContent):
                // Partial approval - use the modified content
                partialApprovalApplied = true
                
                // Update args to use the partially approved content
                // For write_file and edit_file tools, update the content/new_string arg
                if modifiedArgs["content"] != nil {
                    modifiedArgs["content"] = modifiedContent
                } else if modifiedArgs["new_string"] != nil {
                    // For search_replace style edits, we need to use the full file content
                    // This effectively becomes a file overwrite with the partial changes
                    modifiedArgs["content"] = modifiedContent
                    modifiedArgs.removeValue(forKey: "old_string")
                    modifiedArgs.removeValue(forKey: "new_string")
                }
                
                // Update existing message to show partial approval (running state)
                if let idx = toolMsgIndex {
                    var msg = messages[idx]
                    var evt = msg.agentEvent!
                    evt.kind = "step"
                    evt.title = toolName
                    evt.details = "Applying partial changes to: \(change.fileName)"
                    evt.toolStatus = "running"
                    evt.pendingApprovalId = nil
                    evt.collapsed = true
                    evt.fileChange = FileChange(
                        id: change.id,
                        filePath: change.filePath,
                        operationType: change.operationType,
                        beforeContent: change.beforeContent,
                        afterContent: modifiedContent,
                        timestamp: change.timestamp
                    )
                    msg.agentEvent = evt
                    messages[idx] = msg
                }
                messages = messages
                persistMessages()
                
            case .approved:
                // Full approval - update existing message (running state)
                if let idx = toolMsgIndex {
                    var msg = messages[idx]
                    var evt = msg.agentEvent!
                    evt.kind = "step"
                    evt.title = toolName
                    evt.details = change.fileName
                    evt.toolStatus = "running"
                    evt.pendingApprovalId = nil
                    evt.collapsed = true
                    msg.agentEvent = evt
                    messages[idx] = msg
                }
                messages = messages
                persistMessages()
            }
        }
        
        // Record file change to checkpoint for rollback capability
        // This must happen after approval is confirmed but before execution
        if let change = fileChange {
            let wasCreated = change.operationType == .create
            recordFileChange(
                path: change.filePath,
                contentBefore: change.beforeContent,
                wasCreated: wasCreated
            )
        }
        
        // Execute the tool with potentially modified args for partial approval
        if partialApprovalApplied {
            // For partial approval, we need to write the modified content directly
            // Use the write_file tool behavior
            if let path = modifiedArgs["path"], let content = modifiedArgs["content"] {
                do {
                    let resolvedPath = resolvePath(path, cwd: cwd)
                    try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
                    return .success("File updated with selected changes: \(path)")
                } catch {
                    return .failure("Failed to write partial changes: \(error.localizedDescription)")
                }
            }
        }
        
        // Execute the tool normally
        return await tool.execute(args: args, cwd: cwd)
    }
    
    /// Resolve a path relative to the working directory
    func resolvePath(_ path: String, cwd: String?) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        if let cwd = cwd {
            return (cwd as NSString).appendingPathComponent(path)
        }
        return path
    }
}
