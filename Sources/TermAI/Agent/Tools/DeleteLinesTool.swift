import Foundation

// MARK: - Delete Lines Tool

struct DeleteLinesTool: AgentTool, FileOperationTool {
    let name = "delete_lines"
    let description = "Delete a range of lines from a file. Args: path (required), start_line (required, 1-based), end_line (required, 1-based, inclusive)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Delete a range of lines from a file",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file", required: true),
                ToolParameter(name: "start_line", type: .integer, description: "Starting line number to delete (1-based)", required: true),
                ToolParameter(name: "end_line", type: .integer, description: "Ending line number to delete (1-based, inclusive)", required: true)
            ]
        )
    }
    
    func prepareChange(args: [String: String], cwd: String?) async -> FileChange? {
        guard let path = args["path"], !path.isEmpty,
              let startStr = args["start_line"], let startLine = Int(startStr), startLine >= 1,
              let endStr = args["end_line"], let endLine = Int(endStr), endLine >= startLine else {
            return nil
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        
        // Read current content
        guard let beforeContent = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            return nil
        }
        
        // Compute after content
        var lines = beforeContent.components(separatedBy: "\n")
        let start = max(0, startLine - 1)
        let end = min(lines.count, endLine)
        
        if start < lines.count {
            lines.removeSubrange(start..<end)
        }
        
        let afterContent = lines.joined(separator: "\n")
        
        return FileChange(
            filePath: expandedPath,
            operationType: .delete,
            beforeContent: beforeContent,
            afterContent: afterContent,
            startLine: startLine,
            endLine: endLine
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        guard let startStr = args["start_line"], let startLine = Int(startStr), startLine >= 1 else {
            return .failure("Missing or invalid start_line (must be >= 1)")
        }
        guard let endStr = args["end_line"], let endLine = Int(endStr), endLine >= startLine else {
            return .failure("Missing or invalid end_line (must be >= start_line)")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            // Provide helpful error with both original and resolved path
            if path != expandedPath {
                return .failure("File not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path like '/full/path/to/file' if CWD is unknown.")
            }
            return .failure("File not found: '\(path)'. Use an absolute path if needed.")
        }
        
        // Capture file change info before modifying
        let fileChange = await prepareChange(args: args, cwd: cwd)
        
        // Extract session ID for file coordination
        let sessionId = args["_sessionId"].flatMap { UUID(uuidString: $0) } ?? UUID()
        
        // Create file operation
        let operation = FileOperation.deleteLines(path: expandedPath, startLine: startLine, endLine: endLine)
        
        // Acquire lock and execute via FileLockManager
        let lockResult = await MainActor.run {
            Task {
                await FileLockManager.shared.acquireLock(for: operation, sessionId: sessionId)
            }
        }
        let acquisitionResult = await lockResult.value
        
        defer {
            Task { @MainActor in
                FileLockManager.shared.releaseLock(for: expandedPath, sessionId: sessionId)
            }
        }
        
        switch acquisitionResult {
        case .acquired:
            // Execute the operation directly
            return await executeDeleteOperation(path: expandedPath, startLine: startLine, endLine: endLine, fileChange: fileChange)
            
        case .merged(let result):
            // Operation was merged and executed by FileLockManager
            return result.isSuccess ? .success(result.output, fileChange: fileChange) : .failure(result.output)
            
        case .queued(let position):
            return .failure("File is locked by another session. Queue position: \(position). Please retry shortly.")
            
        case .timeout:
            return .failure("Timeout waiting for file lock on \(path). Another session may be holding the lock.")
        }
    }
    
    private func executeDeleteOperation(path: String, startLine: Int, endLine: Int, fileChange: FileChange?) async -> AgentToolResult {
        let url = URL(fileURLWithPath: path)
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")
            
            let start = max(0, startLine - 1)
            let end = min(lines.count, endLine)
            
            if start >= lines.count {
                return .failure("start_line \(startLine) exceeds file length (\(lines.count) lines)")
            }
            
            let deletedCount = end - start
            lines.removeSubrange(start..<end)
            
            let newContent = lines.joined(separator: "\n")
            try newContent.write(to: url, atomically: true, encoding: .utf8)
            notifyFileModified(path: path)
            
            return .success("Deleted \(deletedCount) line(s) from \(path)", fileChange: fileChange)
        } catch {
            return .failure("Error deleting lines: \(error.localizedDescription)")
        }
    }
}
