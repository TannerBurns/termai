import Foundation
import os.log

private let testRunnerLogger = Logger(subsystem: "com.termai.app", category: "TestRunner")

// MARK: - Test Runner Agent

/// Agent responsible for analyzing project structure and running tests
/// Uses high reasoning to understand complex project setups (venvs, Docker, etc.)
@MainActor
final class TestRunnerAgent: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var status: TestRunnerStatus = .idle
    @Published private(set) var analysisResult: TestAnalysisResult?
    @Published private(set) var currentOutput: String = ""
    
    // MARK: - Configuration
    
    private let provider: ProviderType
    private let modelId: String
    private let projectPath: String
    private var runningTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    init(provider: ProviderType, modelId: String, projectPath: String) {
        self.provider = provider
        self.modelId = modelId
        self.projectPath = projectPath
    }
    
    // MARK: - Public API
    
    /// Run the full test runner flow: analyze → execute → report
    func runTests(filter: String? = nil) async {
        // Cancel any existing run
        runningTask?.cancel()
        
        runningTask = Task {
            await executeTestRun(filter: filter)
        }
        
        await runningTask?.value
    }
    
    /// Cancel the current test run
    func cancel() {
        runningTask?.cancel()
        status = .cancelled
    }
    
    /// Re-run only failed tests from the last run
    func rerunFailed() async {
        guard case .completed(let summary) = status else { return }
        let failedNames = summary.failedTests.map { $0.fullName }
        guard !failedNames.isEmpty else { return }
        
        // Create a filter for failed tests
        let filter = failedNames.joined(separator: " or ")
        await runTests(filter: filter)
    }
    
    /// Run a fix command and then retry the test analysis
    func runFixAndRetry(command: String) async {
        testRunnerLogger.info("Running fix command: \(command)")
        
        // Run the fix command
        let result = await runCommand(command, cwd: projectPath, environment: [:])
        
        if result.success {
            testRunnerLogger.info("Fix command succeeded, retrying tests...")
            // Small delay to let things settle (e.g., Docker starting)
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            await runTests()
        } else {
            testRunnerLogger.error("Fix command failed: \(result.output)")
            status = .failed("Fix command failed: \(result.output)")
        }
    }
    
    // MARK: - Private Implementation
    
    private func executeTestRun(filter: String?) async {
        status = .analyzing
        currentOutput = ""
        
        do {
            // Phase 1: Analyze project
            testRunnerLogger.info("Starting test analysis for: \(self.projectPath)")
            let analysis = try await analyzeProject()
            self.analysisResult = analysis
            
            // Check for blockers
            if !analysis.blockers.isEmpty {
                testRunnerLogger.warning("Test run blocked: \(analysis.blockers.count) blockers found")
                status = .blocked(analysis.blockers)
                return
            }
            
            guard let config = analysis.configuration else {
                status = .failed("No test configuration determined")
                return
            }
            
            // Phase 2: Execute tests
            testRunnerLogger.info("Running tests with command: \(config.command)")
            status = .running(progress: TestRunProgress(testsRun: 0, elapsedTime: 0))
            
            let summary = try await executeTests(config: config, filter: filter)
            
            testRunnerLogger.info("Tests completed: \(summary.summaryText)")
            status = .completed(summary)
            
        } catch is CancellationError {
            status = .cancelled
        } catch {
            testRunnerLogger.error("Test run failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
        }
    }
    
    // MARK: - Phase 1: Analysis
    
    /// Tools available for test runner analysis
    private let analysisToolNames = ["read_file", "list_dir", "search_files", "shell"]
    
    private func analyzeProject() async throws -> TestAnalysisResult {
        // First, gather project information
        let projectInfo = await gatherProjectInfo()
        
        // Use native tool calling for dynamic project analysis
        return try await analyzeProjectWithNativeTools(projectInfo: projectInfo)
    }
    
    /// Analyze project using native tool calling for dynamic exploration
    private func analyzeProjectWithNativeTools(projectInfo: ProjectInfo) async throws -> TestAnalysisResult {
        // System prompt for native tool calling
        let systemPrompt = """
        You are a test runner assistant analyzing a project to determine how to run tests.
        You have access to tools to explore the project structure and read configuration files.
        
        Your goal:
        1. Identify the test framework being used
        2. Determine the correct command to run tests
        3. Identify any setup commands needed (like activating virtualenv, starting Docker)
        4. Identify any blockers (missing dependencies, Docker not running, etc.)
        
        Use the tools to explore the project. When you have enough information, respond with a JSON configuration.
        
        JSON Format for final response (no tool calls):
        {
            "framework": "pytest|jest|xctest|swift_test|go_test|cargo_test|rspec|unknown",
            "command": "the exact command to run tests",
            "setup_commands": ["any commands needed before running tests"],
            "environment": {"KEY": "VALUE"},
            "blockers": [{"issue": "description", "fix_command": "command to fix it"}],
            "confidence": "high|medium|low"
        }
        """
        
        // Initial context from gathered info
        let initialContext = buildAnalysisPrompt(projectInfo: projectInfo)
        
        // Get tool schemas
        let toolSchemas = analysisToolNames.compactMap { toolName -> [String: Any]? in
            guard let tool = AgentToolRegistry.shared.get(toolName) else { return nil }
            switch provider {
            case .cloud(.anthropic):
                return tool.schema.toAnthropic()
            case .cloud(.google):
                return tool.schema.toGoogle()
            default:
                return tool.schema.toOpenAI()
            }
        }
        
        var messages: [[String: Any]] = [
            ["role": "user", "content": initialContext + "\n\nAnalyze this project and determine the test configuration. Use tools if you need more information."]
        ]
        
        var additionalContext: [String] = []
        let maxToolSteps = 10
        
        for step in 1...maxToolSteps {
            guard !Task.isCancelled else { throw CancellationError() }
            
            // Use streaming and collect results
            var accumulatedContent = ""
            var toolCalls: [ParsedToolCall] = []
            
            let stream = LLMClient.shared.completeWithToolsStream(
                systemPrompt: systemPrompt,
                messages: messages,
                tools: toolSchemas,
                provider: provider,
                modelId: modelId,
                maxTokens: 4000,
                timeout: 60
            )
            
            for try await event in stream {
                switch event {
                case .textDelta(let text):
                    accumulatedContent += text
                case .toolCallComplete(let toolCall):
                    toolCalls.append(toolCall)
                default:
                    break
                }
            }
            
            // Check if model returned final response (no tool calls)
            if toolCalls.isEmpty {
                if !accumulatedContent.isEmpty {
                    testRunnerLogger.info("Analysis complete after \(step) steps")
                    return try parseAnalysisResponse(accumulatedContent, projectInfo: projectInfo)
                }
                throw TestRunnerError.analysisError("Empty response from model")
            }
            
            // Execute tool calls
            for toolCall in toolCalls {
                guard analysisToolNames.contains(toolCall.name) else { continue }
                guard let tool = AgentToolRegistry.shared.get(toolCall.name) else { continue }
                
                testRunnerLogger.debug("Analysis step \(step): \(toolCall.name) with args \(toolCall.stringArguments)")
                
                let toolResult = await tool.execute(args: toolCall.stringArguments, cwd: projectPath)
                
                if toolResult.success {
                    let truncated = String(toolResult.output.prefix(2000))
                    additionalContext.append("[\(toolCall.name)] \(toolCall.stringArguments): \(truncated)")
                } else {
                    additionalContext.append("[\(toolCall.name)] ERROR: \(toolResult.error ?? "unknown")")
                }
            }
            
            // Add assistant message with tool calls
            let assistantMsg = ToolResultFormatter.assistantMessageWithToolCallsOpenAI(
                content: accumulatedContent.isEmpty ? nil : accumulatedContent,
                toolCalls: toolCalls
            )
            messages.append(assistantMsg)
            
            // Add tool results based on provider
            switch provider {
            case .cloud(.anthropic):
                let results = toolCalls.enumerated().map { (idx, call) -> (toolUseId: String, result: String, isError: Bool) in
                    let context = additionalContext.count > idx ? additionalContext[additionalContext.count - toolCalls.count + idx] : "No result"
                    return (toolUseId: call.id, result: context, isError: context.contains("ERROR"))
                }
                messages.append(ToolResultFormatter.userMessageWithToolResultsAnthropic(results: results))
            default:
                for (idx, call) in toolCalls.enumerated() {
                    let context = additionalContext.count > idx ? additionalContext[additionalContext.count - toolCalls.count + idx] : "No result"
                    messages.append(ToolResultFormatter.formatForOpenAI(toolCallId: call.id, result: context))
                }
            }
        }
        
        throw TestRunnerError.analysisError("Analysis exceeded maximum tool steps")
    }
    
    private func gatherProjectInfo() async -> ProjectInfo {
        var info = ProjectInfo(path: projectPath)
        
        // List files in project root
        info.rootFiles = listDirectory(projectPath, recursive: false)
        
        // Check for common configuration files
        info.hasPackageJson = fileExists("\(projectPath)/package.json")
        info.hasPackageSwift = fileExists("\(projectPath)/Package.swift")
        info.hasPyprojectToml = fileExists("\(projectPath)/pyproject.toml")
        info.hasPytestIni = fileExists("\(projectPath)/pytest.ini")
        info.hasSetupPy = fileExists("\(projectPath)/setup.py")
        info.hasRequirementsTxt = fileExists("\(projectPath)/requirements.txt")
        info.hasDockerCompose = fileExists("\(projectPath)/docker-compose.yml") || fileExists("\(projectPath)/docker-compose.yaml")
        info.hasDockerfile = fileExists("\(projectPath)/Dockerfile")
        info.hasMakefile = fileExists("\(projectPath)/Makefile")
        info.hasCargoToml = fileExists("\(projectPath)/Cargo.toml")
        info.hasGoMod = fileExists("\(projectPath)/go.mod")
        info.hasGemfile = fileExists("\(projectPath)/Gemfile")
        
        // Check for virtual environments
        info.hasVenv = directoryExists("\(projectPath)/.venv") || directoryExists("\(projectPath)/venv")
        info.hasPoetryLock = fileExists("\(projectPath)/poetry.lock")
        info.hasPipfileLock = fileExists("\(projectPath)/Pipfile.lock")
        
        // Check for test directories
        info.hasTestsDir = directoryExists("\(projectPath)/tests") || directoryExists("\(projectPath)/test")
        info.hasSpecDir = directoryExists("\(projectPath)/spec")
        
        // Read key configuration files
        if info.hasPackageJson {
            info.packageJsonContent = readFile("\(projectPath)/package.json", maxSize: 5000)
        }
        if info.hasPyprojectToml {
            info.pyprojectContent = readFile("\(projectPath)/pyproject.toml", maxSize: 3000)
        }
        
        // Check tool availability
        info.dockerAvailable = await checkCommandAvailable("docker info")
        info.pythonAvailable = await checkCommandAvailable("python3 --version")
        info.nodeAvailable = await checkCommandAvailable("node --version")
        info.swiftAvailable = await checkCommandAvailable("swift --version")
        
        return info
    }
    
    private func buildAnalysisPrompt(projectInfo: ProjectInfo) -> String {
        var prompt = """
        Analyze this project to determine how to run tests.
        
        PROJECT PATH: \(projectInfo.path)
        
        ROOT FILES:
        \(projectInfo.rootFiles.joined(separator: "\n"))
        
        DETECTED CONFIGURATION:
        - package.json: \(projectInfo.hasPackageJson)
        - Package.swift: \(projectInfo.hasPackageSwift)
        - pyproject.toml: \(projectInfo.hasPyprojectToml)
        - pytest.ini: \(projectInfo.hasPytestIni)
        - requirements.txt: \(projectInfo.hasRequirementsTxt)
        - docker-compose.yml: \(projectInfo.hasDockerCompose)
        - Makefile: \(projectInfo.hasMakefile)
        - Cargo.toml: \(projectInfo.hasCargoToml)
        - go.mod: \(projectInfo.hasGoMod)
        - Gemfile: \(projectInfo.hasGemfile)
        
        VIRTUAL ENVIRONMENT:
        - .venv or venv directory: \(projectInfo.hasVenv)
        - poetry.lock: \(projectInfo.hasPoetryLock)
        - Pipfile.lock: \(projectInfo.hasPipfileLock)
        
        TEST DIRECTORIES:
        - tests/ or test/: \(projectInfo.hasTestsDir)
        - spec/: \(projectInfo.hasSpecDir)
        
        TOOL AVAILABILITY:
        - Docker: \(projectInfo.dockerAvailable)
        - Python: \(projectInfo.pythonAvailable)
        - Node.js: \(projectInfo.nodeAvailable)
        - Swift: \(projectInfo.swiftAvailable)
        
        """
        
        if let packageJson = projectInfo.packageJsonContent {
            prompt += "\nPACKAGE.JSON CONTENT:\n\(packageJson)\n"
        }
        
        if let pyproject = projectInfo.pyprojectContent {
            prompt += "\nPYPROJECT.TOML CONTENT:\n\(pyproject)\n"
        }
        
        prompt += """
        
        Respond with a JSON object containing:
        {
            "framework": "pytest|jest|xctest|swift_test|go_test|cargo_test|rspec|unknown",
            "command": "the exact command to run tests",
            "setup_commands": ["any commands needed before running tests"],
            "environment": {"KEY": "VALUE"},
            "test_scope": "full|unit_only",
            "blockers": [
                {
                    "kind": "docker_not_running|venv_not_found|missing_dependency|services_not_running|etc",
                    "message": "Human-readable explanation",
                    "suggestion": "How to fix it",
                    "command": "Command to run to fix (optional)"
                }
            ],
            "confidence": "high|medium|low",
            "notes": "Any additional notes about the test setup"
        }
        
        CRITICAL REQUIREMENTS:
        1. ALWAYS prefer running the FULL test suite (including integration tests) when possible
        2. If docker-compose.yml exists:
           - Add "docker-compose up -d" (or "docker compose up -d") to setup_commands to start services
           - Only skip this if Docker is not available (add as blocker instead)
           - Wait for services to be ready if needed
        3. If services are required but not running, include them in setup_commands to start them
        4. Only set test_scope to "unit_only" if:
           - The user explicitly requested unit tests only
           - Required services cannot be started (add blocker explaining why)
        
        ADDITIONAL RULES:
        - If a virtual environment exists, use the venv python directly (e.g., .venv/bin/python -m pytest)
        - If docker-compose exists and Docker is available, services MUST be started in setup_commands
        - If Docker is not running but docker-compose exists, add a blocker with kind "docker_not_running"
        - For Python projects with venv, include activation in commands or use direct paths
        """
        
        return prompt
    }
    
    private func parseAnalysisResponse(_ response: String, projectInfo: ProjectInfo) throws -> TestAnalysisResult {
        // Extract JSON from response (may have markdown code blocks)
        let jsonString = extractJSON(from: response)
        
        guard let data = jsonString.data(using: .utf8) else {
            throw TestRunnerError.analysisParsingFailed("Could not encode response as UTF-8")
        }
        
        struct AnalysisResponse: Decodable {
            let framework: String?
            let command: String?
            let setup_commands: [String]?
            let environment: [String: String]?
            let test_scope: String?
            let blockers: [BlockerResponse]?
            let confidence: String?
            let notes: String?
            
            struct BlockerResponse: Decodable {
                let kind: String
                let message: String
                let suggestion: String?
                let command: String?
            }
        }
        
        let decoded = try JSONDecoder().decode(AnalysisResponse.self, from: data)
        
        // Convert to our models
        let framework = TestFramework(rawValue: decoded.framework ?? "unknown") ?? .unknown
        let confidence = TestAnalysisResult.AnalysisConfidence(rawValue: decoded.confidence ?? "medium") ?? .medium
        
        let blockers: [TestBlocker] = (decoded.blockers ?? []).map { blocker in
            TestBlocker(
                kind: BlockerKind(rawValue: blocker.kind) ?? .unknown,
                message: blocker.message,
                suggestion: blocker.suggestion,
                command: blocker.command
            )
        }
        
        var config: TestRunConfiguration? = nil
        if let command = decoded.command, !command.isEmpty {
            let scope = TestScope(rawValue: decoded.test_scope ?? "full") ?? .full
            config = TestRunConfiguration(
                projectPath: projectPath,
                framework: framework,
                command: command,
                setupCommands: decoded.setup_commands ?? [],
                environment: decoded.environment ?? [:],
                testScope: scope
            )
        }
        
        return TestAnalysisResult(
            framework: framework,
            configuration: config,
            blockers: blockers,
            analysisNotes: decoded.notes ?? "",
            confidence: confidence
        )
    }
    
    // MARK: - Phase 2: Execution
    
    private func executeTests(config: TestRunConfiguration, filter: String?) async throws -> TestRunSummary {
        let startTime = Date()
        var output = ""
        var setupFailures: [(command: String, output: String)] = []
        
        // Run setup commands first
        for setupCmd in config.setupCommands {
            testRunnerLogger.debug("Running setup: \(setupCmd)")
            let setupResult = await runCommand(setupCmd, cwd: projectPath, environment: config.environment)
            if !setupResult.success {
                // Check if this is a docker-compose failure - log it but don't fail immediately
                if setupCmd.contains("docker") && setupCmd.contains("up") {
                    testRunnerLogger.warning("Docker setup failed, will attempt to run tests anyway (may skip integration tests)")
                    setupFailures.append((setupCmd, setupResult.output))
                    // Update status to indicate we're running with limited setup
                    status = .running(progress: TestRunProgress(
                        currentTest: "Running tests (docker setup skipped)",
                        testsRun: 0,
                        totalTests: nil,
                        elapsedTime: 0
                    ))
                } else {
                    throw TestRunnerError.setupFailed(setupCmd, setupResult.output)
                }
            }
        }
        
        // If docker setup failed, add a note about it
        if !setupFailures.isEmpty {
            output += "⚠️ Docker setup failed - running without containerized services\n"
            output += "Some integration tests may be skipped.\n"
            output += "Setup error: \(setupFailures.first?.output.prefix(500) ?? "")\n\n"
        }
        
        // Build the test command with optional filter
        var testCommand = config.command
        if let filter = filter, !filter.isEmpty {
            // Append filter based on framework
            switch config.framework {
            case .pytest:
                testCommand += " -k '\(filter)'"
            case .jest, .vitest:
                testCommand += " --testNamePattern='\(filter)'"
            case .goTest:
                testCommand += " -run '\(filter)'"
            case .cargo:
                testCommand += " '\(filter)'"
            default:
                testCommand += " \(filter)"
            }
        }
        
        // Add verbose flag if needed
        if config.verbose {
            switch config.framework {
            case .pytest:
                if !testCommand.contains("-v") {
                    testCommand += " -v"
                }
            case .jest, .vitest:
                if !testCommand.contains("--verbose") {
                    testCommand += " --verbose"
                }
            default:
                break
            }
        }
        
        // Execute tests using ProcessManager for background execution
        testRunnerLogger.info("Executing: \(testCommand)")
        
        let result = await ProcessManager.shared.startProcess(
            command: testCommand,
            cwd: projectPath,
            waitForOutput: nil,
            timeout: config.timeout
        )
        
        // Track final progress for use in analysis phase
        var finalTestsRun = 0
        var finalTotalTests: Int? = nil
        
        // Wait for process to complete and collect output
        if result.pid > 0 {
            // Poll for completion
            var isRunning = true
            
            while isRunning {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                
                let check = ProcessManager.shared.checkProcess(pid: result.pid, fullOutput: true)
                isRunning = check.running
                
                // IMPORTANT: Always capture output on every check, as process may be cleaned up
                // after it stops running. This ensures we have the final output.
                if !check.output.isEmpty {
                    output = check.output
                    currentOutput = check.output
                }
                
                // Try to parse progress from output
                let progress = parseProgress(from: output, framework: config.framework)
                finalTestsRun = progress.testsRun
                finalTotalTests = progress.totalTests
                
                let elapsed = Date().timeIntervalSince(startTime)
                status = .running(progress: TestRunProgress(
                    currentTest: progress.currentTest,
                    testsRun: finalTestsRun,
                    totalTests: finalTotalTests,
                    elapsedTime: elapsed
                ))
                
                // Check for timeout
                if elapsed > config.timeout {
                    _ = ProcessManager.shared.stopProcessSync(pid: result.pid)
                    throw TestRunnerError.timeout
                }
            }
            
            // Note: Output was already captured in the loop above
            // The process may have been cleaned up by now, so we use the captured output
        } else {
            output = result.initialOutput
            currentOutput = output
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        // First try regex-based parsing
        var results = parseTestResults(from: output, framework: config.framework)
        var passed = results.filter { $0.status == .passed }.count
        var failed = results.filter { $0.status == .failed }.count
        var skipped = results.filter { $0.status == .skipped }.count
        var errors = results.filter { $0.status == .error }.count
        var analysisNotes = ""
        
        // If regex parsing found no results, use LLM to analyze the output
        if passed == 0 && failed == 0 && skipped == 0 {
            testRunnerLogger.info("Regex parsing found no results, using LLM analysis...")
            // Update status to show we're analyzing - preserve test count from run phase
            status = .running(progress: TestRunProgress(
                currentTest: "Analyzing test results...",
                testsRun: finalTestsRun,
                totalTests: finalTotalTests,
                elapsedTime: duration
            ))
            if let llmAnalysis = try? await analyzeTestOutput(output: output, framework: config.framework, finalTestsRun: finalTestsRun, finalTotalTests: finalTotalTests) {
                passed = llmAnalysis.passed
                failed = llmAnalysis.failed
                skipped = llmAnalysis.skipped
                errors = llmAnalysis.errors
                results = llmAnalysis.results
                analysisNotes = llmAnalysis.summary
            }
        }
        
        // Add setup warning to notes if there were failures
        if !setupFailures.isEmpty {
            let warningNote = "⚠️ Docker services could not be started. Integration tests may have been skipped."
            analysisNotes = warningNote + (analysisNotes.isEmpty ? "" : "\n\n" + analysisNotes)
        }
        
        return TestRunSummary(
            passed: passed,
            failed: failed,
            skipped: skipped,
            errors: errors,
            duration: duration,
            results: results,
            rawOutput: output,
            framework: config.framework,
            command: testCommand,
            analysisNotes: analysisNotes,
            testScope: config.testScope
        )
    }
    
    // MARK: - LLM Output Analysis
    
    /// Use LLM to analyze test output when regex parsing fails
    /// Paginates through all output to catch errors anywhere in the test run
    private func analyzeTestOutput(output: String, framework: TestFramework, finalTestsRun: Int = 0, finalTotalTests: Int? = nil) async throws -> LLMTestAnalysis {
        let chunkSize = 6000
        
        // If output is small enough, analyze in one pass
        if output.count <= chunkSize * 2 {
            return try await analyzeSingleChunk(output: output, framework: framework, isFinalChunk: true)
        }
        
        // For large outputs, paginate through chunks and aggregate results
        var allFailedTests: [TestResult] = []
        var allErrorMessages: [String] = []
        var chunkNumber = 0
        let totalChunks = (output.count + chunkSize - 1) / chunkSize
        
        // Process chunks to find errors and failed tests
        var index = output.startIndex
        while index < output.endIndex {
            chunkNumber += 1
            let endIndex = output.index(index, offsetBy: chunkSize, limitedBy: output.endIndex) ?? output.endIndex
            let chunk = String(output[index..<endIndex])
            
            // Update status with pagination progress - preserve test counts from run phase
            status = .running(progress: TestRunProgress(
                currentTest: "Analyzing output (\(chunkNumber)/\(totalChunks))...",
                testsRun: finalTestsRun,
                totalTests: finalTotalTests,
                elapsedTime: 0
            ))
            
            // Analyze this chunk for errors and failures
            if let chunkAnalysis = try? await analyzeChunkForErrors(
                chunk: chunk,
                chunkNumber: chunkNumber,
                totalChunks: totalChunks,
                framework: framework
            ) {
                allFailedTests.append(contentsOf: chunkAnalysis.failedTests)
                allErrorMessages.append(contentsOf: chunkAnalysis.errorMessages)
            }
            
            index = endIndex
        }
        
        // Final pass: analyze the last portion for summary statistics
        let summaryPortion = String(output.suffix(min(8000, output.count)))
        let finalAnalysis = try await analyzeFinalSummary(
            summaryPortion: summaryPortion,
            framework: framework,
            collectedFailures: allFailedTests,
            collectedErrors: allErrorMessages
        )
        
        return finalAnalysis
    }
    
    /// Analyze a single chunk (or small output) in one pass
    private func analyzeSingleChunk(output: String, framework: TestFramework, isFinalChunk: Bool) async throws -> LLMTestAnalysis {
        let analysisPrompt = """
        Analyze this test output and extract the FINAL test results.
        
        TEST FRAMEWORK: \(framework.displayName)
        
        OUTPUT:
        \(output)
        
        CRITICAL INSTRUCTIONS:
        1. Look for the SUMMARY LINE at the END of the output - this is your source of truth for counts
        2. Common summary patterns:
           - pytest: "X passed, Y failed in Z seconds" or "X passed"
           - jest: "Tests: X passed, Y failed, Z total"  
           - go test: "ok" or "FAIL" with test counts
           - cargo: "X passed; Y failed"
        3. DO NOT count individual test lines - use ONLY the summary totals
        4. Extract details of any FAILED tests including error messages
        
        Respond with a JSON object:
        {
            "passed": <number from summary line>,
            "failed": <number from summary line>,
            "skipped": <number from summary line or 0>,
            "errors": <number from summary line or 0>,
            "summary": "<brief summary of what happened>",
            "failed_tests": [
                {
                    "name": "<test name>",
                    "file": "<file path if available>",
                    "error": "<error message if available>"
                }
            ],
            "suggestions": "<any suggestions for fixing failures, or null if all passed>"
        }
        """
        
        let response = try await LLMClient.shared.complete(
            systemPrompt: "You are a test output analyzer. Extract test results accurately from the output. Always respond with valid JSON.",
            userPrompt: analysisPrompt,
            provider: provider,
            modelId: modelId,
            reasoningEffort: .none,
            temperature: 0.1,
            maxTokens: 2000,
            timeout: 30,
            requestType: .testRunner
        )
        
        return try parseTestAnalysisResponse(response)
    }
    
    /// Analyze a chunk of output for errors and failures (not for totals)
    private func analyzeChunkForErrors(chunk: String, chunkNumber: Int, totalChunks: Int, framework: TestFramework) async throws -> ChunkAnalysis {
        let analysisPrompt = """
        Analyze this PORTION of test output (chunk \(chunkNumber) of \(totalChunks)) for ERRORS and FAILURES only.
        
        TEST FRAMEWORK: \(framework.displayName)
        
        OUTPUT CHUNK:
        \(chunk)
        
        Extract ONLY:
        1. Any FAILED tests with their error messages
        2. Any ERROR messages, stack traces, or exceptions
        3. Any warnings that might indicate problems
        
        DO NOT try to determine total pass/fail counts from this chunk - only extract failures and errors.
        
        Respond with JSON:
        {
            "failed_tests": [
                {"name": "<test name>", "file": "<file>", "error": "<error message>"}
            ],
            "error_messages": ["<any error or exception messages found>"]
        }
        
        If no failures or errors in this chunk, return empty arrays.
        """
        
        let response = try await LLMClient.shared.complete(
            systemPrompt: "You are a test output analyzer. Extract failures and errors from this output chunk. Always respond with valid JSON.",
            userPrompt: analysisPrompt,
            provider: provider,
            modelId: modelId,
            reasoningEffort: .none,
            temperature: 0.1,
            maxTokens: 2000,
            timeout: 20,
            requestType: .testRunner
        )
        
        return try parseChunkAnalysisResponse(response)
    }
    
    /// Final analysis pass to get summary statistics and combine with collected failures
    private func analyzeFinalSummary(summaryPortion: String, framework: TestFramework, collectedFailures: [TestResult], collectedErrors: [String]) async throws -> LLMTestAnalysis {
        let failureContext = collectedFailures.isEmpty ? "" : """
        
        Previously found failures in earlier output:
        \(collectedFailures.map { "- \($0.name): \($0.errorMessage ?? "no error message")" }.joined(separator: "\n"))
        """
        
        let errorContext = collectedErrors.isEmpty ? "" : """
        
        Previously found error messages:
        \(collectedErrors.prefix(10).joined(separator: "\n"))
        """
        
        let analysisPrompt = """
        Analyze this FINAL portion of test output to get the summary statistics.
        
        TEST FRAMEWORK: \(framework.displayName)
        
        FINAL OUTPUT PORTION:
        \(summaryPortion)
        \(failureContext)
        \(errorContext)
        
        CRITICAL: Find the SUMMARY LINE with total counts (e.g., "383 passed, 2 failed").
        
        Respond with JSON:
        {
            "passed": <number from summary>,
            "failed": <number from summary>,
            "skipped": <number or 0>,
            "errors": <number or 0>,
            "summary": "<what happened, mention any notable failures>",
            "failed_tests": [<include any failed tests found in this portion OR from the previously found failures>],
            "suggestions": "<suggestions for fixing issues, or null if all passed>"
        }
        """
        
        let response = try await LLMClient.shared.complete(
            systemPrompt: "You are a test output analyzer. Extract the final summary statistics. Always respond with valid JSON.",
            userPrompt: analysisPrompt,
            provider: provider,
            modelId: modelId,
            reasoningEffort: .none,
            temperature: 0.1,
            maxTokens: 2000,
            timeout: 30,
            requestType: .testRunner
        )
        
        var analysis = try parseTestAnalysisResponse(response)
        
        // Merge in any failures found in earlier chunks that weren't in the final portion
        let existingNames = Set(analysis.results.map { $0.name })
        for failure in collectedFailures {
            if !existingNames.contains(failure.name) {
                analysis = LLMTestAnalysis(
                    passed: analysis.passed,
                    failed: analysis.failed,
                    skipped: analysis.skipped,
                    errors: analysis.errors,
                    results: analysis.results + [failure],
                    summary: analysis.summary
                )
            }
        }
        
        return analysis
    }
    
    /// Parse chunk analysis response for errors only
    private func parseChunkAnalysisResponse(_ response: String) throws -> ChunkAnalysis {
        let jsonString = extractJSON(from: response)
        
        guard let data = jsonString.data(using: .utf8) else {
            return ChunkAnalysis(failedTests: [], errorMessages: [])
        }
        
        struct ChunkResponse: Decodable {
            let failed_tests: [FailedTest]?
            let error_messages: [String]?
            
            struct FailedTest: Decodable {
                let name: String?
                let file: String?
                let error: String?
            }
        }
        
        let decoded = try JSONDecoder().decode(ChunkResponse.self, from: data)
        
        let failedTests = (decoded.failed_tests ?? []).compactMap { test -> TestResult? in
            guard let name = test.name else { return nil }
            return TestResult(
                name: name,
                file: test.file,
                status: .failed,
                errorMessage: test.error
            )
        }
        
        return ChunkAnalysis(
            failedTests: failedTests,
            errorMessages: decoded.error_messages ?? []
        )
    }
    
    /// Intermediate result from analyzing a chunk
    private struct ChunkAnalysis {
        let failedTests: [TestResult]
        let errorMessages: [String]
    }
    
    private func parseTestAnalysisResponse(_ response: String) throws -> LLMTestAnalysis {
        let jsonString = extractJSON(from: response)
        
        guard let data = jsonString.data(using: .utf8) else {
            throw TestRunnerError.analysisParsingFailed("Could not encode response")
        }
        
        struct AnalysisResponse: Decodable {
            let passed: Int?
            let failed: Int?
            let skipped: Int?
            let errors: Int?
            let summary: String?
            let failed_tests: [FailedTest]?
            let suggestions: String?
            
            struct FailedTest: Decodable {
                let name: String?
                let file: String?
                let error: String?
            }
        }
        
        let decoded = try JSONDecoder().decode(AnalysisResponse.self, from: data)
        
        // Convert failed_tests to TestResult objects
        var results: [TestResult] = []
        if let failedTests = decoded.failed_tests {
            for test in failedTests {
                if let name = test.name {
                    results.append(TestResult(
                        name: name,
                        file: test.file,
                        status: .failed,
                        errorMessage: test.error
                    ))
                }
            }
        }
        
        var summary = decoded.summary ?? ""
        if let suggestions = decoded.suggestions, !suggestions.isEmpty {
            summary += "\n\nSuggestions: \(suggestions)"
        }
        
        return LLMTestAnalysis(
            passed: decoded.passed ?? 0,
            failed: decoded.failed ?? 0,
            skipped: decoded.skipped ?? 0,
            errors: decoded.errors ?? 0,
            results: results,
            summary: summary
        )
    }
    
    // MARK: - Output Parsing
    
    private func parseProgress(from output: String, framework: TestFramework) -> (testsRun: Int, totalTests: Int?, currentTest: String?) {
        // Framework-specific progress parsing
        switch framework {
        case .pytest:
            return parsePytestProgress(output)
        case .jest, .vitest:
            return parseJestProgress(output)
        default:
            // Count lines that look like test results
            let testLines = output.components(separatedBy: .newlines).filter {
                $0.contains("PASSED") || $0.contains("FAILED") || $0.contains("OK") || $0.contains("FAIL")
            }
            return (testLines.count, nil, nil)
        }
    }
    
    private func parsePytestProgress(_ output: String) -> (testsRun: Int, totalTests: Int?, currentTest: String?) {
        // Look for pytest progress pattern: "test_file.py::test_name PASSED"
        let lines = output.components(separatedBy: .newlines)
        var testsRun = 0
        var currentTest: String?
        
        for line in lines {
            if line.contains(" PASSED") || line.contains(" FAILED") || line.contains(" SKIPPED") || line.contains(" ERROR") {
                testsRun += 1
                // Extract test name
                if let testName = line.components(separatedBy: " ").first {
                    currentTest = testName
                }
            }
        }
        
        // Try to find total from collection output
        var total: Int?
        if let collectMatch = output.range(of: #"collected (\d+) item"#, options: .regularExpression) {
            let matchStr = String(output[collectMatch])
            if let numRange = matchStr.range(of: #"\d+"#, options: .regularExpression) {
                total = Int(matchStr[numRange])
            }
        }
        
        return (testsRun, total, currentTest)
    }
    
    private func parseJestProgress(_ output: String) -> (testsRun: Int, totalTests: Int?, currentTest: String?) {
        // Jest shows: "Tests: X passed, Y total"
        let lines = output.components(separatedBy: .newlines)
        var testsRun = 0
        var total: Int?
        
        for line in lines {
            if line.contains("Tests:") {
                // Parse "Tests: X passed, Y total" or similar
                if let totalMatch = line.range(of: #"(\d+) total"#, options: .regularExpression) {
                    let matchStr = String(line[totalMatch])
                    if let numRange = matchStr.range(of: #"\d+"#, options: .regularExpression) {
                        total = Int(matchStr[numRange])
                    }
                }
                // Count passed + failed
                let passedMatch = line.range(of: #"(\d+) passed"#, options: .regularExpression)
                let failedMatch = line.range(of: #"(\d+) failed"#, options: .regularExpression)
                
                if let pm = passedMatch {
                    let matchStr = String(line[pm])
                    if let numRange = matchStr.range(of: #"\d+"#, options: .regularExpression) {
                        testsRun += Int(matchStr[numRange]) ?? 0
                    }
                }
                if let fm = failedMatch {
                    let matchStr = String(line[fm])
                    if let numRange = matchStr.range(of: #"\d+"#, options: .regularExpression) {
                        testsRun += Int(matchStr[numRange]) ?? 0
                    }
                }
            }
        }
        
        return (testsRun, total, nil)
    }
    
    private func parseTestResults(from output: String, framework: TestFramework) -> [TestResult] {
        switch framework {
        case .pytest:
            return parsePytestResults(output)
        case .jest, .vitest:
            return parseJestResults(output)
        case .swiftTest, .xctest:
            return parseSwiftTestResults(output)
        case .goTest:
            return parseGoTestResults(output)
        default:
            return parseGenericResults(output)
        }
    }
    
    private func parsePytestResults(_ output: String) -> [TestResult] {
        var results: [TestResult] = []
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            // Match pattern: "tests/test_file.py::TestClass::test_name PASSED"
            let patterns: [(status: TestStatus, marker: String)] = [
                (.passed, " PASSED"),
                (.failed, " FAILED"),
                (.skipped, " SKIPPED"),
                (.error, " ERROR")
            ]
            
            for (status, marker) in patterns {
                if line.contains(marker) {
                    let testPath = line.replacingOccurrences(of: marker, with: "").trimmingCharacters(in: .whitespaces)
                    let components = testPath.components(separatedBy: "::")
                    
                    let file = components.first
                    let name = components.last ?? testPath
                    
                    results.append(TestResult(
                        name: name,
                        fullName: testPath,
                        file: file,
                        line: nil,
                        status: status
                    ))
                    break
                }
            }
        }
        
        // Parse failure details
        if output.contains("FAILURES") {
            // Extract failure messages and stack traces
            _ = output.components(separatedBy: "FAILURES").last ?? ""
            // TODO: Parse detailed failure info with stack traces
        }
        
        return results
    }
    
    private func parseJestResults(_ output: String) -> [TestResult] {
        var results: [TestResult] = []
        let lines = output.components(separatedBy: .newlines)
        
        var currentFile: String?
        
        for line in lines {
            // Jest file header: "PASS src/tests/file.test.ts" or "FAIL src/tests/file.test.ts"
            if line.hasPrefix("PASS ") || line.hasPrefix("FAIL ") {
                currentFile = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            
            // Test result: "  ✓ test name (5 ms)" or "  ✕ test name"
            if line.contains("✓") || line.contains("✕") || line.contains("○") {
                let status: TestStatus
                if line.contains("✓") {
                    status = .passed
                } else if line.contains("✕") {
                    status = .failed
                } else {
                    status = .skipped
                }
                
                // Extract test name
                var name = line
                    .replacingOccurrences(of: "✓", with: "")
                    .replacingOccurrences(of: "✕", with: "")
                    .replacingOccurrences(of: "○", with: "")
                    .trimmingCharacters(in: .whitespaces)
                
                // Remove timing info
                if let parenIndex = name.lastIndex(of: "(") {
                    name = String(name[..<parenIndex]).trimmingCharacters(in: .whitespaces)
                }
                
                results.append(TestResult(
                    name: name,
                    fullName: currentFile.map { "\($0) > \(name)" } ?? name,
                    file: currentFile,
                    status: status
                ))
            }
        }
        
        return results
    }
    
    private func parseSwiftTestResults(_ output: String) -> [TestResult] {
        var results: [TestResult] = []
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            // Swift test output: "Test Case '-[TestTarget.TestClass testMethod]' passed"
            if line.contains("Test Case") && (line.contains("passed") || line.contains("failed")) {
                let status: TestStatus = line.contains("passed") ? .passed : .failed
                
                // Extract test name
                if let startQuote = line.firstIndex(of: "'"),
                   let endQuote = line.lastIndex(of: "'") {
                    let testName = String(line[line.index(after: startQuote)..<endQuote])
                    results.append(TestResult(
                        name: testName,
                        fullName: testName,
                        status: status
                    ))
                }
            }
        }
        
        return results
    }
    
    private func parseGoTestResults(_ output: String) -> [TestResult] {
        var results: [TestResult] = []
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            // Go test output: "--- PASS: TestName (0.00s)" or "--- FAIL: TestName (0.00s)"
            if line.hasPrefix("--- PASS:") || line.hasPrefix("--- FAIL:") || line.hasPrefix("--- SKIP:") {
                let status: TestStatus
                if line.contains("PASS") {
                    status = .passed
                } else if line.contains("FAIL") {
                    status = .failed
                } else {
                    status = .skipped
                }
                
                // Extract test name and duration
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    var nameAndDuration = parts[1].trimmingCharacters(in: .whitespaces)
                    var duration: TimeInterval?
                    
                    if let parenIndex = nameAndDuration.lastIndex(of: "(") {
                        let durationStr = String(nameAndDuration[nameAndDuration.index(after: parenIndex)...])
                            .replacingOccurrences(of: ")", with: "")
                            .replacingOccurrences(of: "s", with: "")
                        duration = TimeInterval(durationStr)
                        nameAndDuration = String(nameAndDuration[..<parenIndex]).trimmingCharacters(in: .whitespaces)
                    }
                    
                    results.append(TestResult(
                        name: nameAndDuration,
                        fullName: nameAndDuration,
                        status: status,
                        duration: duration
                    ))
                }
            }
        }
        
        return results
    }
    
    private func parseGenericResults(_ output: String) -> [TestResult] {
        var results: [TestResult] = []
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            let lowerLine = line.lowercased()
            
            if lowerLine.contains("pass") || lowerLine.contains("ok") {
                results.append(TestResult(name: line.trimmingCharacters(in: .whitespaces), status: .passed))
            } else if lowerLine.contains("fail") {
                results.append(TestResult(name: line.trimmingCharacters(in: .whitespaces), status: .failed))
            } else if lowerLine.contains("skip") {
                results.append(TestResult(name: line.trimmingCharacters(in: .whitespaces), status: .skipped))
            }
        }
        
        return results
    }
    
    // MARK: - Helper Methods
    
    private func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
    
    private func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
    
    private func listDirectory(_ path: String, recursive: Bool) -> [String] {
        let url = URL(fileURLWithPath: path)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        return contents.map { $0.lastPathComponent }
    }
    
    private func readFile(_ path: String, maxSize: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        return String(content.prefix(maxSize))
    }
    
    private func checkCommandAvailable(_ command: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/zsh")
                // Use login shell to ensure PATH includes Homebrew and other user tools
                task.arguments = ["-l", "-c", command]
                task.standardOutput = Pipe()
                task.standardError = Pipe()
                
                do {
                    try task.run()
                    task.waitUntilExit()
                    continuation.resume(returning: task.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    private func runCommand(_ command: String, cwd: String, environment: [String: String]) async -> (success: Bool, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/zsh")
                // Use -l for login shell (sources .zprofile) and -i for interactive (sources .zshrc)
                // This ensures tools like docker-compose installed via Homebrew are available
                task.arguments = ["-l", "-i", "-c", command]
                task.currentDirectoryURL = URL(fileURLWithPath: cwd)
                
                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment {
                    env[key] = value
                }
                task.environment = env
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                task.standardOutput = outputPipe
                task.standardError = errorPipe
                
                do {
                    try task.run()
                    task.waitUntilExit()
                    
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let error = String(data: errorData, encoding: .utf8) ?? ""
                    
                    continuation.resume(returning: (task.terminationStatus == 0, output + error))
                } catch {
                    continuation.resume(returning: (false, error.localizedDescription))
                }
            }
        }
    }
    
    private func extractJSON(from response: String) -> String {
        // Try to extract JSON from markdown code blocks
        if let start = response.range(of: "```json"),
           let end = response.range(of: "```", range: start.upperBound..<response.endIndex) {
            return String(response[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        if let start = response.range(of: "```"),
           let end = response.range(of: "```", range: start.upperBound..<response.endIndex) {
            return String(response[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Try to find raw JSON
        if let start = response.firstIndex(of: "{"),
           let end = response.lastIndex(of: "}") {
            return String(response[start...end])
        }
        
        return response
    }
    
    // MARK: - System Prompt
    
    private var testAnalysisSystemPrompt: String {
        """
        You are an expert at analyzing software projects to determine how to run their test suites.
        
        Your job is to:
        1. Identify the test framework(s) being used
        2. Determine the exact command to run tests
        3. Identify any setup steps needed (virtual environment activation, Docker services, etc.)
        4. Detect any blockers that would prevent tests from running
        
        Common patterns to look for:
        
        PYTHON:
        - pytest: Look for pytest.ini, pyproject.toml [tool.pytest], conftest.py
        - If .venv exists, use .venv/bin/python -m pytest
        - If poetry.lock exists, use "poetry run pytest"
        - If Pipfile.lock exists, use "pipenv run pytest"
        
        JAVASCRIPT/TYPESCRIPT:
        - Jest: Look for jest.config.js, package.json "jest" section
        - Vitest: Look for vitest.config.ts
        - Use "npm test" or "yarn test" or "pnpm test" based on lock file
        
        SWIFT:
        - Look for Package.swift with testTarget
        - Command is typically "swift test"
        
        GO:
        - Look for go.mod and _test.go files
        - Command is "go test ./..."
        
        RUST:
        - Look for Cargo.toml
        - Command is "cargo test"
        
        DOCKER:
        - If docker-compose.yml exists and contains test services, tests may need Docker
        - Check if Docker is running before suggesting Docker commands
        
        Always respond with valid JSON. Be specific about blockers and provide actionable suggestions.
        """
    }
}

// MARK: - Project Info

private struct ProjectInfo {
    let path: String
    var rootFiles: [String] = []
    
    // Configuration files
    var hasPackageJson = false
    var hasPackageSwift = false
    var hasPyprojectToml = false
    var hasPytestIni = false
    var hasSetupPy = false
    var hasRequirementsTxt = false
    var hasDockerCompose = false
    var hasDockerfile = false
    var hasMakefile = false
    var hasCargoToml = false
    var hasGoMod = false
    var hasGemfile = false
    
    // Virtual environments
    var hasVenv = false
    var hasPoetryLock = false
    var hasPipfileLock = false
    
    // Test directories
    var hasTestsDir = false
    var hasSpecDir = false
    
    // File contents
    var packageJsonContent: String?
    var pyprojectContent: String?
    
    // Tool availability
    var dockerAvailable = false
    var pythonAvailable = false
    var nodeAvailable = false
    var swiftAvailable = false
}

// MARK: - LLM Test Analysis Result

/// Result from LLM-based test output analysis
struct LLMTestAnalysis {
    let passed: Int
    let failed: Int
    let skipped: Int
    let errors: Int
    let results: [TestResult]
    let summary: String
}

// MARK: - Errors

enum TestRunnerError: LocalizedError {
    case analysisParsingFailed(String)
    case analysisError(String)
    case setupFailed(String, String)
    case timeout
    case noTestsFound
    
    var errorDescription: String? {
        switch self {
        case .analysisParsingFailed(let reason):
            return "Failed to parse analysis response: \(reason)"
        case .analysisError(let reason):
            return "Analysis failed: \(reason)"
        case .setupFailed(let command, let output):
            return "Setup command failed: \(command)\n\(output)"
        case .timeout:
            return "Test execution timed out"
        case .noTestsFound:
            return "No tests were found in the project"
        }
    }
}


