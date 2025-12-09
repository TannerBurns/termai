import Foundation

// MARK: - Run Background Tool

struct RunBackgroundTool: AgentTool {
    let name = "run_background"
    let description = "Start a process in the background (e.g., a server). Args: command (required), wait_for (optional - text to wait for in output to confirm startup), timeout (optional - seconds to wait, default: 5)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Start a process in the background (useful for servers, watchers, etc.)",
            parameters: [
                ToolParameter(name: "command", type: .string, description: "Command to run in the background", required: true),
                ToolParameter(name: "wait_for", type: .string, description: "Text to wait for in output to confirm startup", required: false),
                ToolParameter(name: "timeout", type: .integer, description: "Seconds to wait for startup confirmation (default: 5)", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let command = args["command"], !command.isEmpty else {
            return .failure("Missing required argument: command")
        }
        
        let waitFor = args["wait_for"]
        let timeout = Double(args["timeout"] ?? "5") ?? 5.0
        
        let result = await ProcessManager.shared.startProcess(
            command: command,
            cwd: cwd,
            waitForOutput: waitFor,
            timeout: timeout
        )
        
        if let error = result.error {
            return .failure(error)
        }
        
        var output = "Started background process with PID: \(result.pid)"
        if !result.initialOutput.isEmpty {
            output += "\n\nInitial output:\n\(String(result.initialOutput.prefix(1500)))"
        }
        
        return .success(output)
    }
}
