import Foundation

// MARK: - Project Type Detection

/// Utility for detecting project types from directory contents
public enum ProjectTypeDetector {
    
    /// Detect project types from a list of file/directory names
    /// - Parameter contents: Array of file and directory names in a directory
    /// - Returns: Comma-separated string of detected project types, or "unknown"
    public static func detect(from contents: [String]) -> String {
        var types: [String] = []
        
        // Python
        if contents.contains("requirements.txt") || contents.contains("setup.py") ||
           contents.contains("pyproject.toml") || contents.contains("Pipfile") ||
           contents.contains("venv/") || contents.contains(".venv/") {
            types.append("Python")
        }
        
        // Node.js
        if contents.contains("package.json") {
            types.append("Node.js")
        }
        
        // Swift
        if contents.contains("Package.swift") || contents.contains(where: { $0.hasSuffix(".xcodeproj/") || $0.hasSuffix(".xcworkspace/") }) {
            types.append("Swift")
        }
        
        // Rust
        if contents.contains("Cargo.toml") {
            types.append("Rust")
        }
        
        // Go
        if contents.contains("go.mod") {
            types.append("Go")
        }
        
        // Ruby
        if contents.contains("Gemfile") {
            types.append("Ruby")
        }
        
        // Java/Kotlin
        if contents.contains("pom.xml") || contents.contains("build.gradle") || contents.contains("build.gradle.kts") {
            types.append("Java/Kotlin")
        }
        
        // Docker
        if contents.contains("Dockerfile") || contents.contains("docker-compose.yml") || contents.contains("docker-compose.yaml") {
            types.append("Docker")
        }
        
        // C/C++
        if contents.contains("CMakeLists.txt") || contents.contains("Makefile") ||
           contents.contains("configure.ac") || contents.contains("meson.build") {
            types.append("C/C++")
        }
        
        // .NET
        if contents.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".sln") || $0.hasSuffix(".fsproj") }) {
            types.append(".NET")
        }
        
        return types.isEmpty ? "unknown" : types.joined(separator: ", ")
    }
}

// MARK: - Plan Checklist Parser

/// Utility for parsing checklist items from plan markdown content
public enum PlanChecklistParser {
    
    /// Extract checklist items from plan markdown content
    /// Looks for lines starting with "- [ ]", "- [x]", or "- [X]" in the Checklist section
    /// - Parameter content: Markdown content of a plan
    /// - Returns: Array of task descriptions (without checkbox prefixes)
    public static func extractItems(from content: String) -> [String] {
        var items: [String] = []
        var inChecklistSection = false
        
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Look for Checklist header
            if trimmed.lowercased().contains("## checklist") || trimmed.lowercased() == "checklist" {
                inChecklistSection = true
                continue
            }
            
            // Stop at next section
            if inChecklistSection && trimmed.hasPrefix("##") && !trimmed.lowercased().contains("checklist") {
                break
            }
            
            // Extract checklist items (- [ ] format)
            if inChecklistSection && (trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")) {
                // Remove the checkbox prefix and get the task description
                // Handle both with and without trailing space after checkbox
                var item = trimmed
                if item.hasPrefix("- [ ] ") {
                    item = String(item.dropFirst(6))
                } else if item.hasPrefix("- [x] ") || item.hasPrefix("- [X] ") {
                    item = String(item.dropFirst(6))
                } else if item.hasPrefix("- [ ]") {
                    item = String(item.dropFirst(5))
                } else if item.hasPrefix("- [x]") || item.hasPrefix("- [X]") {
                    item = String(item.dropFirst(5))
                }
                item = item.trimmingCharacters(in: .whitespaces)
                
                if !item.isEmpty {
                    items.append(item)
                }
            }
        }
        
        return items
    }
    
    /// Check if a markdown string contains a checklist section
    /// - Parameter content: Markdown content to check
    /// - Returns: True if content contains a checklist section
    public static func hasChecklist(in content: String) -> Bool {
        let lowercased = content.lowercased()
        return lowercased.contains("## checklist") || lowercased.contains("\nchecklist\n")
    }
}
