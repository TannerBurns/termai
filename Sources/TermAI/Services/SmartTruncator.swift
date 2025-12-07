import Foundation

/// Smart truncation utilities for preserving important context when content exceeds limits
/// These strategies help agents retain critical information like errors at the end of files
/// or important output that might appear anywhere in large outputs
struct SmartTruncator {
    
    // MARK: - Head + Tail Truncation
    
    /// Truncate keeping both the beginning and end of content
    /// Useful for files where imports are at top but errors/exports may be at bottom
    /// - Parameters:
    ///   - content: The content to truncate
    ///   - maxChars: Maximum characters to retain
    ///   - headRatio: Ratio of space to allocate to the head (default 0.6 = 60% head, 40% tail)
    /// - Returns: Truncated content with head, separator, and tail
    static func headTail(_ content: String, maxChars: Int, headRatio: Double = 0.6) -> String {
        guard content.count > maxChars else { return content }
        
        // Reserve some space for the separator message
        let separatorTemplate = "\n\n... [%d characters omitted] ...\n\n"
        let separatorOverhead = 50 // Approximate max separator length
        let availableChars = maxChars - separatorOverhead
        
        guard availableChars > 100 else {
            // Not enough space for meaningful head+tail, just use prefix
            return String(content.prefix(maxChars))
        }
        
        let headChars = Int(Double(availableChars) * headRatio)
        let tailChars = availableChars - headChars
        
        let head = String(content.prefix(headChars))
        let tail = String(content.suffix(tailChars))
        let omittedCount = content.count - headChars - tailChars
        
        let separator = String(format: separatorTemplate, omittedCount)
        
        return head + separator + tail
    }
    
    // MARK: - Error-Prioritized Truncation
    
    /// Truncate but prioritize lines containing errors, warnings, or failures
    /// Useful for build output, test results, and command output
    /// - Parameters:
    ///   - output: The output to truncate
    ///   - maxChars: Maximum characters to retain
    ///   - errorPatterns: Patterns to match for priority lines (case-insensitive)
    /// - Returns: Truncated output with priority lines preserved
    static func prioritizeErrors(
        _ output: String,
        maxChars: Int,
        errorPatterns: [String] = defaultErrorPatterns
    ) -> String {
        guard output.count > maxChars else { return output }
        
        let lines = output.components(separatedBy: .newlines)
        
        // Categorize lines
        var priorityLines: [(index: Int, line: String)] = []
        var normalLines: [(index: Int, line: String)] = []
        
        for (index, line) in lines.enumerated() {
            let lowercaseLine = line.lowercased()
            let isPriority = errorPatterns.contains { pattern in
                lowercaseLine.contains(pattern.lowercased())
            }
            
            if isPriority {
                priorityLines.append((index, line))
            } else {
                normalLines.append((index, line))
            }
        }
        
        // If no priority lines found, fall back to head+tail
        if priorityLines.isEmpty {
            return headTail(output, maxChars: maxChars)
        }
        
        // Build result: priority lines first, then fill with context
        var result: [String] = []
        var usedChars = 0
        
        // Reserve space for header
        let headerLine = "=== Priority lines (errors/warnings) ===\n"
        let contextHeader = "\n=== Context ===\n"
        let headerOverhead = headerLine.count + contextHeader.count + 50
        let availableChars = maxChars - headerOverhead
        
        // Add priority lines (with line numbers for reference)
        result.append(headerLine.trimmingCharacters(in: .newlines))
        for (index, line) in priorityLines {
            let numberedLine = "L\(index + 1): \(line)"
            if usedChars + numberedLine.count + 1 < availableChars / 2 {
                result.append(numberedLine)
                usedChars += numberedLine.count + 1
            }
        }
        
        // Fill remaining space with context (prefer lines near errors)
        result.append(contextHeader.trimmingCharacters(in: .newlines))
        
        // Get indices of priority lines for context selection
        let priorityIndices = Set(priorityLines.map { $0.index })
        
        // Add context lines near priority lines first
        var contextAdded = Set<Int>()
        let contextRadius = 3 // Lines before/after each priority line
        
        for priorityIndex in priorityIndices.sorted() {
            let start = max(0, priorityIndex - contextRadius)
            let end = min(lines.count - 1, priorityIndex + contextRadius)
            
            for i in start...end {
                if !priorityIndices.contains(i) && !contextAdded.contains(i) {
                    let line = lines[i]
                    let numberedLine = "L\(i + 1): \(line)"
                    if usedChars + numberedLine.count + 1 < availableChars {
                        result.append(numberedLine)
                        usedChars += numberedLine.count + 1
                        contextAdded.insert(i)
                    }
                }
            }
        }
        
        // If still have space, add beginning of output for context
        if usedChars < availableChars - 100 {
            result.append("\n=== Start of output ===")
            for i in 0..<min(10, lines.count) {
                if !priorityIndices.contains(i) && !contextAdded.contains(i) {
                    let line = lines[i]
                    if usedChars + line.count + 1 < availableChars {
                        result.append(line)
                        usedChars += line.count + 1
                    }
                }
            }
        }
        
        return result.joined(separator: "\n")
    }
    
