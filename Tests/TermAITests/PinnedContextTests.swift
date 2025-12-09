import XCTest

// MARK: - Pinned Context Types (self-contained copy for testing)

fileprivate enum PinnedContextType: String, Codable, Equatable {
    case file
    case terminal
    case snippet
}

fileprivate struct LineRange: Codable, Equatable, Hashable {
    let start: Int
    let end: Int
    
    init(start: Int, end: Int) {
        self.start = min(start, end)
        self.end = max(start, end)
    }
    
    init(line: Int) {
        self.start = line
        self.end = line
    }
    
    var description: String {
        start == end ? "L\(start)" : "L\(start)-\(end)"
    }
    
    func contains(_ line: Int) -> Bool {
        line >= start && line <= end
    }
}

// Minimal TokenEstimator for testing
fileprivate enum TokenEstimator {
    static func estimateTokens(_ text: String) -> Int {
        Int(ceil(Double(text.count) / 3.8))
    }
}

fileprivate struct PinnedContext: Codable, Identifiable, Equatable {
    let id: UUID
    let type: PinnedContextType
    let path: String
    let displayName: String
    let content: String
    let fullContent: String?
    let lineRanges: [LineRange]?
    var summary: String?
    let timestamp: Date
    
    var startLine: Int? { lineRanges?.first?.start }
    var endLine: Int? { lineRanges?.last?.end }
    
    init(
        id: UUID = UUID(),
        type: PinnedContextType,
        path: String,
        displayName: String? = nil,
        content: String,
        fullContent: String? = nil,
        lineRanges: [LineRange]? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.type = type
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.content = content
        self.fullContent = fullContent
        self.lineRanges = lineRanges
        self.summary = summary
        self.timestamp = Date()
    }
    
    static func file(path: String, content: String, fullContent: String? = nil, lineRanges: [LineRange]? = nil) -> PinnedContext {
        PinnedContext(type: .file, path: path, content: content, fullContent: fullContent, lineRanges: lineRanges)
    }
    
    static func fileWithLineRange(path: String, content: String, startLine: Int, endLine: Int? = nil) -> PinnedContext {
        let ranges = [LineRange(start: startLine, end: endLine ?? startLine)]
        return PinnedContext(type: .file, path: path, content: content, lineRanges: ranges)
    }
    
    static func terminal(content: String, cwd: String? = nil) -> PinnedContext {
        PinnedContext(type: .terminal, path: cwd ?? "terminal", displayName: "Terminal Output", content: content)
    }
    
    var isLargeContent: Bool {
        TokenEstimator.estimateTokens(content) > 5000
    }
    
    var isPartialFile: Bool {
        lineRanges != nil && !lineRanges!.isEmpty
    }
    
    var lineRangeDescription: String? {
        guard let ranges = lineRanges, !ranges.isEmpty else { return nil }
        if ranges.count == 1 {
            let r = ranges[0]
            return r.start == r.end ? "line \(r.start)" : "lines \(r.start)-\(r.end)"
        } else {
            return ranges.map { $0.description }.joined(separator: ", ")
        }
    }
    
    func isLineSelected(_ lineNumber: Int) -> Bool {
        guard let ranges = lineRanges else { return false }
        return ranges.contains { $0.contains(lineNumber) }
    }
    
    var icon: String {
        switch type {
        case .file: return "doc.text.fill"
        case .terminal: return "terminal.fill"
        case .snippet: return "text.quote"
        }
    }
    
    var language: String? {
        guard type == .file else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "jsx", "tsx": return ext
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "html", "htm": return "html"
        case "css", "scss", "sass": return "css"
        case "rs": return "rust"
        case "go": return "go"
        case "c", "h": return "c"
        case "cpp", "hpp", "cc": return "cpp"
        case "md", "markdown": return "markdown"
        case "sh", "bash", "zsh": return "shell"
        default: return nil
        }
    }
}

// MARK: - Tests

final class PinnedContextTypeTests: XCTestCase {
    
    func testRawValues() {
        XCTAssertEqual(PinnedContextType.file.rawValue, "file")
        XCTAssertEqual(PinnedContextType.terminal.rawValue, "terminal")
        XCTAssertEqual(PinnedContextType.snippet.rawValue, "snippet")
    }
    
    func testCodable_RoundTrip() throws {
        let types: [PinnedContextType] = [.file, .terminal, .snippet]
        for type in types {
            let encoded = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(PinnedContextType.self, from: encoded)
            XCTAssertEqual(type, decoded)
        }
    }
}

final class PinnedContextTests: XCTestCase {
    
    // MARK: - Factory Methods
    
    func testFileFactory_Basic() {
        let ctx = PinnedContext.file(path: "/path/to/file.swift", content: "let x = 1")
        
        XCTAssertEqual(ctx.type, .file)
        XCTAssertEqual(ctx.path, "/path/to/file.swift")
        XCTAssertEqual(ctx.displayName, "file.swift")
        XCTAssertEqual(ctx.content, "let x = 1")
        XCTAssertNil(ctx.lineRanges)
    }
    
