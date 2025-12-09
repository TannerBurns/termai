import Foundation

// MARK: - Delete File Tool

struct DeleteFileTool: AgentTool, FileOperationTool, RequiresApprovalTool {
    let name = "delete_file"
    let description = "Delete a file. ALWAYS requires user approval. Args: path (required)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Delete a file at the specified path. This operation ALWAYS requires user approval before execution.",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file to delete", required: true)
            ]
        )
    }
    
    func prepareChange(args: [String: String], cwd: String?) async -> FileChange? {
        guard let path = args["path"], !path.isEmpty else {
            return nil
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return nil
        }
        
        // Read current content for preview
        let beforeContent = try? String(contentsOfFile: expandedPath, encoding: .utf8)
        
        return FileChange(
            filePath: expandedPath,
            operationType: .deleteFile,
            beforeContent: beforeContent,
            afterContent: nil  // File will be deleted, no after content
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        
        // Check file exists
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            if path != expandedPath {
                return .failure("File not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path if CWD is unknown.")
            }
            return .failure("File not found: '\(path)'. Use an absolute path if needed.")
        }
        
        // Prepare file change for diff display
        let fileChange = await prepareChange(args: args, cwd: cwd)
        
        // Delete the file
        do {
            try FileManager.default.removeItem(atPath: expandedPath)
            notifyFileModified(path: expandedPath)  // Notify so any open tabs can react
            return .success("Deleted file: \(expandedPath)", fileChange: fileChange)
        } catch {
            return .failure("Error deleting file: \(error.localizedDescription)")
        }
    }
}
