import XCTest
import SwiftUI

// MARK: - Types (copied from AgentSettings.swift for testing)
// These will be imported from the module after refactoring

enum AppearanceMode: String, Codable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    
    var description: String {
        switch self {
        case .system: return "Follow system appearance"
        case .light: return "Always use light mode"
        case .dark: return "Always use dark mode"
        }
    }
}

enum TerminalBellMode: String, Codable, CaseIterable {
    case sound = "Sound"
    case visual = "Visual"
    case off = "Off"
    
    var icon: String {
        switch self {
        case .sound: return "bell.fill"
        case .visual: return "light.max"
        case .off: return "bell.slash"
        }
    }
    
    var description: String {
        switch self {
        case .sound: return "Play system alert sound"
        case .visual: return "Flash the terminal window"
        case .off: return "Disable terminal bell"
        }
    }
}

enum AgentMode: String, Codable, CaseIterable {
    case scout = "Scout"
    case navigator = "Navigator"
    case copilot = "Copilot"
    case pilot = "Pilot"
    
    var icon: String {
        switch self {
        case .scout: return "binoculars"
        case .navigator: return "map"
        case .copilot: return "airplane"
        case .pilot: return "airplane.departure"
        }
    }
    
    var description: String {
        switch self {
        case .scout: return "Read-only exploration"
        case .navigator: return "Create implementation plans"
        case .copilot: return "File operations, no shell"
        case .pilot: return "Full autonomous agent"
        }
    }
    
    var hasTools: Bool {
        true
    }
    
    var canWriteFiles: Bool {
        self == .copilot || self == .pilot
    }
    
    var canExecuteShell: Bool {
        self == .pilot
    }
    
    var canCreatePlans: Bool {
        self == .navigator
    }
}

enum AgentProfile: String, Codable, CaseIterable {
    case auto = "Auto"
    case general = "General"
    case coding = "Coding"
    case codeReview = "Code Review"
    case testing = "Testing"
    case debugging = "Debugging"
    case security = "Security"
    case refactoring = "Refactoring"
    case devops = "DevOps"
    case documentation = "Documentation"
    case productManagement = "Product Management"
    
    var isAuto: Bool {
        self == .auto
    }
    
    static var specializableProfiles: [AgentProfile] {
        [.coding, .codeReview, .testing, .debugging, .security, .refactoring, .devops, .documentation, .productManagement]
    }
    
    static func fromString(_ string: String) -> AgentProfile? {
        let lowercased = string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lowercased {
        case "auto": return .auto
        case "general": return .general
        case "coding": return .coding
        case "codereview", "code review", "code_review", "review": return .codeReview
        case "testing": return .testing
        case "debugging", "debug": return .debugging
        case "security", "sec": return .security
        case "refactoring", "refactor": return .refactoring
        case "devops": return .devops
        case "documentation": return .documentation
        case "productmanagement", "product management", "product_management", "pm": return .productManagement
        default: return nil
        }
    }
    
    var icon: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .general: return "sparkles"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .codeReview: return "eye.circle"
        case .testing: return "checkmark.seal"
        case .debugging: return "ant"
        case .security: return "lock.shield"
        case .refactoring: return "arrow.triangle.2.circlepath"
        case .devops: return "server.rack"
        case .documentation: return "doc.text"
        case .productManagement: return "list.clipboard"
        }
    }
}

// MARK: - Minimal AgentSettings for Testing Command Detection

/// Simplified AgentSettings for testing command detection logic
class TestableAgentSettings {
    var requireCommandApproval: Bool = false
    var autoApproveReadOnly: Bool = true
    var blockedCommandPatterns: [String]
    
    static let defaultBlockedCommandPatterns: [String] = [
        "rm", "rmdir", "unlink", "sudo", "su ", "doas",
        "chmod", "chown", "chgrp",
        "git push --force", "git push -f", "git reset --hard",
        "git clean -fd", "git clean -f", "git checkout -- .",
        "mv /", "cp /dev/", "dd ", "mkfs", "fdisk",
        "diskutil eraseDisk", "diskutil partitionDisk",
        "kill ", "killall ", "pkill ",
        "shutdown", "reboot", "halt",
        "brew uninstall", "brew remove", "pip uninstall",
        "npm uninstall -g", "apt remove", "apt purge",
        "DROP DATABASE", "DROP TABLE", "TRUNCATE", "DELETE FROM"
    ]
    
