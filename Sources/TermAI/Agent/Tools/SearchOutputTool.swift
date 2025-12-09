import Foundation

// MARK: - Search Output Tool

struct SearchOutputTool: AgentTool {
    let name = "search_output"
    let description = "Search through previous command outputs. Args: pattern (required), context_lines (optional, default: 3)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search through previous command outputs for a pattern",
            parameters: [
                ToolParameter(name: "pattern", type: .string, description: "Search pattern to find in previous outputs", required: true),
                ToolParameter(name: "context_lines", type: .integer, description: "Number of context lines around matches (default: 3)", required: false)
            ]
        )
    }
    
    private let buffer: OutputBuffer
    
    init(buffer: OutputBuffer) {
        self.buffer = buffer
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let pattern = args["pattern"], !pattern.isEmpty else {
            return .failure("Missing required argument: pattern")
        }
        
        let contextLines = args["context_lines"].flatMap { Int($0) } ?? 3
        let matches = buffer.search(pattern: pattern, contextLines: contextLines)
        
        if matches.isEmpty {
            return .success("No matches found for '\(pattern)'")
        }
        
        var output: [String] = ["Found \(matches.count) matches for '\(pattern)':\n"]
        for (index, match) in matches.prefix(20).enumerated() {
            output.append("--- Match \(index + 1) (from '\(match.command)', line \(match.lineNumber)) ---")
            output.append(match.context)
            output.append("")
        }
        
        if matches.count > 20 {
            output.append("... and \(matches.count - 20) more matches")
        }
        
        return .success(output.joined(separator: "\n"))
    }
}
