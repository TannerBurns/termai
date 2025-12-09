import Foundation

// MARK: - Shell Command Tool

/// Executes shell commands in the user's terminal PTY
/// This tool delegates to a ShellCommandExecutor (typically ChatSession) for actual execution
final class ShellCommandTool: AgentTool {
    let name = "shell"
    let description = "Execute a shell command in the user's terminal. Environment changes (cd, source, export) persist. Args: command (required), timeout (optional - seconds to wait for output)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Execute a shell command in the user's terminal. Environment changes (cd, source, export) persist in the session.",
            parameters: [
                ToolParameter(name: "command", type: .string, description: "Shell command to execute", required: true),
                ToolParameter(name: "timeout", type: .integer, description: "Seconds to wait for command output (default: 300, use higher for long builds/tests)", required: false)
            ]
        )
    }
    
    /// Weak reference to the executor (set by ChatSession when starting agent mode)
    weak var executor: ShellCommandExecutor?
    
    init(executor: ShellCommandExecutor? = nil) {
        self.executor = executor
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let command = args["command"], !command.isEmpty else {
            return .failure("Missing required argument: command")
        }
        
        guard let executor = executor else {
            return .failure("Shell command executor not configured. This is an internal error.")
        }
        
        // Parse optional timeout (nil uses default from settings)
        let timeout: TimeInterval? = args["timeout"].flatMap { Double($0) }
        
        // Execute through the session's terminal
        let result = await executor.executeShellCommand(command, requireApproval: AgentSettings.shared.requireCommandApproval, timeout: timeout)
        
        if result.success {
            var output = result.output
            if output.isEmpty {
                output = "(command completed with no output, exit code: \(result.exitCode))"
            }
            return .success(output)
        } else {
            let errorMsg = result.output.isEmpty 
                ? "Command failed with exit code \(result.exitCode)" 
                : "Command failed (exit \(result.exitCode)): \(result.output)"
            return .failure(errorMsg)
        }
    }
}