    private static let readOnlyPrefixes = [
        "ls", "cat", "head", "tail", "less", "more", "grep", "find", "which", "where",
        "pwd", "whoami", "hostname", "uname", "date", "cal", "echo", "printf",
        "wc", "file", "stat", "du", "df", "free", "top", "ps", "env", "printenv",
        "git status", "git log", "git diff", "git show", "git branch",
        "docker ps", "docker images", "docker logs",
        "brew list", "brew info", "brew search",
        "npm list", "npm info", "npm search",
        "pip list", "pip show",
        "cargo --version", "rustc --version",
        "python --version", "node --version", "swift --version"
    ]
    
    init() {
        blockedCommandPatterns = Self.defaultBlockedCommandPatterns
    }
    
    func isReadOnlyCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.readOnlyPrefixes.contains { prefix in
            trimmed.hasPrefix(prefix.lowercased())
        }
    }
    
    func isDestructiveCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        for pattern in blockedCommandPatterns {
            let lowerPattern = pattern.lowercased()
            
            if trimmed == lowerPattern {
                return true
            }
            
            if trimmed.hasPrefix(lowerPattern + " ") || trimmed.hasPrefix(lowerPattern + "\t") {
                return true
            }
            
            if lowerPattern.contains(" ") && trimmed.contains(lowerPattern) {
                return true
            }
            
            if lowerPattern.hasSuffix(" ") && trimmed.hasPrefix(lowerPattern) {
                return true
            }
        }
        
        return false
    }
    
    func shouldAutoApprove(_ command: String) -> Bool {
        if isDestructiveCommand(command) {
            return false
        }
        if !requireCommandApproval {
            return true
        }
        if autoApproveReadOnly && isReadOnlyCommand(command) {
            return true
        }
        return false
    }
}

// MARK: - Dynamic Context Calculation (for testing)

class TestableContextSettings {
    var outputCapturePercent: Double = 0.15
    var agentMemoryPercent: Double = 0.40
    var maxOutputCaptureCap: Int = 50000
    var maxAgentMemoryCap: Int = 100000
    var minOutputCapture: Int = 8000
    var minContextSize: Int = 16000
    
    func effectiveOutputCaptureLimit(forContextTokens contextTokens: Int) -> Int {
        let contextChars = contextTokens * 4
        let dynamic = Int(Double(contextChars) * outputCapturePercent)
        let withFloor = max(dynamic, minOutputCapture)
        return min(withFloor, maxOutputCaptureCap)
    }
    
    func effectiveAgentMemoryLimit(forContextTokens contextTokens: Int) -> Int {
        let contextChars = contextTokens * 4
        let dynamic = Int(Double(contextChars) * agentMemoryPercent)
        let withFloor = max(dynamic, minContextSize)
        return min(withFloor, maxAgentMemoryCap)
    }
}

// MARK: - Tests

final class AgentSettingsTests: XCTestCase {
    
    // MARK: - AppearanceMode Tests
    
