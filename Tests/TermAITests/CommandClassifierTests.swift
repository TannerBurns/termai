import XCTest
@testable import TermAI

final class CommandClassifierTests: XCTestCase {
    
    // MARK: - Test Universal Commands
    
    func testUniversalCommands() {
        let universalCommands = ["ls", "pwd", "clear", "whoami", "date", "top", "ssh", "man"]
        
        for cmd in universalCommands {
            let result = CommandClassifier.classify(cmd, currentCWD: "/Users/test")
            XCTAssertEqual(result, .universal, "Expected '\(cmd)' to be classified as universal")
        }
    }
    
    func testUniversalCommandsAreCaseInsensitive() {
        // ls should work even with uppercase (though rare)
        let result = CommandClassifier.classify("LS", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal)
    }
    
    func testUniversalCommandsWithArguments() {
        // Universal commands with arguments should still be universal
        // (the base command is what matters, not the arguments)
        let result = CommandClassifier.classify("ls -la", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal)
        
        let result2 = CommandClassifier.classify("grep pattern file.txt", currentCWD: "/Users/test")
        // grep is a universal command - the file might not exist elsewhere but grep itself works anywhere
        XCTAssertEqual(result2, .universal)
    }
    
    // MARK: - Test CD Command Special Handling
    
    func testCdNoArgs() {
        let result = CommandClassifier.classify("cd", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal, "cd with no args should be universal (goes to home)")
    }
    
    func testCdHome() {
        let result = CommandClassifier.classify("cd ~", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal)
    }
    
    func testCdHomePath() {
        let result = CommandClassifier.classify("cd ~/Documents", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal)
    }
    
    func testCdAbsolutePath() {
        let result = CommandClassifier.classify("cd /usr/local/bin", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal)
    }
    
    func testCdDash() {
        let result = CommandClassifier.classify("cd -", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal, "cd - (previous directory) should be universal")
    }
    
    func testCdRelativePath() {
        let result = CommandClassifier.classify("cd src", currentCWD: "/Users/test/project")
        XCTAssertEqual(result, .pathDependent, "cd to relative path may not exist elsewhere")
    }
    
    // MARK: - Test Git Command Special Handling
    
    func testGitStatusIsUniversal() {
        let result = CommandClassifier.classify("git status", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal)
    }
    
    func testGitLogIsUniversal() {
        let result = CommandClassifier.classify("git log", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal)
    }
    
    func testGitBranchIsUniversal() {
        let result = CommandClassifier.classify("git branch", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal)
    }
    
    func testGitCommitIsProjectSpecific() {
        let result = CommandClassifier.classify("git commit -m 'message'", currentCWD: "/Users/test")
        if case .projectSpecific = result {
            // Expected
        } else {
            XCTFail("Expected git commit to be project-specific")
        }
    }
    
    func testGitPushIsProjectSpecific() {
        let result = CommandClassifier.classify("git push origin main", currentCWD: "/Users/test")
        if case .projectSpecific = result {
            // Expected
        } else {
            XCTFail("Expected git push to be project-specific")
        }
    }
    
    // MARK: - Test Project-Specific Commands
    
    func testNpmIsNodeProject() {
        let result = CommandClassifier.classify("npm install", currentCWD: "/Users/test")
        if case .projectSpecific(let type) = result {
            XCTAssertEqual(type, .node)
        } else {
            XCTFail("Expected npm to be project-specific for Node.js")
        }
    }
    
    func testYarnIsNodeProject() {
        let result = CommandClassifier.classify("yarn add lodash", currentCWD: "/Users/test")
        if case .projectSpecific(let type) = result {
            XCTAssertEqual(type, .node)
        } else {
            XCTFail("Expected yarn to be project-specific for Node.js")
        }
    }
    
    func testCargoIsRustProject() {
        let result = CommandClassifier.classify("cargo build", currentCWD: "/Users/test")
        if case .projectSpecific(let type) = result {
            XCTAssertEqual(type, .rust)
        } else {
            XCTFail("Expected cargo to be project-specific for Rust")
        }
    }
    
