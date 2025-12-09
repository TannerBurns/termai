import Foundation

// MARK: - Stop Process Tool

struct StopProcessTool: AgentTool {
    let name = "stop_process"
    let description = "Stop a background process. Args: pid (required - process ID to stop), all (optional - 'true' to stop all managed processes)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Stop a background process by PID or stop all managed processes",
            parameters: [
                ToolParameter(name: "pid", type: .integer, description: "Process ID to stop", required: false),
                ToolParameter(name: "all", type: .boolean, description: "Stop all managed background processes", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        // Stop all processes
        if args["all"]?.lowercased() == "true" {
            await MainActor.run {
                ProcessManager.shared.stopAllProcessesSync()
                ProcessManager.shared.refreshProcessList()
            }
            return .success("Stopped all managed background processes")
        }
        
        // Stop specific PID
        guard let pidStr = args["pid"], let pid = Int32(pidStr) else {
            return .failure("Missing required argument: pid")
        }
        
        let success = await MainActor.run { ProcessManager.shared.stopProcessSync(pid: pid) }
        if success {
            await MainActor.run {
                ProcessManager.shared.refreshProcessList()
            }
            return .success("Stopped process \(pid)")
        } else {
            return .failure("Process \(pid) not found or already stopped")
        }
    }
}