    /// Default patterns to identify error/warning lines
    static let defaultErrorPatterns: [String] = [
        "error",
        "error:",
        "failed",
        "failure",
        "exception",
        "fatal",
        "warning",
        "warn:",
        "cannot",
        "could not",
        "unable to",
        "not found",
        "undefined",
        "null pointer",
        "segmentation fault",
        "stack trace",
        "traceback",
        "panic",
        "assert",
        "denied",
        "refused",
        "timeout",
        "timed out",
        "❌",
        "✗",
        "FAIL",
        "ERROR",
        "FATAL"
    ]
    
    // MARK: - Structure-Preserving Truncation
    
    /// Truncate while trying to preserve complete JSON objects or log entries
    /// Useful for API responses or structured logs
    /// - Parameters:
    ///   - content: The structured content to truncate
    ///   - maxChars: Maximum characters to retain
    /// - Returns: Truncated content with complete structures preserved where possible
    static func preserveStructure(_ content: String, maxChars: Int) -> String {
        guard content.count > maxChars else { return content }
        
        // Try to detect if this is JSON
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return truncateJSON(content, maxChars: maxChars)
        }
        
        // Try to detect log-style output (lines starting with timestamps or levels)
        let lines = content.components(separatedBy: .newlines)
        if looksLikeLogOutput(lines) {
            return truncateLogOutput(lines, maxChars: maxChars)
        }
        
