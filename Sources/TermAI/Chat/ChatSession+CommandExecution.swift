import Foundation
import TermAIModels

// MARK: - Command Execution

extension ChatSession {
    
    /// Wait for command output from the terminal
    func waitForCommandOutput(matching command: String, timeout: TimeInterval) async -> String? {
        let sid = self.id
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var token: NSObjectProtocol?
            var cancelCheckTimer: DispatchSourceTimer?
            var resolved = false
            
            func finish(_ value: String?) {
                guard !resolved else { return }
                resolved = true
                cancelCheckTimer?.cancel()
                cancelCheckTimer = nil
                if let t = token { NotificationCenter.default.removeObserver(t) }
                token = nil
                continuation.resume(returning: value)
            }
            
            // Check for cancellation periodically
            cancelCheckTimer = DispatchSource.makeTimerSource(queue: .main)
            cancelCheckTimer?.schedule(deadline: .now() + 0.5, repeating: 0.5)
            cancelCheckTimer?.setEventHandler { [weak self] in
                if self?.agentCancelled == true {
                    AgentDebugConfig.log("[Agent] Command wait cancelled by user")
                    finish(nil)
                }
            }
            cancelCheckTimer?.resume()
            
            token = NotificationCenter.default.addObserver(forName: .TermAICommandFinished, object: nil, queue: .main) { note in
                guard let noteSid = note.userInfo?["sessionId"] as? UUID, noteSid == sid else { return }
                guard let cmd = note.userInfo?["command"] as? String, cmd == command else { return }
                let out = note.userInfo?["output"] as? String
                finish(out)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
        }
    }
    
    /// Request approval for a command if settings require it
    /// Returns the approved command (possibly edited), or nil if rejected
    func requestCommandApproval(_ command: String) async -> String? {
        let settings = AgentSettings.shared
        
        // Auto-approve if approval not required or command is read-only and auto-approve is enabled
        if settings.shouldAutoApprove(command) {
            return command
        }
        
        // Post notification requesting approval (for any listeners, but UI is now inline)
        let approvalId = UUID()
        NotificationCenter.default.post(
            name: .TermAICommandPendingApproval,
            object: nil,
            userInfo: [
                "sessionId": self.id,
                "approvalId": approvalId,
                "command": command
            ]
        )
        
        // Add a pending approval message with inline approval buttons
        messages.append(ChatMessage(
            role: "assistant",
            content: "",
            agentEvent: AgentEvent(
                kind: "command_approval",
                title: "Awaiting command approval",
                details: command,
                command: command,
                output: nil,
                collapsed: false,
                pendingApprovalId: approvalId,
                pendingToolName: "shell",
                eventCategory: "command"
            )
        ))
        messages = messages
        persistMessages()
        
        // Post macOS system notification if user is away
        SystemNotificationService.shared.postCommandApprovalNotification(
            command: command,
            sessionId: self.id
        )
        
        // Wait for approval response
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var token: NSObjectProtocol?
            var cancelCheckTimer: DispatchSourceTimer?
            var resolved = false
            
            func finish(_ value: String?) {
                guard !resolved else { return }
                resolved = true
                cancelCheckTimer?.cancel()
                cancelCheckTimer = nil
                if let t = token { NotificationCenter.default.removeObserver(t) }
                token = nil
                continuation.resume(returning: value)
            }
            
            // Check for cancellation periodically
            cancelCheckTimer = DispatchSource.makeTimerSource(queue: .main)
            cancelCheckTimer?.schedule(deadline: .now() + 0.5, repeating: 0.5)
            cancelCheckTimer?.setEventHandler { [weak self] in
                if self?.agentCancelled == true {
                    AgentDebugConfig.log("[Agent] Approval wait cancelled by user")
                    finish(nil)
                }
            }
            cancelCheckTimer?.resume()
            
            token = NotificationCenter.default.addObserver(
                forName: .TermAICommandApprovalResponse,
                object: nil,
                queue: .main
            ) { note in
                guard let noteApprovalId = note.userInfo?["approvalId"] as? UUID,
                      noteApprovalId == approvalId else { return }
                
                let approved = note.userInfo?["approved"] as? Bool ?? false
                let editedCommand = note.userInfo?["command"] as? String
                
                if approved {
                    finish(editedCommand ?? command)
                } else {
                    finish(nil)
                }
            }
            
            // Timeout after 5 minutes (user might be away)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                finish(nil)
            }
        }
    }
    
    /// Execute a command with optional approval flow
    /// - Parameters:
    ///   - command: The shell command to execute
    ///   - timeout: Custom timeout for command execution (defaults to settings value)
    func executeCommandWithApproval(_ command: String, timeout: TimeInterval? = nil) async -> String? {
        let effectiveTimeout = timeout ?? AgentSettings.shared.commandTimeout
        // Request approval if needed
        guard let approvedCommand = await requestCommandApproval(command) else {
            // Command was rejected - update the existing approval message
            if let idx = messages.lastIndex(where: { $0.agentEvent?.kind == "command_approval" && $0.agentEvent?.command == command }) {
                var msg = messages[idx]
                var evt = msg.agentEvent!
                evt.kind = "status"
                evt.title = "Command rejected"
                evt.details = "User declined to execute"
                evt.toolStatus = "failed"
                evt.pendingApprovalId = nil
                msg.agentEvent = evt
                messages[idx] = msg
            }
            messages = messages
            persistMessages()
            return nil
        }
        
        // Find the approval message and update it to show running state
        if let idx = messages.lastIndex(where: { $0.agentEvent?.kind == "command_approval" && $0.agentEvent?.command == command }) {
            var msg = messages[idx]
            var evt = msg.agentEvent!
            evt.kind = "status"
            evt.title = approvedCommand != command ? "Running (edited)" : "Running"
            evt.command = approvedCommand
            evt.details = approvedCommand
            evt.toolStatus = "running"
            evt.pendingApprovalId = nil
            msg.agentEvent = evt
            messages[idx] = msg
            messages = messages
            persistMessages()
        }
        
        AgentDebugConfig.log("[Agent] Executing command: \(approvedCommand)")
        NotificationCenter.default.post(
            name: .TermAIExecuteCommand,
            object: nil,
            userInfo: [
                "sessionId": self.id,
                "command": approvedCommand
            ]
        )
        
        // Wait for output
        let output = await waitForCommandOutput(matching: approvedCommand, timeout: effectiveTimeout)
        
        // Record in context log - note: recentCommands tracking done in caller
        agentContextLog.append("RAN: \(approvedCommand)")
        if let out = output, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Summarize if output is long
            let processedOutput = await summarizeOutput(out, command: approvedCommand)
            agentContextLog.append("OUTPUT: \(processedOutput)")
        }
        
        // Update the command message with completed status and output
        if let idx = messages.lastIndex(where: { $0.agentEvent?.command == approvedCommand && $0.agentEvent?.toolStatus == "running" }) {
            var msg = messages[idx]
            var evt = msg.agentEvent!
            evt.title = "Completed"
            evt.toolStatus = "succeeded"
            evt.output = output
            msg.agentEvent = evt
            messages[idx] = msg
            messages = messages
            persistMessages()
        }
        
        // Track tool call execution
        TokenUsageTracker.shared.recordToolCall(
            provider: providerName,
            model: model,
            command: approvedCommand
        )
        
        return output
    }
}

