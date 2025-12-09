import XCTest
@testable import TermAI

/// Tests for suggestion parsing and CWD validation functionality
final class SuggestionParsingTests: XCTestCase {
    
    var testDir: URL!
    
    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func createFile(_ name: String) {
        let filePath = testDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: filePath.path, contents: nil)
    }
    
    // MARK: - Test Parse Suggestions from JSON
    
    func testParseSimpleJsonArray() {
        let json = """
        [{"command": "npm install", "reason": "Install dependencies", "source": "projectContext"}]
        """
        
        let suggestions = SuggestionGenerator.parseSuggestions(from: json)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.command, "npm install")
        XCTAssertEqual(suggestions.first?.reason, "Install dependencies")
        XCTAssertEqual(suggestions.first?.source, .projectContext)
    }
    
    func testParseMultipleSuggestions() {
        let json = """
        [
            {"command": "git status", "reason": "Check status", "source": "gitStatus"},
            {"command": "npm test", "reason": "Run tests", "source": "projectContext"},
            {"command": "ls -la", "reason": "List files", "source": "generalContext"}
        ]
        """
        
        let suggestions = SuggestionGenerator.parseSuggestions(from: json)
        XCTAssertEqual(suggestions.count, 3)
        XCTAssertEqual(suggestions[0].command, "git status")
        XCTAssertEqual(suggestions[1].command, "npm test")
        XCTAssertEqual(suggestions[2].command, "ls -la")
    }
    
    func testParseJsonInMarkdownCodeBlock() {
        let response = """
        Here are some suggestions:
        
        ```json
        [{"command": "cargo build", "reason": "Build project", "source": "projectContext"}]
        ```
        
        Let me know if you need more!
        """
        
        let suggestions = SuggestionGenerator.parseSuggestions(from: response)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.command, "cargo build")
    }
    
    func testParseJsonWithoutSourceField() {
        let json = """
        [{"command": "ls", "reason": "List files"}]
        """
        
        let suggestions = SuggestionGenerator.parseSuggestions(from: json)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.source, .generalContext)  // Default source
    }
    
    func testParseLimitsToThreeSuggestions() {
        let json = """
        [
            {"command": "cmd1", "reason": "r1"},
            {"command": "cmd2", "reason": "r2"},
            {"command": "cmd3", "reason": "r3"},
            {"command": "cmd4", "reason": "r4"},
            {"command": "cmd5", "reason": "r5"}
        ]
        """
        
        let suggestions = SuggestionGenerator.parseSuggestions(from: json)
        XCTAssertEqual(suggestions.count, 3)
    }
    
    func testParseTruncatesLongReasons() {
        let json = """
        [{"command": "git status", "reason": "This is a very long reason that should be truncated to keep the UI clean and readable for users"}]
        """
        
        let suggestions = SuggestionGenerator.parseSuggestions(from: json)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertLessThanOrEqual(suggestions.first?.reason.count ?? 100, 35)
    }
    
    func testParseJsonWithExtraText() {
        let response = """
        Based on your terminal context, here are my suggestions:
        [{"command": "npm start", "reason": "Start server"}]
        These should help you get started!
        """
        
        let suggestions = SuggestionGenerator.parseSuggestions(from: response)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.command, "npm start")
    }
    
    func testParseInvalidJson() {
        let badJson = "This is not JSON at all"
        
        let suggestions = SuggestionGenerator.parseSuggestions(from: badJson)
        XCTAssertTrue(suggestions.isEmpty)
    }
    
    func testParseEmptyArray() {
        let json = "[]"
        
        let suggestions = SuggestionGenerator.parseSuggestions(from: json)
        XCTAssertTrue(suggestions.isEmpty)
    }
    
    func testParseMalformedJson() {
        let badJson = "[{command: npm install}]"  // Missing quotes
        
        let suggestions = SuggestionGenerator.parseSuggestions(from: badJson)
        XCTAssertTrue(suggestions.isEmpty)
    }
    
    // MARK: - Test CWD Validation
    
    func testFiltersCdToCurrentDirectory() {
        var envContext = EnvironmentContext()
        envContext.projectType = .node
        
        let suggestions = [
            createSuggestion("cd /tmp/testdir"),
            createSuggestion("npm install"),
        ]
        
        let filtered = SuggestionGenerator.validateSuggestionsForCWD(
            suggestions,
            cwd: "/tmp/testdir",
            envContext: envContext
        )
        
        // cd to current directory should be filtered out
        XCTAssertFalse(filtered.contains { $0.command == "cd /tmp/testdir" })
        XCTAssertTrue(filtered.contains { $0.command == "npm install" })
    }
    
    func testFiltersCdToCurrentDirectoryWithRelativePath() {
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let suggestions = [
            createSuggestion("cd ."),
            createSuggestion("ls -la"),
        ]
        
        let filtered = SuggestionGenerator.validateSuggestionsForCWD(
            suggestions,
            cwd: testDir.path,
            envContext: envContext
        )
        
        XCTAssertFalse(filtered.contains { $0.command == "cd ." })
        XCTAssertTrue(filtered.contains { $0.command == "ls -la" })
    }
    
    func testAllowsCdToParentDirectory() {
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let suggestions = [
            createSuggestion("cd .."),
        ]
        
        let filtered = SuggestionGenerator.validateSuggestionsForCWD(
            suggestions,
            cwd: testDir.path,
            envContext: envContext
        )
        
        XCTAssertTrue(filtered.contains { $0.command == "cd .." })
    }
    
    func testFiltersProjectCommandsInHomeDir() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown  // No project files in home
        
        let suggestions = [
            createSuggestion("npm install"),
            createSuggestion("cargo build"),
            createSuggestion("ls -la"),
        ]
        
        let filtered = SuggestionGenerator.validateSuggestionsForCWD(
            suggestions,
            cwd: homeDir,
            envContext: envContext
        )
        
        // Project commands should be filtered in home dir with no project
        XCTAssertFalse(filtered.contains { $0.command == "npm install" })
        XCTAssertFalse(filtered.contains { $0.command == "cargo build" })
        XCTAssertTrue(filtered.contains { $0.command == "ls -la" })
    }
    
    func testAllowsProjectCommandsInProjectDir() {
        var envContext = EnvironmentContext()
        envContext.projectType = .node
        
        let suggestions = [
            createSuggestion("npm install"),
            createSuggestion("npm test"),
        ]
        
        let filtered = SuggestionGenerator.validateSuggestionsForCWD(
            suggestions,
            cwd: "/Users/test/my-node-project",
            envContext: envContext
        )
        
        XCTAssertEqual(filtered.count, 2)
    }
    
    func testFiltersNonExistentFilePaths() {
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let suggestions = [
            createSuggestion("cat nonexistent.txt"),
            createSuggestion("ls -la"),
        ]
        
        let filtered = SuggestionGenerator.validateSuggestionsForCWD(
            suggestions,
            cwd: testDir.path,
            envContext: envContext
        )
        
        // Should filter out command referencing non-existent file
        XCTAssertFalse(filtered.contains { $0.command == "cat nonexistent.txt" })
        XCTAssertTrue(filtered.contains { $0.command == "ls -la" })
    }
    
    func testAllowsExistingFilePaths() {
        createFile("existing.txt")
        
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let suggestions = [
            createSuggestion("cat existing.txt"),
        ]
        
        let filtered = SuggestionGenerator.validateSuggestionsForCWD(
            suggestions,
            cwd: testDir.path,
            envContext: envContext
        )
        
        XCTAssertTrue(filtered.contains { $0.command == "cat existing.txt" })
    }
    
    func testAllowsFileCreationCommands() {
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let suggestions = [
            createSuggestion("touch newfile.txt"),
            createSuggestion("mkdir newfolder"),
            createSuggestion("vim newfile.js"),
        ]
        
        let filtered = SuggestionGenerator.validateSuggestionsForCWD(
            suggestions,
            cwd: testDir.path,
            envContext: envContext
        )
        
        // File creation commands should pass even for non-existent paths
        XCTAssertEqual(filtered.count, 3)
    }
    
    func testFiltersHomeCdWhenAlreadyInHome() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let suggestions = [
            createSuggestion("cd ~"),
            createSuggestion("cd"),
        ]
        
        let filtered = SuggestionGenerator.validateSuggestionsForCWD(
            suggestions,
            cwd: homeDir,
            envContext: envContext
        )
        
        // Both should be filtered when already in home
        XCTAssertTrue(filtered.isEmpty)
    }
    
    func testAllowsHomeCdWhenNotInHome() {
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let suggestions = [
            createSuggestion("cd ~"),
        ]
        
        let filtered = SuggestionGenerator.validateSuggestionsForCWD(
            suggestions,
            cwd: testDir.path,
            envContext: envContext
        )
        
        XCTAssertTrue(filtered.contains { $0.command == "cd ~" })
    }
    
    // MARK: - Helper
    
    private func createSuggestion(_ command: String) -> CommandSuggestion {
        return CommandSuggestion(
            command: command,
            reason: "Test",
            confidence: 0.8,
            source: .generalContext
        )
    }
}
