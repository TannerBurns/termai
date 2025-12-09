import XCTest
@testable import TermAI

/// Tests for project type detection functionality
final class ProjectDetectionTests: XCTestCase {
    
    var testDir: URL!
    
    override func setUp() {
        super.setUp()
        // Create a temporary directory for tests
        testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        // Clean up test directory
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func createFile(_ name: String, in dir: URL? = nil) {
        let directory = dir ?? testDir!
        let filePath = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: filePath.path, contents: nil)
    }
    
    private func createSubdirectory(_ name: String) -> URL {
        let subdir = testDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        return subdir
    }
    
    // MARK: - Test Node.js Detection
    
    func testDetectNodeProject() {
        createFile("package.json")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .node)
    }
    
    // MARK: - Test Swift Detection
    
    func testDetectSwiftProject() {
        createFile("Package.swift")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .swift)
    }
    
    // MARK: - Test Rust Detection
    
    func testDetectRustProject() {
        createFile("Cargo.toml")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .rust)
    }
    
    // MARK: - Test Python Detection
    
    func testDetectPythonFromPyproject() {
        createFile("pyproject.toml")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .python)
    }
    
    func testDetectPythonFromSetupPy() {
        createFile("setup.py")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .python)
    }
    
    func testDetectPythonFromRequirements() {
        createFile("requirements.txt")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .python)
    }
    
    // MARK: - Test Go Detection
    
    func testDetectGoProject() {
        createFile("go.mod")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .go)
    }
    
    // MARK: - Test Ruby Detection
    
    func testDetectRubyProject() {
        createFile("Gemfile")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .ruby)
    }
    
    // MARK: - Test Java Detection
    
    func testDetectMavenProject() {
        createFile("pom.xml")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .java)
    }
    
    func testDetectGradleProject() {
        createFile("build.gradle")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .java)
    }
    
    func testDetectGradleKotlinProject() {
        createFile("build.gradle.kts")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .java)
    }
    
    // MARK: - Test .NET Detection
    
    func testDetectDotnetFromCsproj() {
        createFile("MyProject.csproj")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .dotnet)
    }
    
    func testDetectDotnetFromSln() {
        createFile("MySolution.sln")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .dotnet)
    }
    
    // MARK: - Test Unknown Project
    
    func testDetectUnknownProject() {
        // Empty directory
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .unknown)
    }
    
    func testDetectUnknownWithRandomFiles() {
        createFile("README.md")
        createFile("config.yaml")
        createFile("data.json")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .unknown)
    }
    
    // MARK: - Test Priority Order
    
    func testPackageJsonTakesPriority() {
        // When multiple project files exist, order matters
        // package.json should be detected first
        createFile("package.json")
        createFile("Cargo.toml")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        // The order in the markers array determines priority
        XCTAssertEqual(result, .node)
    }
    
    func testSwiftBeforeRust() {
        createFile("Package.swift")
        createFile("Cargo.toml")
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: testDir.path)
        XCTAssertEqual(result, .swift)
    }
    
    // MARK: - Test Non-Existent Path
    
    func testNonExistentPath() {
        let fakePath = "/this/path/does/not/exist/\(UUID().uuidString)"
        
        let result = EnvironmentContextProvider.shared.detectProjectType(at: fakePath)
        XCTAssertEqual(result, .unknown)
    }
    
    // MARK: - Test ProjectType Common Commands
    
    func testNodeCommonCommands() {
        let commands = ProjectType.node.commonCommands
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.contains { $0.command == "npm install" })
        XCTAssertTrue(commands.contains { $0.command == "npm test" })
    }
    
    func testSwiftCommonCommands() {
        let commands = ProjectType.swift.commonCommands
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.contains { $0.command == "swift build" })
        XCTAssertTrue(commands.contains { $0.command == "swift test" })
    }
    
    func testRustCommonCommands() {
        let commands = ProjectType.rust.commonCommands
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.contains { $0.command == "cargo build" })
        XCTAssertTrue(commands.contains { $0.command == "cargo test" })
    }
    
    func testPythonCommonCommands() {
        let commands = ProjectType.python.commonCommands
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.contains { $0.command == "pytest" })
    }
    
    func testGoCommonCommands() {
        let commands = ProjectType.go.commonCommands
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.contains { $0.command == "go build" })
        XCTAssertTrue(commands.contains { $0.command == "go test ./..." })
    }
    
    func testUnknownHasNoCommands() {
        let commands = ProjectType.unknown.commonCommands
        XCTAssertTrue(commands.isEmpty)
    }
}
