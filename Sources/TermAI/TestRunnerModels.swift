import Foundation

// MARK: - Test Runner Status

/// Overall status of a test run
enum TestRunnerStatus: Equatable {
    case idle
    case analyzing
    case blocked([TestBlocker])
    case running(progress: TestRunProgress)
    case completed(TestRunSummary)
    case failed(String)
    case cancelled
    
    var isActive: Bool {
        switch self {
        case .analyzing, .running:
            return true
        default:
            return false
        }
    }
    
    var displayTitle: String {
        switch self {
        case .idle: return "Ready"
        case .analyzing: return "Analyzing Project..."
        case .blocked: return "Blocked"
        case .running: return "Running Tests..."
        case .completed: return "Tests Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
    
    var icon: String {
        switch self {
        case .idle: return "play.circle"
        case .analyzing: return "magnifyingglass"
        case .blocked: return "exclamationmark.triangle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }
}

// MARK: - Test Run Progress

/// Progress information during test execution
struct TestRunProgress: Equatable {
    var currentTest: String?
    var testsRun: Int
    var totalTests: Int?
    var elapsedTime: TimeInterval
    
    var progressPercent: Double? {
        guard let total = totalTests, total > 0 else { return nil }
        return Double(testsRun) / Double(total)
    }
    
    var progressDescription: String {
        if let total = totalTests {
            return "\(testsRun)/\(total) tests"
        }
        return "\(testsRun) tests run"
    }
}

// MARK: - Test Blocker

/// A blocker that prevents tests from running
struct TestBlocker: Identifiable, Equatable {
    let id: UUID
    let kind: BlockerKind
    let message: String
    let suggestion: String?
    let command: String?
    
    init(
        id: UUID = UUID(),
        kind: BlockerKind,
        message: String,
        suggestion: String? = nil,
        command: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.suggestion = suggestion
        self.command = command
    }
}

/// Types of blockers that can prevent test execution
enum BlockerKind: String, Equatable {
    case dockerNotRunning = "docker_not_running"
    case venvNotFound = "venv_not_found"
    case venvNotActivated = "venv_not_activated"
    case missingDependency = "missing_dependency"
    case missingTestFramework = "missing_test_framework"
    case noTestsFound = "no_tests_found"
    case configurationError = "configuration_error"
    case permissionDenied = "permission_denied"
    case networkUnavailable = "network_unavailable"
    case databaseNotRunning = "database_not_running"
    case envVarsMissing = "env_vars_missing"
    case unknown = "unknown"
    
    var icon: String {
        switch self {
        case .dockerNotRunning: return "shippingbox"
        case .venvNotFound, .venvNotActivated: return "folder.badge.questionmark"
        case .missingDependency, .missingTestFramework: return "puzzlepiece.extension"
        case .noTestsFound: return "doc.text.magnifyingglass"
        case .configurationError: return "gear.badge.xmark"
        case .permissionDenied: return "lock.fill"
        case .networkUnavailable: return "wifi.slash"
        case .databaseNotRunning: return "cylinder.split.1x2"
        case .envVarsMissing: return "key"
        case .unknown: return "questionmark.circle"
        }
    }
    
    var title: String {
        switch self {
        case .dockerNotRunning: return "Docker Not Running"
        case .venvNotFound: return "Virtual Environment Not Found"
        case .venvNotActivated: return "Virtual Environment Not Activated"
        case .missingDependency: return "Missing Dependency"
        case .missingTestFramework: return "Test Framework Not Installed"
        case .noTestsFound: return "No Tests Found"
        case .configurationError: return "Configuration Error"
        case .permissionDenied: return "Permission Denied"
        case .networkUnavailable: return "Network Unavailable"
        case .databaseNotRunning: return "Database Not Running"
        case .envVarsMissing: return "Environment Variables Missing"
        case .unknown: return "Unknown Issue"
        }
    }
}

// MARK: - Test Result

/// Result of a single test
struct TestResult: Identifiable, Equatable {
    let id: UUID
    let name: String
    let fullName: String
    let file: String?
    let line: Int?
    let status: TestStatus
    let duration: TimeInterval?
    let errorMessage: String?
    let stackTrace: String?
    
    init(
        id: UUID = UUID(),
        name: String,
        fullName: String? = nil,
        file: String? = nil,
        line: Int? = nil,
        status: TestStatus,
        duration: TimeInterval? = nil,
        errorMessage: String? = nil,
        stackTrace: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName ?? name
        self.file = file
        self.line = line
        self.status = status
        self.duration = duration
        self.errorMessage = errorMessage
        self.stackTrace = stackTrace
    }
    
    /// Extract file:line reference for clickable navigation
    var fileReference: String? {
        guard let file = file else { return nil }
        if let line = line {
            return "\(file):\(line)"
        }
        return file
    }
}

/// Status of an individual test
enum TestStatus: String, Equatable, CaseIterable {
    case passed = "passed"
    case failed = "failed"
    case skipped = "skipped"
    case error = "error"
    case running = "running"
    
    var icon: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "arrow.right.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        }
    }
    
    var colorName: String {
        switch self {
        case .passed: return "green"
        case .failed: return "red"
        case .skipped: return "yellow"
        case .error: return "orange"
        case .running: return "blue"
        }
    }
}

// MARK: - Test Run Summary

/// Summary of a completed test run
struct TestRunSummary: Equatable {
    let passed: Int
    let failed: Int
    let skipped: Int
    let errors: Int
    let duration: TimeInterval
    let results: [TestResult]
    let rawOutput: String
    let framework: TestFramework
    let command: String
    let timestamp: Date
    /// LLM-generated analysis notes and suggestions
    let analysisNotes: String
    /// Scope of tests that were run
    let testScope: TestScope
    
    init(
        passed: Int = 0,
        failed: Int = 0,
        skipped: Int = 0,
        errors: Int = 0,
        duration: TimeInterval = 0,
        results: [TestResult] = [],
        rawOutput: String = "",
        framework: TestFramework = .unknown,
        command: String = "",
        timestamp: Date = Date(),
        analysisNotes: String = "",
        testScope: TestScope = .full
    ) {
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.errors = errors
        self.duration = duration
        self.results = results
        self.rawOutput = rawOutput
        self.framework = framework
        self.command = command
        self.timestamp = timestamp
        self.analysisNotes = analysisNotes
        self.testScope = testScope
    }
    
    var total: Int { passed + failed + skipped + errors }
    
    var isSuccess: Bool { failed == 0 && errors == 0 }
    
    var summaryText: String {
        var parts: [String] = []
        if passed > 0 { parts.append("\(passed) passed") }
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if errors > 0 { parts.append("\(errors) errors") }
        return parts.isEmpty ? "No tests" : parts.joined(separator: ", ")
    }
    
    var durationText: String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        }
    }
    
    /// Group results by file for display
    var resultsByFile: [String: [TestResult]] {
        Dictionary(grouping: results) { result in
            result.file ?? "Unknown"
        }
    }
    
    /// Get only failed tests
    var failedTests: [TestResult] {
        results.filter { $0.status == .failed || $0.status == .error }
    }
}

// MARK: - Test Framework

/// Detected test framework
enum TestFramework: String, Equatable {
    case pytest = "pytest"
    case unittest = "unittest"
    case jest = "jest"
    case mocha = "mocha"
    case vitest = "vitest"
    case xctest = "xctest"
    case swiftTest = "swift_test"
    case goTest = "go_test"
    case rspec = "rspec"
    case junit = "junit"
    case cargo = "cargo_test"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .pytest: return "pytest"
        case .unittest: return "unittest"
        case .jest: return "Jest"
        case .mocha: return "Mocha"
        case .vitest: return "Vitest"
        case .xctest: return "XCTest"
        case .swiftTest: return "Swift Testing"
        case .goTest: return "Go Test"
        case .rspec: return "RSpec"
        case .junit: return "JUnit"
        case .cargo: return "Cargo Test"
        case .unknown: return "Unknown"
        }
    }
    
    var icon: String {
        switch self {
        case .pytest, .unittest: return "p.circle"
        case .jest, .mocha, .vitest: return "j.circle"
        case .xctest, .swiftTest: return "swift"
        case .goTest: return "g.circle"
        case .rspec: return "r.circle"
        case .junit: return "cup.and.saucer"
        case .cargo: return "shippingbox"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - Test Scope

/// Indicates what scope of tests are being run
enum TestScope: String, Equatable {
    case full = "full"
    case unitOnly = "unit_only"
    
    var displayName: String {
        switch self {
        case .full: return "Full Suite"
        case .unitOnly: return "Unit Tests Only"
        }
    }
    
    var icon: String {
        switch self {
        case .full: return "testtube.2"
        case .unitOnly: return "function"
        }
    }
}

// MARK: - Test Run Configuration

/// Configuration for running tests
struct TestRunConfiguration: Equatable {
    var projectPath: String
    var framework: TestFramework
    var command: String
    var setupCommands: [String]
    var environment: [String: String]
    var testFilter: String?
    var verbose: Bool
    var failFast: Bool
    var timeout: TimeInterval
    var testScope: TestScope
    
    init(
        projectPath: String,
        framework: TestFramework = .unknown,
        command: String = "",
        setupCommands: [String] = [],
        environment: [String: String] = [:],
        testFilter: String? = nil,
        verbose: Bool = true,
        failFast: Bool = false,
        timeout: TimeInterval = 300,
        testScope: TestScope = .full
    ) {
        self.projectPath = projectPath
        self.framework = framework
        self.command = command
        self.setupCommands = setupCommands
        self.environment = environment
        self.testFilter = testFilter
        self.verbose = verbose
        self.failFast = failFast
        self.timeout = timeout
        self.testScope = testScope
    }
}

// MARK: - Analysis Result

/// Result of analyzing a project for test setup
struct TestAnalysisResult: Equatable {
    let framework: TestFramework
    let configuration: TestRunConfiguration?
    let blockers: [TestBlocker]
    let analysisNotes: String
    let confidence: AnalysisConfidence
    
    var canRun: Bool { blockers.isEmpty && configuration != nil }
    
    enum AnalysisConfidence: String, Equatable {
        case high = "high"
        case medium = "medium"
        case low = "low"
    }
}