    func testFileFactory_WithLineRange() {
        let ctx = PinnedContext.fileWithLineRange(path: "/path/to/file.swift", content: "code", startLine: 10, endLine: 50)
        
        XCTAssertEqual(ctx.lineRanges?.count, 1)
        XCTAssertEqual(ctx.lineRanges?[0].start, 10)
        XCTAssertEqual(ctx.lineRanges?[0].end, 50)
    }
    
    func testFileFactory_WithSingleLine() {
        let ctx = PinnedContext.fileWithLineRange(path: "/path/to/file.swift", content: "line", startLine: 42)
        
        XCTAssertEqual(ctx.lineRanges?.count, 1)
        XCTAssertEqual(ctx.lineRanges?[0].start, 42)
        XCTAssertEqual(ctx.lineRanges?[0].end, 42)
    }
    
    func testFileFactory_WithMultipleRanges() {
        let ranges = [LineRange(start: 10, end: 20), LineRange(start: 50, end: 60)]
        let ctx = PinnedContext.file(path: "/path/to/file.swift", content: "code", fullContent: "full code", lineRanges: ranges)
        
        XCTAssertEqual(ctx.lineRanges?.count, 2)
        XCTAssertEqual(ctx.fullContent, "full code")
    }
    
    func testTerminalFactory() {
        let ctx = PinnedContext.terminal(content: "$ ls -la", cwd: "/home/user")
        
        XCTAssertEqual(ctx.type, .terminal)
        XCTAssertEqual(ctx.path, "/home/user")
        XCTAssertEqual(ctx.displayName, "Terminal Output")
        XCTAssertEqual(ctx.content, "$ ls -la")
    }
    
    func testTerminalFactory_NoCwd() {
        let ctx = PinnedContext.terminal(content: "output")
        XCTAssertEqual(ctx.path, "terminal")
    }
    
    // MARK: - Legacy Accessors
    
    func testStartEndLine_FromRanges() {
        let ranges = [LineRange(start: 10, end: 20), LineRange(start: 50, end: 60)]
        let ctx = PinnedContext.file(path: "/file.swift", content: "code", lineRanges: ranges)
        
        XCTAssertEqual(ctx.startLine, 10)  // First range start
        XCTAssertEqual(ctx.endLine, 60)    // Last range end
    }
    
    func testStartEndLine_NoRanges() {
        let ctx = PinnedContext.file(path: "/file.swift", content: "code")
        XCTAssertNil(ctx.startLine)
        XCTAssertNil(ctx.endLine)
    }
    
    // MARK: - Content Size
    
    func testIsLargeContent_Small() {
        let ctx = PinnedContext.file(path: "/file.swift", content: "small content")
        XCTAssertFalse(ctx.isLargeContent)
    }
    
    func testIsLargeContent_Large() {
        // 5000 tokens * 3.8 chars/token = 19000 chars
        let largeContent = String(repeating: "x", count: 20000)
        let ctx = PinnedContext.file(path: "/file.swift", content: largeContent)
        XCTAssertTrue(ctx.isLargeContent)
    }
    
    // MARK: - Partial File Detection
    
    func testIsPartialFile_WithRanges() {
        let ctx = PinnedContext.fileWithLineRange(path: "/file.swift", content: "code", startLine: 10, endLine: 20)
        XCTAssertTrue(ctx.isPartialFile)
    }
    
    func testIsPartialFile_NoRanges() {
        let ctx = PinnedContext.file(path: "/file.swift", content: "code")
        XCTAssertFalse(ctx.isPartialFile)
    }
    
    func testIsPartialFile_EmptyRanges() {
        let ctx = PinnedContext.file(path: "/file.swift", content: "code", lineRanges: [])
        XCTAssertFalse(ctx.isPartialFile)
    }
    
    // MARK: - Line Range Description
    
    func testLineRangeDescription_SingleRange() {
        let ctx = PinnedContext.fileWithLineRange(path: "/file.swift", content: "code", startLine: 10, endLine: 50)
        XCTAssertEqual(ctx.lineRangeDescription, "lines 10-50")
    }
    
    func testLineRangeDescription_SingleLine() {
        let ctx = PinnedContext.fileWithLineRange(path: "/file.swift", content: "code", startLine: 42)
        XCTAssertEqual(ctx.lineRangeDescription, "line 42")
    }
    
    func testLineRangeDescription_MultipleRanges() {
        let ranges = [LineRange(start: 10, end: 20), LineRange(start: 50, end: 60)]
        let ctx = PinnedContext.file(path: "/file.swift", content: "code", lineRanges: ranges)
        XCTAssertEqual(ctx.lineRangeDescription, "L10-20, L50-60")
    }
    
