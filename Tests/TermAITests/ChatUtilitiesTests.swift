import XCTest
@testable import TermAIModels

// MARK: - Project Type Detector Tests

final class ProjectTypeDetectorTests: XCTestCase {
    
    func test_emptyContents_returnsUnknown() {
        let result = ProjectTypeDetector.detect(from: [])
        XCTAssertEqual(result, "unknown")
    }
    
    func test_unrecognizedFiles_returnsUnknown() {
        let contents = ["README.md", "LICENSE", "data.csv"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "unknown")
    }
    
    // MARK: - Single Project Type Detection
    
    func test_pythonProject_requirementsTxt() {
        let contents = ["requirements.txt", "main.py", "README.md"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Python")
    }
    
    func test_pythonProject_setupPy() {
        let contents = ["setup.py", "src/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Python")
    }
    
    func test_pythonProject_pyprojectToml() {
        let contents = ["pyproject.toml", "poetry.lock"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Python")
    }
    
    func test_pythonProject_pipfile() {
        let contents = ["Pipfile", "Pipfile.lock"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Python")
    }
    
    func test_pythonProject_venv() {
        let contents = ["venv/", "app.py"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Python")
    }
    
    func test_pythonProject_dotVenv() {
        let contents = [".venv/", "main.py"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Python")
    }
    
    func test_nodeProject() {
        let contents = ["package.json", "node_modules/", "index.js"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Node.js")
    }
    
    func test_swiftProject_packageSwift() {
        let contents = ["Package.swift", "Sources/", "Tests/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Swift")
    }
    
    func test_swiftProject_xcodeproj() {
        let contents = ["MyApp.xcodeproj/", "MyApp/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Swift")
    }
    
    func test_swiftProject_xcworkspace() {
        let contents = ["MyApp.xcworkspace/", "Pods/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Swift")
    }
    
    func test_rustProject() {
        let contents = ["Cargo.toml", "src/", "target/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Rust")
    }
    
    func test_goProject() {
        let contents = ["go.mod", "go.sum", "main.go"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Go")
    }
    
    func test_rubyProject() {
        let contents = ["Gemfile", "Gemfile.lock", "app/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Ruby")
    }
    
    func test_javaProject_maven() {
        let contents = ["pom.xml", "src/main/java/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Java/Kotlin")
    }
    
    func test_javaProject_gradle() {
        let contents = ["build.gradle", "settings.gradle"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Java/Kotlin")
    }
    
    func test_kotlinProject_gradleKts() {
        let contents = ["build.gradle.kts", "settings.gradle.kts"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Java/Kotlin")
    }
    
    func test_dockerProject_dockerfile() {
        let contents = ["Dockerfile", "app/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Docker")
    }
    
    func test_dockerProject_composeYml() {
        let contents = ["docker-compose.yml", "services/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Docker")
    }
    
    func test_dockerProject_composeYaml() {
        let contents = ["docker-compose.yaml"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "Docker")
    }
    
    func test_cppProject_cmake() {
        let contents = ["CMakeLists.txt", "src/", "include/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "C/C++")
    }
    
    func test_cProject_makefile() {
        let contents = ["Makefile", "main.c"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, "C/C++")
    }
    
    func test_dotnetProject_csproj() {
        let contents = ["MyApp.csproj", "Program.cs"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, ".NET")
    }
    
    func test_dotnetProject_sln() {
        let contents = ["MySolution.sln", "src/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertEqual(result, ".NET")
    }
    
    // MARK: - Multiple Project Types
    
    func test_multipleTypes_nodeAndDocker() {
        let contents = ["package.json", "Dockerfile", "src/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertTrue(result.contains("Node.js"))
        XCTAssertTrue(result.contains("Docker"))
    }
    
    func test_multipleTypes_pythonAndDocker() {
        let contents = ["requirements.txt", "docker-compose.yml", "app/"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertTrue(result.contains("Python"))
        XCTAssertTrue(result.contains("Docker"))
    }
    
    func test_fullStackProject() {
        // A typical full-stack project with multiple technologies
        let contents = ["package.json", "requirements.txt", "Dockerfile", "docker-compose.yml"]
        let result = ProjectTypeDetector.detect(from: contents)
        XCTAssertTrue(result.contains("Python"))
        XCTAssertTrue(result.contains("Node.js"))
        XCTAssertTrue(result.contains("Docker"))
    }
}

// MARK: - Plan Checklist Parser Tests

final class PlanChecklistParserTests: XCTestCase {
    
    func test_emptyContent_returnsEmpty() {
        let result = PlanChecklistParser.extractItems(from: "")
        XCTAssertTrue(result.isEmpty)
    }
    
    func test_noChecklistSection_returnsEmpty() {
        let content = """
        # My Plan
        
        ## Overview
        This is the overview.
        
        ## Implementation
        - Step 1
        - Step 2
        """
        let result = PlanChecklistParser.extractItems(from: content)
        XCTAssertTrue(result.isEmpty)
    }
    
    func test_checklistSection_extractsItems() {
        let content = """
        # Implementation Plan
        
        ## Overview
        Build a new feature.
        
        ## Checklist
        - [ ] Create the model
        - [ ] Add the view
        - [ ] Write tests
        
        ## Notes
        Additional notes here.
        """
        let result = PlanChecklistParser.extractItems(from: content)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], "Create the model")
        XCTAssertEqual(result[1], "Add the view")
        XCTAssertEqual(result[2], "Write tests")
    }
    
    func test_checklistWithCompletedItems() {
        let content = """
        ## Checklist
        - [x] Already done
        - [ ] Still pending
        - [X] Also completed
        """
        let result = PlanChecklistParser.extractItems(from: content)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], "Already done")
        XCTAssertEqual(result[1], "Still pending")
        XCTAssertEqual(result[2], "Also completed")
    }
    
    func test_checklistStopsAtNextSection() {
        let content = """
        ## Checklist
        - [ ] Task 1
        - [ ] Task 2
        
        ## Implementation Details
        - This is not a task
        - [ ] This looks like a task but isn't in checklist
        """
        let result = PlanChecklistParser.extractItems(from: content)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Task 1")
        XCTAssertEqual(result[1], "Task 2")
    }
    
    func test_checklistWithWhitespace() {
        let content = """
        ## Checklist
        - [ ]   Extra spaces around task   
        - [ ] Normal task
        """
        let result = PlanChecklistParser.extractItems(from: content)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Extra spaces around task")
        XCTAssertEqual(result[1], "Normal task")
    }
    
    func test_checklistIgnoresEmptyItems() {
        let content = """
        ## Checklist
        - [ ] Valid task
        - [ ]   
        - [ ] Another valid task
        """
        let result = PlanChecklistParser.extractItems(from: content)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Valid task")
        XCTAssertEqual(result[1], "Another valid task")
    }
    
    func test_lowercaseChecklistHeader() {
        let content = """
        ## checklist
        - [ ] Task one
        - [ ] Task two
        """
        let result = PlanChecklistParser.extractItems(from: content)
        XCTAssertEqual(result.count, 2)
    }
    
    func test_standaloneChecklistHeader() {
        let content = """
        checklist
        - [ ] Task A
        - [ ] Task B
        """
        let result = PlanChecklistParser.extractItems(from: content)
        XCTAssertEqual(result.count, 2)
    }
    
    func test_indentedChecklistItems() {
        let content = """
        ## Checklist
          - [ ] Indented task 1
            - [ ] More indented task 2
        """
        let result = PlanChecklistParser.extractItems(from: content)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "Indented task 1")
        XCTAssertEqual(result[1], "More indented task 2")
    }
    
    // MARK: - hasChecklist Tests
    
    func test_hasChecklist_true() {
        let content = """
        # Plan
        ## Checklist
        - [ ] Task
        """
        XCTAssertTrue(PlanChecklistParser.hasChecklist(in: content))
    }
    
    func test_hasChecklist_false() {
        let content = """
        # Plan
        ## Overview
        Some content
        """
        XCTAssertFalse(PlanChecklistParser.hasChecklist(in: content))
    }
    
    func test_hasChecklist_caseInsensitive() {
        let content1 = "## CHECKLIST"
        let content2 = "## checklist"
        let content3 = "## Checklist"
        
        XCTAssertTrue(PlanChecklistParser.hasChecklist(in: content1))
        XCTAssertTrue(PlanChecklistParser.hasChecklist(in: content2))
        XCTAssertTrue(PlanChecklistParser.hasChecklist(in: content3))
    }
}