    func testSwiftIsSwiftProject() {
        let result = CommandClassifier.classify("swift build", currentCWD: "/Users/test")
        if case .projectSpecific(let type) = result {
            XCTAssertEqual(type, .swift)
        } else {
            XCTFail("Expected swift to be project-specific for Swift")
        }
    }
    
    func testGoIsGoProject() {
        let result = CommandClassifier.classify("go build", currentCWD: "/Users/test")
        if case .projectSpecific(let type) = result {
            XCTAssertEqual(type, .go)
        } else {
            XCTFail("Expected go to be project-specific for Go")
        }
    }
    
    func testPythonIsPythonProject() {
        let result = CommandClassifier.classify("python main.py", currentCWD: "/Users/test")
        if case .projectSpecific(let type) = result {
            XCTAssertEqual(type, .python)
        } else {
            XCTFail("Expected python to be project-specific for Python")
        }
    }
    
    func testMvnIsJavaProject() {
        let result = CommandClassifier.classify("mvn clean install", currentCWD: "/Users/test")
        if case .projectSpecific(let type) = result {
            XCTAssertEqual(type, .java)
        } else {
            XCTFail("Expected mvn to be project-specific for Java")
        }
    }
    
    func testDotnetIsDotnetProject() {
        let result = CommandClassifier.classify("dotnet build", currentCWD: "/Users/test")
        if case .projectSpecific(let type) = result {
            XCTAssertEqual(type, .dotnet)
        } else {
            XCTFail("Expected dotnet to be project-specific for .NET")
        }
    }
    
    func testBundleIsRubyProject() {
        let result = CommandClassifier.classify("bundle install", currentCWD: "/Users/test")
        if case .projectSpecific(let type) = result {
            XCTAssertEqual(type, .ruby)
        } else {
            XCTFail("Expected bundle to be project-specific for Ruby")
        }
    }
    
    // MARK: - Test Path-Dependent Commands
    
    func testCommandWithRelativePath() {
        // Direct script execution is path-dependent
        let result = CommandClassifier.classify("./script.sh", currentCWD: "/Users/test")
        XCTAssertEqual(result, .pathDependent)
    }
    
    func testCommandWithParentPath() {
        // cat is a universal command - even with ../ in args, the base command works anywhere
        // The path-dependent check only triggers for non-universal commands
        let result = CommandClassifier.classify("cat ../config.yaml", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal)
    }
    
    func testCommandWithFilePath() {
        // vim is a universal command - even with path args, vim itself works anywhere
        let result = CommandClassifier.classify("vim src/main.rs", currentCWD: "/Users/test")
        XCTAssertEqual(result, .universal)
    }
    
    func testNonUniversalWithPath() {
        // A custom command with path is path-dependent
        let result = CommandClassifier.classify("myapp src/config.json", currentCWD: "/Users/test")
        XCTAssertEqual(result, .pathDependent)
    }
    
    // MARK: - Test Ambiguous Commands
    
    func testUnknownCommand() {
        let result = CommandClassifier.classify("myCustomCommand", currentCWD: "/Users/test")
        XCTAssertEqual(result, .ambiguous)
    }
    
    func testEmptyCommand() {
        let result = CommandClassifier.classify("", currentCWD: "/Users/test")
        XCTAssertEqual(result, .ambiguous)
    }
    
    func testWhitespaceOnlyCommand() {
        let result = CommandClassifier.classify("   ", currentCWD: "/Users/test")
        XCTAssertEqual(result, .ambiguous)
    }
    
    // MARK: - Test isRelevantInDirectory
    
    func testUniversalCommandIsAlwaysRelevant() {
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let result = CommandClassifier.isRelevantInDirectory("ls -la", cwd: "/Users/test", envContext: envContext)
        XCTAssertTrue(result)
    }
    
    func testProjectCommandRelevantInMatchingProject() {
        var envContext = EnvironmentContext()
        envContext.projectType = .node
        
        let result = CommandClassifier.isRelevantInDirectory("npm install", cwd: "/Users/test/node-project", envContext: envContext)
        XCTAssertTrue(result)
    }
    
    func testProjectCommandNotRelevantInWrongProject() {
        var envContext = EnvironmentContext()
        envContext.projectType = .rust  // Rust project, not Node
        
        let result = CommandClassifier.isRelevantInDirectory("npm install", cwd: "/Users/test/rust-project", envContext: envContext)
        XCTAssertFalse(result)
    }
    