        // Fall back to head+tail
        return headTail(content, maxChars: maxChars)
    }
    
    /// Check if output looks like structured log entries
    private static func looksLikeLogOutput(_ lines: [String]) -> Bool {
        guard lines.count > 5 else { return false }
        
        // Check if lines start with common log patterns
        let logPatterns = [
            #"^\d{4}-\d{2}-\d{2}"#,  // Date: 2024-01-15
            #"^\[\d{2}:\d{2}:\d{2}\]"#,  // Time: [14:30:45]
            #"^\[INFO\]"#,
            #"^\[DEBUG\]"#,
            #"^\[ERROR\]"#,
            #"^\[WARN"#,
            #"^INFO "#,
            #"^DEBUG "#,
            #"^ERROR "#
        ]
        
        var matchCount = 0
        for line in lines.prefix(10) {
            for pattern in logPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, options: [], range: range) != nil {
                        matchCount += 1
                        break
                    }
                }
            }
        }
        
        return matchCount >= 3
    }
    
    /// Truncate log output preserving complete log entries
    private static func truncateLogOutput(_ lines: [String], maxChars: Int) -> String {
        var result: [String] = []
        var usedChars = 0
        let separator = "\n... [log entries omitted] ...\n"
        let availableChars = maxChars - separator.count
        
        // Take entries from beginning
        let headBudget = Int(Double(availableChars) * 0.6)
        for line in lines {
            if usedChars + line.count + 1 <= headBudget {
                result.append(line)
                usedChars += line.count + 1
            } else {
                break
            }
        }
        
        result.append(separator.trimmingCharacters(in: .newlines))
        
        // Take entries from end
        var tailLines: [String] = []
        var tailChars = 0
        let tailBudget = availableChars - usedChars
        
        for line in lines.reversed() {
            if tailChars + line.count + 1 <= tailBudget {
                tailLines.insert(line, at: 0)
                tailChars += line.count + 1
            } else {
                break
            }
        }
        
        result.append(contentsOf: tailLines)
        return result.joined(separator: "\n")
    }
    
    /// Truncate JSON trying to preserve complete objects
    private static func truncateJSON(_ content: String, maxChars: Int) -> String {
        // For JSON, we'll try to preserve the structure by finding complete objects
        // This is a simplified approach - for deeply nested JSON, we fall back to head+tail
        
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If it's an array of objects, try to keep complete objects
        if trimmed.hasPrefix("[") {
            return truncateJSONArray(content, maxChars: maxChars)
        }
        
        // For single objects, use head+tail to show structure
        return headTail(content, maxChars: maxChars, headRatio: 0.7)
    }
    
    /// Truncate JSON array keeping complete elements
    private static func truncateJSONArray(_ content: String, maxChars: Int) -> String {
        // Simple approach: try to parse and re-serialize with fewer elements
        guard let data = content.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              array.count > 2 else {
            return headTail(content, maxChars: maxChars)
        }
        
        // Keep first few and last few elements
        let keepCount = max(2, array.count / 4)
        var truncatedArray: [[String: Any]] = []
        
        // Add first elements
        truncatedArray.append(contentsOf: array.prefix(keepCount))
        
        // Add marker
        truncatedArray.append(["_truncated": "... \(array.count - keepCount * 2) items omitted ..."])
        
        // Add last elements
        truncatedArray.append(contentsOf: array.suffix(keepCount))
        
        // Re-serialize
        if let truncatedData = try? JSONSerialization.data(withJSONObject: truncatedArray, options: [.prettyPrinted, .sortedKeys]),
           let truncatedString = String(data: truncatedData, encoding: .utf8),
           truncatedString.count <= maxChars {
            return truncatedString
        }
        
        // If still too long, fall back
        return headTail(content, maxChars: maxChars)
    }
    
    // MARK: - Utility: Line-Based Truncation
    
    /// Truncate to a maximum number of lines, keeping head and tail
    /// - Parameters:
    ///   - content: Content to truncate
    ///   - maxLines: Maximum number of lines to keep
    ///   - headRatio: Ratio of lines to allocate to head (default 0.6)
    /// - Returns: Truncated content
    static func truncateLines(_ content: String, maxLines: Int, headRatio: Double = 0.6) -> String {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count > maxLines else { return content }
        
        let headCount = Int(Double(maxLines) * headRatio)
        let tailCount = maxLines - headCount
        
        let headLines = Array(lines.prefix(headCount))
        let tailLines = Array(lines.suffix(tailCount))
        let omittedCount = lines.count - headCount - tailCount
        
        var result = headLines
        result.append("\n... [\(omittedCount) lines omitted] ...\n")
        result.append(contentsOf: tailLines)
        
        return result.joined(separator: "\n")
    }
    
    // MARK: - Smart Selection Based on Content Type
    
    /// Automatically choose the best truncation strategy based on content analysis
    /// - Parameters:
    ///   - content: Content to truncate
    ///   - maxChars: Maximum characters
    ///   - context: Optional hint about what kind of content this is
    /// - Returns: Truncated content using the most appropriate strategy
    static func smartTruncate(
        _ content: String,
        maxChars: Int,
        context: ContentContext = .unknown
    ) -> String {
        guard content.count > maxChars else { return content }
        
        switch context {
        case .fileContent:
            // Files benefit from seeing beginning (imports) and end (exports, main code)
            return headTail(content, maxChars: maxChars, headRatio: 0.6)
            
        case .commandOutput:
            // Command output often has errors at the end
            return prioritizeErrors(content, maxChars: maxChars)
            
        case .buildOutput:
            // Build output: heavily prioritize errors/warnings
            return prioritizeErrors(content, maxChars: maxChars, errorPatterns: buildErrorPatterns)
            
        case .testOutput:
            // Test output: prioritize failures
            return prioritizeErrors(content, maxChars: maxChars, errorPatterns: testErrorPatterns)
            
        case .apiResponse:
            // API responses are often structured
            return preserveStructure(content, maxChars: maxChars)
            
        case .unknown:
            // Auto-detect based on content
            return autoDetectAndTruncate(content, maxChars: maxChars)
        }
    }
    
    /// Content context hints for smart truncation
    enum ContentContext {
        case fileContent
        case commandOutput
        case buildOutput
        case testOutput
        case apiResponse
        case unknown
    }
    
    /// Patterns specific to build/compile errors
    static let buildErrorPatterns: [String] = defaultErrorPatterns + [
        "undefined reference",
        "linker error",
        "syntax error",
        "parse error",
        "type mismatch",
        "cannot find",
        "no such file",
        "build failed",
        "compilation failed",
        "make: ***",
        "npm ERR!",
        "error TS",
        "error CS",
        "error[E",
        "^~~~"
    ]
    
    /// Patterns specific to test failures
    static let testErrorPatterns: [String] = defaultErrorPatterns + [
        "FAILED",
        "FAIL:",
        "test failed",
        "assertion failed",
        "expected",
        "actual",
        "AssertionError",
        "XCTAssert",
        "expect(",
        "toBe(",
        "toEqual(",
        "not equal",
        "0 passing",
        "tests failed"
    ]
    
    /// Auto-detect content type and apply appropriate truncation
    private static func autoDetectAndTruncate(_ content: String, maxChars: Int) -> String {
        let lowercased = content.lowercased()
        
        // Check for test output patterns
        if lowercased.contains("test") && (lowercased.contains("pass") || lowercased.contains("fail")) {
            return prioritizeErrors(content, maxChars: maxChars, errorPatterns: testErrorPatterns)
        }
        
        // Check for build output patterns
        if lowercased.contains("compiling") || lowercased.contains("building") || lowercased.contains("linking") {
            return prioritizeErrors(content, maxChars: maxChars, errorPatterns: buildErrorPatterns)
        }
        
        // Check for JSON structure
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return preserveStructure(content, maxChars: maxChars)
        }
        
        // Check for log-style output
        let lines = content.components(separatedBy: .newlines)
        if looksLikeLogOutput(lines) {
            return preserveStructure(content, maxChars: maxChars)
        }
        
        // Check if there are any error patterns present
        let hasErrors = defaultErrorPatterns.contains { pattern in
            lowercased.contains(pattern.lowercased())
        }
        
        if hasErrors {
            return prioritizeErrors(content, maxChars: maxChars)
        }
        
        // Default to head+tail
        return headTail(content, maxChars: maxChars)
    }
}

