import Foundation

// MARK: - Read File Tool

struct ReadFileTool: AgentTool {
    let name = "read_file"
    let description = "Read contents of a file. Args: path (required), start_line (optional), end_line (optional)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Read the contents of a file at the specified path",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the file to read", required: true),
                ToolParameter(name: "start_line", type: .integer, description: "Starting line number (1-based, optional)", required: false),
                ToolParameter(name: "end_line", type: .integer, description: "Ending line number (1-based, inclusive, optional)", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let url = URL(fileURLWithPath: expandedPath)
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            // Provide helpful error with both original and resolved path
            if path != expandedPath {
                return .failure("File not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path like '/full/path/to/file' if CWD is unknown.")
            }
            return .failure("File not found: '\(path)'. Use an absolute path if needed.")
        }
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            
            // Handle line range if specified
            if let startStr = args["start_line"], let startLine = Int(startStr) {
                let endLine = args["end_line"].flatMap { Int($0) }
                let lines = content.components(separatedBy: .newlines)
                let start = max(0, startLine - 1)
                let end = min(lines.count, endLine ?? lines.count)
                
                if start >= lines.count {
                    return .failure("Start line \(startLine) exceeds file length (\(lines.count) lines)")
                }
                
                let selectedLines = lines[start..<end]
                let numberedLines = selectedLines.enumerated().map { 
                    "\(start + $0.offset + 1)| \($0.element)" 
                }.joined(separator: "\n")
                return .success(numberedLines)
            }
            
            // Get dynamic output limit from settings
            // Use _contextTokens arg if provided by session, otherwise use minimum
            let contextTokens = args["_contextTokens"].flatMap { Int($0) } ?? 32_000
            let maxSize = AgentSettings.shared.effectiveOutputCaptureLimit(forContextTokens: contextTokens)
            
            if content.count > maxSize {
                let lines = content.components(separatedBy: .newlines)
                // Use head+tail truncation to show file structure (imports at top, exports/main at bottom)
                let truncated = SmartTruncator.headTail(content, maxChars: maxSize, headRatio: 0.6)
                return .success("File has \(lines.count) lines, \(content.count) chars. Use start_line/end_line for specific sections.\n\n\(truncated)")
            }
            
            return .success(content)
        } catch {
            return .failure("Error reading file: \(error.localizedDescription)")
        }
    }
}