// MARK: - ShellCommandExecutor Protocol

extension ChatSession {
    
    /// Execute a shell command via the terminal PTY (ShellCommandExecutor protocol)
    /// This is used by the ShellCommandTool in the native tool calling flow
    nonisolated func executeShellCommand(_ command: String, requireApproval: Bool, timeout: TimeInterval? = nil) async -> (success: Bool, output: String, exitCode: Int) {
        // Use provided timeout or fall back to default from settings
        let effectiveTimeout = timeout ?? AgentSettings.shared.commandTimeout
        
        // Record shell command to checkpoint for rollback warnings
        await MainActor.run {
            recordShellCommand(command)
        }
        
        // Execute the command
        // Always require approval for destructive commands (rm, rmdir), regardless of settings
        let output: String?
        if AgentSettings.shared.isDestructiveCommand(command) ||
           (requireApproval && !AgentSettings.shared.shouldAutoApprove(command)) {
            output = await executeCommandWithApproval(command, timeout: effectiveTimeout)
        } else {
            // Direct execution
            await MainActor.run {
                AgentDebugConfig.log("[ShellTool] Executing command: \(command) (timeout: \(Int(effectiveTimeout))s)")
                NotificationCenter.default.post(
                    name: .TermAIExecuteCommand,
                    object: nil,
                    userInfo: [
                        "sessionId": self.id,
                        "command": command
                    ]
                )
            }
            output = await waitForCommandOutput(matching: command, timeout: effectiveTimeout)
            
            await MainActor.run {
                agentContextLog.append("RAN: \(command)")
                TokenUsageTracker.shared.recordToolCall(
                    provider: providerName,
                    model: model,
                    command: command
                )
            }
        }
        
        // Get exit code from context log
        let exitCode = await MainActor.run { () -> Int in
            let exitStr = lastExitCodeString()
            return Int(exitStr) ?? -1
        }
        
        let success = exitCode == 0
        let outputStr = output ?? ""
        
        // Store output for later search
        if !outputStr.isEmpty {
            await MainActor.run {
                AgentToolRegistry.shared.storeOutput(outputStr, command: command)
            }
        }
        
        return (success: success, output: outputStr, exitCode: exitCode)
    }
}
