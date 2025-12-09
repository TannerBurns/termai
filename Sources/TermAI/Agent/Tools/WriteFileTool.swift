import Foundation

// MARK: - Write File Tool

struct WriteFileTool: AgentTool, FileOperationTool {
    let name = "write_file"
    let description = "Create a NEW file or COMPLETELY REWRITE an existing file. For small edits to existing files, prefer edit_file, insert_lines, or delete_lines instead. Args: path (required), content (required), mode ('overwrite' or 'append', default: overwrite)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Create a NEW file or COMPLETELY REWRITE an existing file. For small changes to existing files, prefer edit_file (search/replace), insert_lines, or delete_lines instead - they are safer and more precise.",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file to write", required: true),
                ToolParameter(name: "content", type: .string, description: "Content to write to the file", required: true),
                ToolParameter(name: "mode", type: .string, description: "Write mode: 'overwrite' (default) or 'append'", required: false, enumValues: ["overwrite", "append"])
            ]
        )
    }
    
    func prepareChange(args: [String: String], cwd: String?) async -> FileChange? {
        guard let path = args["path"], !path.isEmpty,
              let content = args["content"] else {
            return nil
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let mode = args["mode"] ?? "overwrite"
        let fileExists = FileManager.default.fileExists(atPath: expandedPath)
        
        // Read current content if file exists
        var beforeContent: String? = nil
        if fileExists {
            beforeContent = try? String(contentsOfFile: expandedPath, encoding: .utf8)
        }
        
        // Compute after content
        let afterContent: String
        if mode == "append" && beforeContent != nil {
            afterContent = beforeContent! + content
        } else {
            afterContent = content
        }
        
        let operationType: FileOperationType = fileExists ? (mode == "append" ? .insert : .overwrite) : .create
        
        return FileChange(
            filePath: expandedPath,
            operationType: operationType,
            beforeContent: beforeContent,
            afterContent: afterContent
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        guard let content = args["content"] else {
            return .failure("Missing required argument: content")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let mode = args["mode"] ?? "overwrite"
        let writeMode: FileOperation.WriteMode = mode == "append" ? .append : .overwrite
        
        // Capture file change info before modifying
        let fileChange = await prepareChange(args: args, cwd: cwd)
        
        // Extract session ID for file coordination
        let sessionId = args["_sessionId"].flatMap { UUID(uuidString: $0) } ?? UUID()
        
        // Create file operation
        let operation = FileOperation.write(path: expandedPath, content: content, mode: writeMode)
        
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
            return await executeWriteOperation(path: expandedPath, content: content, mode: writeMode, fileChange: fileChange)
            
        case .merged(let result):
            // Operation was merged and executed by FileLockManager
            return result.isSuccess ? .success(result.output, fileChange: fileChange) : .failure(result.output, fileChange: fileChange)
            
        case .queued(let position):
            return .failure("File is locked by another session. Queue position: \(position). Please retry shortly.", fileChange: fileChange)
            
        case .timeout:
            return .failure("Timeout waiting for file lock on \(path). Another session may be holding the lock.", fileChange: fileChange)
        }
    }
    
    private func executeWriteOperation(path: String, content: String, mode: FileOperation.WriteMode, fileChange: FileChange?) async -> AgentToolResult {
        let url = URL(fileURLWithPath: path)
        
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            
            if mode == .append && FileManager.default.fileExists(atPath: path) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                if let data = content.data(using: .utf8) {
                    handle.write(data)
                }
                try handle.close()
                notifyFileModified(path: path)
                return .success("Appended \(content.count) chars to \(path)", fileChange: fileChange)
            } else {
                try content.write(to: url, atomically: true, encoding: .utf8)
                notifyFileModified(path: path)
                return .success("Wrote \(content.count) chars to \(path)", fileChange: fileChange)
            }
        } catch {
            return .failure("Error writing file: \(error.localizedDescription)")
        }
    }
}
