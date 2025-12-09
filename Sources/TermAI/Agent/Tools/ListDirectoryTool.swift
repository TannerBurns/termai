import Foundation

// MARK: - List Directory Tool

struct ListDirectoryTool: AgentTool {
    let name = "list_dir"
    let description = "List contents of a directory. Args: path (required), recursive (optional, 'true'/'false', default: false)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List contents of a directory",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Path to the directory to list", required: true),
                ToolParameter(name: "recursive", type: .boolean, description: "List recursively (default: false)", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let path = args["path"], !path.isEmpty else {
            return .failure("Missing required argument: path")
        }
        
        let expandedPath = resolvePath(path, cwd: cwd)
        let url = URL(fileURLWithPath: expandedPath)
        let recursive = args["recursive"]?.lowercased() == "true"
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // Provide helpful error with both original and resolved path
            if path != expandedPath {
                return .failure("Directory not found: '\(path)' (resolved to: '\(expandedPath)'). Use an absolute path like '/full/path/to/dir' if CWD is unknown.")
            }
            return .failure("Directory not found: '\(path)'. Use an absolute path if needed.")
        }
        
        do {
            let contents: [URL]
            if recursive {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                var urls: [URL] = []
                while let fileURL = enumerator?.nextObject() as? URL {
                    urls.append(fileURL)
                    if urls.count > 500 { break } // Limit for safety
                }
                contents = urls
            } else {
                contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            }
            
            var output: [String] = []
            let baseURL = URL(fileURLWithPath: expandedPath).standardized
            for item in contents.sorted(by: { $0.path < $1.path }) {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                // Use proper path relativization instead of string replacement
                let itemStandardized = item.standardized
                let relativePath: String
                if itemStandardized.path.hasPrefix(baseURL.path + "/") {
                    relativePath = String(itemStandardized.path.dropFirst(baseURL.path.count + 1))
                } else if itemStandardized.path == baseURL.path {
                    relativePath = "."
                } else {
                    // Fallback to just the filename if paths don't match
                    relativePath = item.lastPathComponent
                }
                let suffix = isDir ? "/" : ""
                output.append("\(relativePath)\(suffix)")
            }
            
            if output.isEmpty {
                return .success("(empty directory)")
            }
            
            return .success(output.joined(separator: "\n"))
        } catch {
            return .failure("Error listing directory: \(error.localizedDescription)")
        }
    }
}
