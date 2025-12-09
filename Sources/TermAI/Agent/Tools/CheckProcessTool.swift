import Foundation

// MARK: - Check Process Tool

struct CheckProcessTool: AgentTool {
    let name = "check_process"
    let description = "Check if a background process is running. Args: pid (optional - process ID), port (optional - check by port number), list (optional - 'true' to list all managed processes)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Check if a background process is running by PID, port, or list all",
            parameters: [
                ToolParameter(name: "pid", type: .integer, description: "Process ID to check", required: false),
                ToolParameter(name: "port", type: .integer, description: "Port number to check for listening process", required: false),
                ToolParameter(name: "list", type: .boolean, description: "List all managed background processes", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        // List all processes
        if args["list"]?.lowercased() == "true" {
            let processes = await MainActor.run { ProcessManager.shared.listProcesses() }
            if processes.isEmpty {
                return .success("No managed background processes")
            }
            
            var output = "Managed background processes:\n"
            for proc in processes {
                let status = proc.running ? "RUNNING" : "STOPPED"
                let uptime = Int(proc.uptime)
                output += "  PID \(proc.pid): \(status) (uptime: \(uptime)s) - \(proc.command.prefix(50))\n"
            }
            return .success(output)
        }
        
        // Check by PID
        if let pidStr = args["pid"], let pid = Int32(pidStr) {
            let result = await MainActor.run { ProcessManager.shared.checkProcess(pid: pid) }
            
            var output = "Process \(pid): \(result.running ? "RUNNING" : "NOT RUNNING")"
            if !result.output.isEmpty {
                output += "\n\nRecent output:\n\(result.output)"
            }
            if !result.error.isEmpty && result.error != "Process \(pid) not found in manager" {
                output += "\n\nRecent errors:\n\(result.error)"
            }
            
            return .success(output)
        }
        
        // Check by port
        if let portStr = args["port"], let port = Int(portStr) {
            let result = await ProcessManager.shared.checkProcessByPort(port: port)
            
            var output = "Port \(port): \(result.running ? "IN USE" : "FREE")"
            if let pid = result.pid {
                output += " (PID: \(pid))"
            }
            if !result.output.isEmpty {
                output += "\n\(result.output)"
            }
            
            return .success(output)
        }
        
        return .failure("Must provide either 'pid', 'port', or 'list=true'")
    }
}