    func testLineRangeDescription_NoRanges() {
        let ctx = PinnedContext.file(path: "/file.swift", content: "code")
        XCTAssertNil(ctx.lineRangeDescription)
    }
    
    // MARK: - Line Selection
    
    func testIsLineSelected_InRange() {
        let ctx = PinnedContext.fileWithLineRange(path: "/file.swift", content: "code", startLine: 10, endLine: 20)
        XCTAssertTrue(ctx.isLineSelected(10))
        XCTAssertTrue(ctx.isLineSelected(15))
        XCTAssertTrue(ctx.isLineSelected(20))
    }
    
    func testIsLineSelected_OutOfRange() {
        let ctx = PinnedContext.fileWithLineRange(path: "/file.swift", content: "code", startLine: 10, endLine: 20)
        XCTAssertFalse(ctx.isLineSelected(9))
        XCTAssertFalse(ctx.isLineSelected(21))
    }
    
    func testIsLineSelected_MultipleRanges() {
        let ranges = [LineRange(start: 10, end: 20), LineRange(start: 50, end: 60)]
        let ctx = PinnedContext.file(path: "/file.swift", content: "code", lineRanges: ranges)
        
        XCTAssertTrue(ctx.isLineSelected(15))   // In first range
        XCTAssertTrue(ctx.isLineSelected(55))   // In second range
        XCTAssertFalse(ctx.isLineSelected(30))  // Between ranges
    }
    
    func testIsLineSelected_NoRanges() {
        let ctx = PinnedContext.file(path: "/file.swift", content: "code")
        XCTAssertFalse(ctx.isLineSelected(10))
    }
    
    // MARK: - Icons
    
    func testIcon() {
        XCTAssertEqual(PinnedContext.file(path: "/file.swift", content: "").icon, "doc.text.fill")
        XCTAssertEqual(PinnedContext.terminal(content: "").icon, "terminal.fill")
        XCTAssertEqual(PinnedContext(type: .snippet, path: "snippet", content: "code").icon, "text.quote")
    }
    
    // MARK: - Language Detection
    
    func testLanguage_Swift() {
        let ctx = PinnedContext.file(path: "/path/to/File.swift", content: "")
        XCTAssertEqual(ctx.language, "swift")
    }
    
    func testLanguage_Python() {
        let ctx = PinnedContext.file(path: "/path/to/script.py", content: "")
        XCTAssertEqual(ctx.language, "python")
    }
    
    func testLanguage_JavaScript() {
        XCTAssertEqual(PinnedContext.file(path: "/file.js", content: "").language, "javascript")
        XCTAssertEqual(PinnedContext.file(path: "/file.ts", content: "").language, "typescript")
    }
    
    func testLanguage_CFamily() {
        XCTAssertEqual(PinnedContext.file(path: "/file.c", content: "").language, "c")
        XCTAssertEqual(PinnedContext.file(path: "/file.h", content: "").language, "c")
        XCTAssertEqual(PinnedContext.file(path: "/file.cpp", content: "").language, "cpp")
    }
    
    func testLanguage_Others() {
        XCTAssertEqual(PinnedContext.file(path: "/file.rs", content: "").language, "rust")
        XCTAssertEqual(PinnedContext.file(path: "/file.go", content: "").language, "go")
        XCTAssertEqual(PinnedContext.file(path: "/file.json", content: "").language, "json")
        XCTAssertEqual(PinnedContext.file(path: "/file.yaml", content: "").language, "yaml")
        XCTAssertEqual(PinnedContext.file(path: "/file.md", content: "").language, "markdown")
        XCTAssertEqual(PinnedContext.file(path: "/file.sh", content: "").language, "shell")
    }
    
    func testLanguage_Unknown() {
        XCTAssertNil(PinnedContext.file(path: "/file.xyz", content: "").language)
        XCTAssertNil(PinnedContext.file(path: "/file", content: "").language)
    }
    
    func testLanguage_NotFile() {
        let ctx = PinnedContext.terminal(content: "output")
        XCTAssertNil(ctx.language)
    }
    
    // MARK: - Codable
    
    func testCodable_RoundTrip() throws {
        let ranges = [LineRange(start: 10, end: 20)]
        var ctx = PinnedContext.file(path: "/path/to/file.swift", content: "code", fullContent: "full", lineRanges: ranges)
        ctx.summary = "A test file"
        
        let encoded = try JSONEncoder().encode(ctx)
        let decoded = try JSONDecoder().decode(PinnedContext.self, from: encoded)
        
        XCTAssertEqual(ctx.id, decoded.id)
        XCTAssertEqual(ctx.type, decoded.type)
        XCTAssertEqual(ctx.path, decoded.path)
        XCTAssertEqual(ctx.content, decoded.content)
        XCTAssertEqual(ctx.fullContent, decoded.fullContent)
        XCTAssertEqual(ctx.lineRanges, decoded.lineRanges)
        XCTAssertEqual(ctx.summary, decoded.summary)
    }
}
