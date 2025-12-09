import Foundation

// MARK: - Insert Lines Tool

struct InsertLinesTool: AgentTool, FileOperationTool {
    let name = "insert_lines"
    let description = "Insert lines at a specific position in a file. Args: path (required), line_number (required - 1-based, lines inserted BEFORE this line), content (required). TIP: For markdown, include a leading blank line if inserting after content."
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Insert lines at a specific position in a file (lines inserted BEFORE the specified line number)",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file", required: true),
                ToolParameter(name: "line_number", type: .integer, description: "Line number where to insert (1-based, content inserted BEFORE this line)", required: true),
                ToolParameter(name: "content", type: .string, description: "Content to insert (can be multiple lines)", required: true)
            ]
        )
    }
    
    func prepareChange(args: [String: String], cwd: String?) async -> FileChange? {
        guard let path = args["path"], !path.isEmpty,
              let lineNumStr = args["line_number"], let lineNumber = Int(lineNumStr), lineNumber >= 1,
              let insertContent = args["content"] else {
            return nil
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        
        // Read current content
        guard let beforeContent = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            return nil
        }
        
        // Compute after content
        var lines = beforeContent.components(separatedBy: "\n")
        let insertIndex = min(lineNumber - 1, lines.count)
        let newLines = insertContent.components(separatedBy: "\n")
        lines.insert(contentsOf: newLines, at: insertIndex)
        let afterContent = lines.joined(separator: "\n")
        
        return FileChange(
            filePath: expandedPath,
            operationType: .insert,
            beforeContent: beforeContent,
            afterContent: afterContent,
            startLine: lineNumber,
            endLine: lineNumber + newLines.count - 1
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        guard let lineNumStr = args["line_number"], let lineNumber = Int(lineNumStr), lineNumber >= 1 else {
            return .failure("Missing or invalid line_number (must be >= 1)")
        }
        guard let insertContent = args["content"] else {
            return .failure("Missing required argument: content")
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
        let operation = FileOperation.insertLines(path: expandedPath, lineNumber: lineNumber, content: insertContent)
        
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
            return await executeInsertOperation(path: expandedPath, lineNumber: lineNumber, content: insertContent, fileChange: fileChange)
            
        case .merged(let result):
            // Operation was merged and executed by FileLockManager
            return result.isSuccess ? .success(result.output, fileChange: fileChange) : .failure(result.output, fileChange: fileChange)
            
        case .queued(let position):
            return .failure("File is locked by another session. Queue position: \(position). Please retry shortly.", fileChange: fileChange)
            
        case .timeout:
            return .failure("Timeout waiting for file lock on \(path). Another session may be holding the lock.", fileChange: fileChange)
        }
    }
    
    private func executeInsertOperation(path: String, lineNumber: Int, content insertContent: String, fileChange: FileChange?) async -> AgentToolResult {
        let url = URL(fileURLWithPath: path)
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            
            let normalizedInsert = insertContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.contains(normalizedInsert) {
                return .success("ALREADY EXISTS: The content you're trying to insert already exists in the file. No changes made. Use read_file to verify the current state.", fileChange: nil)
            }
            
            var lines = content.components(separatedBy: "\n")
            let insertIndex = min(lineNumber - 1, lines.count)
            let newLines = insertContent.components(separatedBy: "\n")
            lines.insert(contentsOf: newLines, at: insertIndex)
            
            let newContent = lines.joined(separator: "\n")
            try newContent.write(to: url, atomically: true, encoding: .utf8)
            notifyFileModified(path: path)
            
            let previewStart = max(0, insertIndex - 2)
            let previewEnd = min(lines.count, insertIndex + newLines.count + 2)
            let preview = lines[previewStart..<previewEnd].enumerated().map { 
                "\(previewStart + $0.offset + 1)| \($0.element)" 
            }.joined(separator: "\n")
            
            return .success("Inserted \(newLines.count) line(s) at line \(lineNumber).\n\nPreview around insertion:\n\(preview)", fileChange: fileChange)
        } catch {
            return .failure("Error inserting lines: \(error.localizedDescription)")
        }
    }
}
