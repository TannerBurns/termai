import Foundation

// MARK: - Edit File Tool (Search/Replace)

struct EditFileTool: AgentTool, FileOperationTool {
    let name = "edit_file"
    let description = "PREFERRED for modifying existing files. Search and replace specific text. Args: path (required), old_text (required - exact text to find, include enough context to be unique), new_text (required - replacement text), replace_all (optional, 'true'/'false', default: false)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "PREFERRED tool for modifying existing files. Finds and replaces specific text. Include enough surrounding context in old_text to ensure a unique match.",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file to edit", required: true),
                ToolParameter(name: "old_text", type: .string, description: "Exact text to find and replace (must match exactly including whitespace)", required: true),
                ToolParameter(name: "new_text", type: .string, description: "Replacement text (can be empty to delete)", required: true),
                ToolParameter(name: "replace_all", type: .boolean, description: "Replace all occurrences (default: false, only first match)", required: false)
            ]
        )
    }
    
    func prepareChange(args: [String: String], cwd: String?) async -> FileChange? {
        guard let path = args["path"], !path.isEmpty,
              let oldText = args["old_text"], !oldText.isEmpty,
              let newText = args["new_text"] else {
            return nil
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let replaceAll = args["replace_all"]?.lowercased() == "true"
        
        // Read current content
        guard let beforeContent = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            return nil
        }
        
        // Check if old_text exists
        guard beforeContent.contains(oldText) else {
            return nil
        }
        
        // Compute after content
        let afterContent: String
        if replaceAll {
            afterContent = beforeContent.replacingOccurrences(of: oldText, with: newText)
        } else {
            if let range = beforeContent.range(of: oldText) {
                afterContent = beforeContent.replacingCharacters(in: range, with: newText)
            } else {
                afterContent = beforeContent
            }
        }
        
        return FileChange(
            filePath: expandedPath,
            operationType: .edit,
            beforeContent: beforeContent,
            afterContent: afterContent,
            oldText: oldText,
            newText: newText
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        guard let oldText = args["old_text"], !oldText.isEmpty else {
            return .failure("Missing required argument: old_text (the text to find and replace)")
        }
        guard let newText = args["new_text"] else {
            return .failure("Missing required argument: new_text (replacement text, can be empty string to delete)")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let replaceAll = args["replace_all"]?.lowercased() == "true"
        
        // Check file exists
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
        let operation = FileOperation.edit(path: expandedPath, oldText: oldText, newText: newText, replaceAll: replaceAll)
        
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
            return await executeEditOperation(path: expandedPath, oldText: oldText, newText: newText, replaceAll: replaceAll, fileChange: fileChange)
            
        case .merged(let result):
            // Operation was merged and executed by FileLockManager
            return result.isSuccess ? .success(result.output, fileChange: fileChange) : .failure(result.output, fileChange: fileChange)
            
        case .queued(let position):
            return .failure("File is locked by another session. Queue position: \(position). Please retry shortly.", fileChange: fileChange)
            
        case .timeout:
            return .failure("Timeout waiting for file lock on \(path). Another session may be holding the lock.", fileChange: fileChange)
        }
    }
    
    private func executeEditOperation(path: String, oldText: String, newText: String, replaceAll: Bool, fileChange: FileChange?) async -> AgentToolResult {
        let url = URL(fileURLWithPath: path)
        
        do {
            var content = try String(contentsOf: url, encoding: .utf8)
            
            guard content.contains(oldText) else {
                let lines = content.components(separatedBy: .newlines)
                let preview = lines.prefix(10).joined(separator: "\n")
                return .failure("Text not found in file. The old_text must match exactly (including whitespace/indentation).\n\nFile has \(lines.count) lines. First 10 lines:\n\(preview)")
            }
            
            let occurrences = content.components(separatedBy: oldText).count - 1
            
            if replaceAll {
                content = content.replacingOccurrences(of: oldText, with: newText)
            } else {
                if let range = content.range(of: oldText) {
                    content = content.replacingCharacters(in: range, with: newText)
                }
            }
            
            try content.write(to: url, atomically: true, encoding: .utf8)
            notifyFileModified(path: path)
            
            let resultLines = content.components(separatedBy: "\n")
            let previewLines = resultLines.prefix(20).enumerated().map { "\($0.offset + 1)| \($0.element)" }.joined(separator: "\n")
            let suffix = resultLines.count > 20 ? "\n... (\(resultLines.count - 20) more lines)" : ""
            
            if replaceAll {
                return .success("Replaced \(occurrences) occurrence(s) in \(path).\n\nFile preview:\n\(previewLines)\(suffix)", fileChange: fileChange)
            } else {
                return .success("Replaced 1 occurrence in \(path).\n\nFile preview:\n\(previewLines)\(suffix)", fileChange: fileChange)
            }
        } catch {
            return .failure("Error editing file: \(error.localizedDescription)")
        }
    }
}