    func testProjectCommandNotRelevantInUnknownProject() {
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let result = CommandClassifier.isRelevantInDirectory("npm install", cwd: "/Users/test", envContext: envContext)
        XCTAssertFalse(result)
    }
    
    func testPathDependentCommandNotRelevant() {
        var envContext = EnvironmentContext()
        envContext.projectType = .node
        
        let result = CommandClassifier.isRelevantInDirectory("./build.sh", cwd: "/Users/test", envContext: envContext)
        XCTAssertFalse(result)
    }
    
    func testAmbiguousCommandIsRelevant() {
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let result = CommandClassifier.isRelevantInDirectory("myCommand", cwd: "/Users/test", envContext: envContext)
        XCTAssertTrue(result)
    }
    
    // MARK: - Test filterForCurrentContext
    
    func testFilterInHomeDirectory() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let commands = [
            CommandFrequency(command: "ls", count: 10, lastUsed: nil),
            CommandFrequency(command: "npm install", count: 5, lastUsed: nil),
            CommandFrequency(command: "pwd", count: 3, lastUsed: nil),
            CommandFrequency(command: "./run.sh", count: 2, lastUsed: nil),
        ]
        
        let filtered = CommandClassifier.filterForCurrentContext(
            commands: commands,
            cwd: homeDir,
            envContext: envContext
        )
        
        // Only universal commands should remain when in home directory
        XCTAssertTrue(filtered.contains { $0.command == "ls" })
        XCTAssertTrue(filtered.contains { $0.command == "pwd" })
        XCTAssertFalse(filtered.contains { $0.command == "npm install" })
        XCTAssertFalse(filtered.contains { $0.command == "./run.sh" })
    }
    
    func testFilterInProjectDirectory() {
        var envContext = EnvironmentContext()
        envContext.projectType = .node
        
        let commands = [
            CommandFrequency(command: "ls", count: 10, lastUsed: nil),
            CommandFrequency(command: "npm install", count: 5, lastUsed: nil),
            CommandFrequency(command: "cargo build", count: 3, lastUsed: nil),  // Wrong project type
        ]
        
        let filtered = CommandClassifier.filterForCurrentContext(
            commands: commands,
            cwd: "/Users/test/my-node-project",
            envContext: envContext
        )
        
        // Universal and matching project commands should remain
        XCTAssertTrue(filtered.contains { $0.command == "ls" })
        XCTAssertTrue(filtered.contains { $0.command == "npm install" })
        XCTAssertFalse(filtered.contains { $0.command == "cargo build" })
    }
    
    func testFilterAmbiguousInHomeDir() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        var envContext = EnvironmentContext()
        envContext.projectType = .unknown
        
        let commands = [
            CommandFrequency(command: "myCommand", count: 5, lastUsed: nil),          // Simple ambiguous - should pass
            CommandFrequency(command: "run file.txt", count: 3, lastUsed: nil),       // Has dot - path-dependent, should fail
            CommandFrequency(command: "cat path/to/file", count: 2, lastUsed: nil),   // cat is universal - should pass
        ]
        
        let filtered = CommandClassifier.filterForCurrentContext(
            commands: commands,
            cwd: homeDir,
            envContext: envContext
        )
        
        XCTAssertTrue(filtered.contains { $0.command == "myCommand" })
        XCTAssertFalse(filtered.contains { $0.command == "run file.txt" })
        // cat is universal, so it passes even with path args
        XCTAssertTrue(filtered.contains { $0.command == "cat path/to/file" })
    }
}

// MARK: - CommandContextType Equatable Extension for Testing

extension CommandContextType: Equatable {
    public static func == (lhs: CommandContextType, rhs: CommandContextType) -> Bool {
        switch (lhs, rhs) {
        case (.universal, .universal):
            return true
        case (.pathDependent, .pathDependent):
            return true
        case (.ambiguous, .ambiguous):
            return true
        case (.projectSpecific(let lhsType), .projectSpecific(let rhsType)):
            return lhsType == rhsType
        default:
            return false
        }
    }
}
