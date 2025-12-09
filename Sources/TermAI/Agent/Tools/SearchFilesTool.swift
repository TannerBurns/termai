import Foundation

// MARK: - Search Files Tool

struct SearchFilesTool: AgentTool {
    let name = "search_files"
    let description = "Search for files by name pattern. Args: path (required), pattern (required, e.g. '*.swift'), recursive (optional, default: true)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Search for files by name pattern (glob)",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Directory path to search in", required: true),
                ToolParameter(name: "pattern", type: .string, description: "Glob pattern to match (e.g., '*.swift', 'test_*.py')", required: true),
                ToolParameter(name: "recursive", type: .boolean, description: "Search recursively (default: true)", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        guard let pattern = args["pattern"], !pattern.isEmpty else {
            return .failure("Missing required argument: pattern")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let url = URL(fileURLWithPath: expandedPath)
        let recursive = args["recursive"]?.lowercased() != "false"
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // Provide helpful error with both original and resolved path
            if path != expandedPath {
                return .failure("Directory not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path like '/full/path/to/dir' if CWD is unknown.")
            }
            return .failure("Directory not found: '\(path)'. Use an absolute path if needed.")
        }
        
        // Convert glob pattern to a simple check
        let patternParts = pattern.components(separatedBy: "*")
        
        var matches: [String] = []
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let filename = fileURL.lastPathComponent
            
            // Simple glob matching
            var isMatch = true
            var remaining = filename
            for (index, part) in patternParts.enumerated() {
                if part.isEmpty { continue }
                if index == 0 && !part.isEmpty {
                    // Must start with this
                    if !remaining.hasPrefix(part) {
                        isMatch = false
                        break
                    }
                    remaining = String(remaining.dropFirst(part.count))
                } else if index == patternParts.count - 1 && !part.isEmpty {
                    // Must end with this
                    if !remaining.hasSuffix(part) {
                        isMatch = false
                        break
                    }
                } else if !part.isEmpty {
                    // Must contain this
                    if let range = remaining.range(of: part) {
                        remaining = String(remaining[range.upperBound...])
                    } else {
                        isMatch = false
                        break
                    }
                }
            }
            
            if isMatch {
                let relativePath = fileURL.path.replacingOccurrences(of: expandedPath, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                matches.append(relativePath)
                
                if matches.count > 200 { break } // Limit for safety
            }
        }
        
        if matches.isEmpty {
            return .success("No files matching '\(pattern)' found in \(path)")
        }
        
        return .success("Found \(matches.count) files:\n\(matches.joined(separator: "\n"))")
    }
}