    func testAppearanceMode_AllCases() {
        let allCases = AppearanceMode.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.system))
        XCTAssertTrue(allCases.contains(.light))
        XCTAssertTrue(allCases.contains(.dark))
    }
    
    func testAppearanceMode_RawValues() {
        XCTAssertEqual(AppearanceMode.system.rawValue, "System")
        XCTAssertEqual(AppearanceMode.light.rawValue, "Light")
        XCTAssertEqual(AppearanceMode.dark.rawValue, "Dark")
    }
    
    func testAppearanceMode_ColorScheme() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
    }
    
    func testAppearanceMode_Icons() {
        XCTAssertEqual(AppearanceMode.system.icon, "circle.lefthalf.filled")
        XCTAssertEqual(AppearanceMode.light.icon, "sun.max.fill")
        XCTAssertEqual(AppearanceMode.dark.icon, "moon.fill")
    }
    
    func testAppearanceMode_Codable() throws {
        for mode in AppearanceMode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(AppearanceMode.self, from: encoded)
            XCTAssertEqual(mode, decoded)
        }
    }
    
    // MARK: - TerminalBellMode Tests
    
    func testTerminalBellMode_AllCases() {
        let allCases = TerminalBellMode.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.sound))
        XCTAssertTrue(allCases.contains(.visual))
        XCTAssertTrue(allCases.contains(.off))
    }
    
    func testTerminalBellMode_RawValues() {
        XCTAssertEqual(TerminalBellMode.sound.rawValue, "Sound")
        XCTAssertEqual(TerminalBellMode.visual.rawValue, "Visual")
        XCTAssertEqual(TerminalBellMode.off.rawValue, "Off")
    }
    
    func testTerminalBellMode_Icons() {
        XCTAssertEqual(TerminalBellMode.sound.icon, "bell.fill")
        XCTAssertEqual(TerminalBellMode.visual.icon, "light.max")
        XCTAssertEqual(TerminalBellMode.off.icon, "bell.slash")
    }
    
    func testTerminalBellMode_Codable() throws {
        for mode in TerminalBellMode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(TerminalBellMode.self, from: encoded)
            XCTAssertEqual(mode, decoded)
        }
    }
    
    // MARK: - AgentMode Tests
    
    func testAgentMode_AllCases() {
        let allCases = AgentMode.allCases
        XCTAssertEqual(allCases.count, 4)
        XCTAssertTrue(allCases.contains(.scout))
        XCTAssertTrue(allCases.contains(.navigator))
        XCTAssertTrue(allCases.contains(.copilot))
        XCTAssertTrue(allCases.contains(.pilot))
    }
    
    func testAgentMode_RawValues() {
        XCTAssertEqual(AgentMode.scout.rawValue, "Scout")
        XCTAssertEqual(AgentMode.navigator.rawValue, "Navigator")
        XCTAssertEqual(AgentMode.copilot.rawValue, "Copilot")
        XCTAssertEqual(AgentMode.pilot.rawValue, "Pilot")
    }
    
    func testAgentMode_HasTools() {
        // All modes have tools
        for mode in AgentMode.allCases {
            XCTAssertTrue(mode.hasTools)
        }
    }
    
    func testAgentMode_CanWriteFiles() {
        XCTAssertFalse(AgentMode.scout.canWriteFiles)
        XCTAssertFalse(AgentMode.navigator.canWriteFiles)
        XCTAssertTrue(AgentMode.copilot.canWriteFiles)
        XCTAssertTrue(AgentMode.pilot.canWriteFiles)
    }
    
    func testAgentMode_CanExecuteShell() {
        XCTAssertFalse(AgentMode.scout.canExecuteShell)
        XCTAssertFalse(AgentMode.navigator.canExecuteShell)
        XCTAssertFalse(AgentMode.copilot.canExecuteShell)
        XCTAssertTrue(AgentMode.pilot.canExecuteShell)
    }
    
    func testAgentMode_CanCreatePlans() {
        XCTAssertFalse(AgentMode.scout.canCreatePlans)
        XCTAssertTrue(AgentMode.navigator.canCreatePlans)
        XCTAssertFalse(AgentMode.copilot.canCreatePlans)
        XCTAssertFalse(AgentMode.pilot.canCreatePlans)
    }
    
    func testAgentMode_Icons() {
        XCTAssertEqual(AgentMode.scout.icon, "binoculars")
        XCTAssertEqual(AgentMode.navigator.icon, "map")
        XCTAssertEqual(AgentMode.copilot.icon, "airplane")
        XCTAssertEqual(AgentMode.pilot.icon, "airplane.departure")
    }
    
    func testAgentMode_Codable() throws {
        for mode in AgentMode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(AgentMode.self, from: encoded)
            XCTAssertEqual(mode, decoded)
        }
    }
    
    // MARK: - AgentProfile Tests
    
    func testAgentProfile_AllCases() {
        let allCases = AgentProfile.allCases
        XCTAssertEqual(allCases.count, 11)
    }
    
    func testAgentProfile_RawValues() {
        XCTAssertEqual(AgentProfile.auto.rawValue, "Auto")
        XCTAssertEqual(AgentProfile.general.rawValue, "General")
        XCTAssertEqual(AgentProfile.coding.rawValue, "Coding")
        XCTAssertEqual(AgentProfile.codeReview.rawValue, "Code Review")
        XCTAssertEqual(AgentProfile.testing.rawValue, "Testing")
        XCTAssertEqual(AgentProfile.debugging.rawValue, "Debugging")
        XCTAssertEqual(AgentProfile.security.rawValue, "Security")
        XCTAssertEqual(AgentProfile.refactoring.rawValue, "Refactoring")
        XCTAssertEqual(AgentProfile.devops.rawValue, "DevOps")
        XCTAssertEqual(AgentProfile.documentation.rawValue, "Documentation")
        XCTAssertEqual(AgentProfile.productManagement.rawValue, "Product Management")
    }
    
    func testAgentProfile_IsAuto() {
        XCTAssertTrue(AgentProfile.auto.isAuto)
        XCTAssertFalse(AgentProfile.general.isAuto)
        XCTAssertFalse(AgentProfile.coding.isAuto)
    }
    
    func testAgentProfile_SpecializableProfiles() {
        let specializable = AgentProfile.specializableProfiles
        XCTAssertEqual(specializable.count, 9)
        XCTAssertFalse(specializable.contains(.auto))
        XCTAssertFalse(specializable.contains(.general))
        XCTAssertTrue(specializable.contains(.coding))
        XCTAssertTrue(specializable.contains(.codeReview))
        XCTAssertTrue(specializable.contains(.testing))
    }
    
    func testAgentProfile_FromString_ExactMatch() {
        XCTAssertEqual(AgentProfile.fromString("auto"), .auto)
        XCTAssertEqual(AgentProfile.fromString("general"), .general)
        XCTAssertEqual(AgentProfile.fromString("coding"), .coding)
        XCTAssertEqual(AgentProfile.fromString("testing"), .testing)
        XCTAssertEqual(AgentProfile.fromString("debugging"), .debugging)
        XCTAssertEqual(AgentProfile.fromString("security"), .security)
        XCTAssertEqual(AgentProfile.fromString("refactoring"), .refactoring)
        XCTAssertEqual(AgentProfile.fromString("devops"), .devops)
        XCTAssertEqual(AgentProfile.fromString("documentation"), .documentation)
    }
    
    func testAgentProfile_FromString_CaseInsensitive() {
        XCTAssertEqual(AgentProfile.fromString("AUTO"), .auto)
        XCTAssertEqual(AgentProfile.fromString("Coding"), .coding)
        XCTAssertEqual(AgentProfile.fromString("DEVOPS"), .devops)
    }
    
    func testAgentProfile_FromString_Aliases() {
        // Code Review aliases
        XCTAssertEqual(AgentProfile.fromString("codereview"), .codeReview)
        XCTAssertEqual(AgentProfile.fromString("code review"), .codeReview)
        XCTAssertEqual(AgentProfile.fromString("code_review"), .codeReview)
        XCTAssertEqual(AgentProfile.fromString("review"), .codeReview)
        
        // Debugging aliases
        XCTAssertEqual(AgentProfile.fromString("debug"), .debugging)
        
        // Security aliases
        XCTAssertEqual(AgentProfile.fromString("sec"), .security)
        
        // Refactoring aliases
        XCTAssertEqual(AgentProfile.fromString("refactor"), .refactoring)
        
        // Product Management aliases
        XCTAssertEqual(AgentProfile.fromString("productmanagement"), .productManagement)
        XCTAssertEqual(AgentProfile.fromString("product management"), .productManagement)
        XCTAssertEqual(AgentProfile.fromString("product_management"), .productManagement)
        XCTAssertEqual(AgentProfile.fromString("pm"), .productManagement)
    }
    
    func testAgentProfile_FromString_TrimsWhitespace() {
        XCTAssertEqual(AgentProfile.fromString("  coding  "), .coding)
        XCTAssertEqual(AgentProfile.fromString("\ttesting\n"), .testing)
    }
    
    func testAgentProfile_FromString_InvalidReturnsNil() {
        XCTAssertNil(AgentProfile.fromString("invalid"))
        XCTAssertNil(AgentProfile.fromString(""))
        XCTAssertNil(AgentProfile.fromString("unknown profile"))
    }
    
    func testAgentProfile_Icons() {
        XCTAssertEqual(AgentProfile.auto.icon, "wand.and.stars")
        XCTAssertEqual(AgentProfile.general.icon, "sparkles")
        XCTAssertEqual(AgentProfile.coding.icon, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(AgentProfile.debugging.icon, "ant")
        XCTAssertEqual(AgentProfile.security.icon, "lock.shield")
    }
    
    func testAgentProfile_Codable() throws {
        for profile in AgentProfile.allCases {
            let encoded = try JSONEncoder().encode(profile)
            let decoded = try JSONDecoder().decode(AgentProfile.self, from: encoded)
            XCTAssertEqual(profile, decoded)
        }
    }
    
    // MARK: - Command Detection Tests
    
    func testIsReadOnlyCommand_BasicCommands() {
        let settings = TestableAgentSettings()
        
        // Read-only commands
        XCTAssertTrue(settings.isReadOnlyCommand("ls"))
        XCTAssertTrue(settings.isReadOnlyCommand("ls -la"))
        XCTAssertTrue(settings.isReadOnlyCommand("cat file.txt"))
        XCTAssertTrue(settings.isReadOnlyCommand("pwd"))
        XCTAssertTrue(settings.isReadOnlyCommand("whoami"))
        XCTAssertTrue(settings.isReadOnlyCommand("echo hello"))
    }
    
    func testIsReadOnlyCommand_GitCommands() {
        let settings = TestableAgentSettings()
        
        // Read-only git commands
        XCTAssertTrue(settings.isReadOnlyCommand("git status"))
        XCTAssertTrue(settings.isReadOnlyCommand("git log"))
        XCTAssertTrue(settings.isReadOnlyCommand("git diff"))
        XCTAssertTrue(settings.isReadOnlyCommand("git branch"))
        XCTAssertTrue(settings.isReadOnlyCommand("git show HEAD"))
    }
    
    func testIsReadOnlyCommand_VersionCommands() {
        let settings = TestableAgentSettings()
        
        XCTAssertTrue(settings.isReadOnlyCommand("python --version"))
        XCTAssertTrue(settings.isReadOnlyCommand("node --version"))
        XCTAssertTrue(settings.isReadOnlyCommand("swift --version"))
        XCTAssertTrue(settings.isReadOnlyCommand("cargo --version"))
    }
    
    func testIsReadOnlyCommand_NonReadOnly() {
        let settings = TestableAgentSettings()
        
        // These are not read-only
        XCTAssertFalse(settings.isReadOnlyCommand("npm install"))
        XCTAssertFalse(settings.isReadOnlyCommand("mkdir test"))
        XCTAssertFalse(settings.isReadOnlyCommand("touch file.txt"))
        XCTAssertFalse(settings.isReadOnlyCommand("git commit -m 'test'"))
    }
    
    func testIsReadOnlyCommand_CaseInsensitive() {
        let settings = TestableAgentSettings()
        
        XCTAssertTrue(settings.isReadOnlyCommand("LS -la"))
        XCTAssertTrue(settings.isReadOnlyCommand("CAT file.txt"))
        XCTAssertTrue(settings.isReadOnlyCommand("PWD"))
    }
    
    func testIsReadOnlyCommand_TrimsWhitespace() {
        let settings = TestableAgentSettings()
        
        XCTAssertTrue(settings.isReadOnlyCommand("  ls  "))
        XCTAssertTrue(settings.isReadOnlyCommand("\tpwd\n"))
    }
    
    func testIsDestructiveCommand_FileOperations() {
        let settings = TestableAgentSettings()
        
        XCTAssertTrue(settings.isDestructiveCommand("rm file.txt"))
        XCTAssertTrue(settings.isDestructiveCommand("rm -rf /"))
        XCTAssertTrue(settings.isDestructiveCommand("rmdir empty_folder"))
        XCTAssertTrue(settings.isDestructiveCommand("unlink file"))
    }
    
    func testIsDestructiveCommand_Sudo() {
        let settings = TestableAgentSettings()
        
        XCTAssertTrue(settings.isDestructiveCommand("sudo apt update"))
        XCTAssertTrue(settings.isDestructiveCommand("sudo rm file"))
    }
    
    func testIsDestructiveCommand_GitDestructive() {
        let settings = TestableAgentSettings()
        
        XCTAssertTrue(settings.isDestructiveCommand("git push --force"))
        XCTAssertTrue(settings.isDestructiveCommand("git push -f origin main"))
        XCTAssertTrue(settings.isDestructiveCommand("git reset --hard HEAD~1"))
        XCTAssertTrue(settings.isDestructiveCommand("git clean -fd"))
    }
    
    func testIsDestructiveCommand_ProcessKill() {
        let settings = TestableAgentSettings()
        
        XCTAssertTrue(settings.isDestructiveCommand("kill 1234"))
        XCTAssertTrue(settings.isDestructiveCommand("killall node"))
        XCTAssertTrue(settings.isDestructiveCommand("pkill python"))
    }
    
    func testIsDestructiveCommand_SystemCommands() {
        let settings = TestableAgentSettings()
        
        XCTAssertTrue(settings.isDestructiveCommand("shutdown"))
        XCTAssertTrue(settings.isDestructiveCommand("reboot"))
        XCTAssertTrue(settings.isDestructiveCommand("halt"))
    }
    
    func testIsDestructiveCommand_DatabaseCommands() {
        let settings = TestableAgentSettings()
        
        XCTAssertTrue(settings.isDestructiveCommand("DROP DATABASE test"))
        XCTAssertTrue(settings.isDestructiveCommand("DROP TABLE users"))
        XCTAssertTrue(settings.isDestructiveCommand("TRUNCATE users"))
        XCTAssertTrue(settings.isDestructiveCommand("DELETE FROM users WHERE id > 0"))
    }
    
    func testIsDestructiveCommand_SafeCommands() {
        let settings = TestableAgentSettings()
        
        // These should NOT be destructive
        XCTAssertFalse(settings.isDestructiveCommand("ls"))
        XCTAssertFalse(settings.isDestructiveCommand("cat file.txt"))
        XCTAssertFalse(settings.isDestructiveCommand("git status"))
        XCTAssertFalse(settings.isDestructiveCommand("npm install"))
        XCTAssertFalse(settings.isDestructiveCommand("mkdir test"))
    }
    
    func testIsDestructiveCommand_CaseInsensitive() {
        let settings = TestableAgentSettings()
        
        XCTAssertTrue(settings.isDestructiveCommand("RM file.txt"))
        XCTAssertTrue(settings.isDestructiveCommand("SUDO apt update"))
        XCTAssertTrue(settings.isDestructiveCommand("drop database test"))
    }
    
    func testIsDestructiveCommand_ExactMatch() {
        let settings = TestableAgentSettings()
        
        // Exact match for single-word patterns
        XCTAssertTrue(settings.isDestructiveCommand("rm"))
        XCTAssertTrue(settings.isDestructiveCommand("shutdown"))
    }
    
    func testShouldAutoApprove_NoApprovalRequired() {
        let settings = TestableAgentSettings()
        settings.requireCommandApproval = false
        
        // Safe commands auto-approved
        XCTAssertTrue(settings.shouldAutoApprove("ls"))
        XCTAssertTrue(settings.shouldAutoApprove("npm install"))
        
        // Destructive commands NEVER auto-approved
        XCTAssertFalse(settings.shouldAutoApprove("rm file.txt"))
        XCTAssertFalse(settings.shouldAutoApprove("sudo apt update"))
    }
    
    func testShouldAutoApprove_ApprovalRequired_ReadOnlyAutoApproved() {
        let settings = TestableAgentSettings()
        settings.requireCommandApproval = true
        settings.autoApproveReadOnly = true
        
        // Read-only auto-approved
        XCTAssertTrue(settings.shouldAutoApprove("ls"))
        XCTAssertTrue(settings.shouldAutoApprove("git status"))
        
        // Non-read-only needs approval
        XCTAssertFalse(settings.shouldAutoApprove("npm install"))
        XCTAssertFalse(settings.shouldAutoApprove("mkdir test"))
        
        // Destructive NEVER auto-approved
        XCTAssertFalse(settings.shouldAutoApprove("rm file.txt"))
    }
    
    func testShouldAutoApprove_ApprovalRequired_NoAutoApproveReadOnly() {
        let settings = TestableAgentSettings()
        settings.requireCommandApproval = true
        settings.autoApproveReadOnly = false
        
        // Nothing auto-approved except...
        XCTAssertFalse(settings.shouldAutoApprove("ls"))
        XCTAssertFalse(settings.shouldAutoApprove("npm install"))
        
        // Destructive still never auto-approved
        XCTAssertFalse(settings.shouldAutoApprove("rm file.txt"))
    }
    
    // MARK: - Dynamic Context Calculation Tests
    
    func testEffectiveOutputCaptureLimit_SmallContext() {
        let settings = TestableContextSettings()
        
        // 8K token model (~32K chars) - should hit floor
        let limit = settings.effectiveOutputCaptureLimit(forContextTokens: 8000)
        XCTAssertEqual(limit, 8000) // floor
    }
    
    func testEffectiveOutputCaptureLimit_MediumContext() {
        let settings = TestableContextSettings()
        
        // 32K token model (~128K chars)
        // 128K * 0.15 = 19200
        let limit = settings.effectiveOutputCaptureLimit(forContextTokens: 32000)
        XCTAssertEqual(limit, 19200)
    }
    
    func testEffectiveOutputCaptureLimit_LargeContext() {
        let settings = TestableContextSettings()
        
        // 128K token model (~512K chars)
        // 512K * 0.15 = 76800, but capped at 50000
        let limit = settings.effectiveOutputCaptureLimit(forContextTokens: 128000)
        XCTAssertEqual(limit, 50000) // cap
    }
    
    func testEffectiveAgentMemoryLimit_SmallContext() {
        let settings = TestableContextSettings()
        
        // 8K token model - should hit floor
        let limit = settings.effectiveAgentMemoryLimit(forContextTokens: 8000)
        XCTAssertEqual(limit, 16000) // floor
    }
    
    func testEffectiveAgentMemoryLimit_MediumContext() {
        let settings = TestableContextSettings()
        
        // 32K token model (~128K chars)
        // 128K * 0.40 = 51200
        let limit = settings.effectiveAgentMemoryLimit(forContextTokens: 32000)
        XCTAssertEqual(limit, 51200)
    }
    
    func testEffectiveAgentMemoryLimit_LargeContext() {
        let settings = TestableContextSettings()
        
        // 128K token model (~512K chars)
        // 512K * 0.40 = 204800, but capped at 100000
        let limit = settings.effectiveAgentMemoryLimit(forContextTokens: 128000)
        XCTAssertEqual(limit, 100000) // cap
    }
    
    func testEffectiveOutputCaptureLimit_CustomPercent() {
        let settings = TestableContextSettings()
        settings.outputCapturePercent = 0.25
        
        // 32K token model with 25% allocation
        // 128K * 0.25 = 32000
        let limit = settings.effectiveOutputCaptureLimit(forContextTokens: 32000)
        XCTAssertEqual(limit, 32000)
    }
    
    func testEffectiveAgentMemoryLimit_CustomPercent() {
        let settings = TestableContextSettings()
        settings.agentMemoryPercent = 0.50
        
        // 32K token model with 50% allocation
        // 128K * 0.50 = 64000
        let limit = settings.effectiveAgentMemoryLimit(forContextTokens: 32000)
        XCTAssertEqual(limit, 64000)
    }
}
