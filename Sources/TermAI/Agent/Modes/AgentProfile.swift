import Foundation
import SwiftUI

/// Agent profile determines the task-specific behavior, planning style, and reflection focus
/// Profiles layer on top of modes - mode defines capability, profile defines approach
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
    
    /// Whether this profile automatically adapts to the task
    var isAuto: Bool {
        self == .auto
    }
    
    /// The specialized profiles that Auto mode can switch between
    static var specializableProfiles: [AgentProfile] {
        [.coding, .codeReview, .testing, .debugging, .security, .refactoring, .devops, .documentation, .productManagement]
    }
    
    /// Initialize from a string (used for JSON parsing in Auto mode)
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
    
    /// SF Symbol icon for the profile
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
    
    /// Short description for tooltips
    var description: String {
        switch self {
        case .auto: return "Automatically adapts profile based on task"
        case .general: return "Balanced general-purpose assistant"
        case .coding: return "Code quality, architecture & SOLID principles"
        case .codeReview: return "PR feedback, bug detection & style consistency"
        case .testing: return "Test coverage, TDD & quality assurance"
        case .debugging: return "Root cause analysis & systematic bug hunting"
        case .security: return "Vulnerability analysis & secure coding"
        case .refactoring: return "Code smell detection & incremental improvement"
        case .devops: return "Infrastructure & safety focus"
        case .documentation: return "Content quality & clarity focus"
        case .productManagement: return "User value & requirements focus"
        }
    }
    
    /// Detailed description for settings
    var detailedDescription: String {
        switch self {
        case .auto:
            return "Analyzes the current task and dynamically switches between specialized profiles (Coding, Testing, DevOps, etc.) as work progresses."
        case .general:
            return "Standard task breakdown with progress tracking. Good for mixed or unknown task types."
        case .coding:
            return "SOLID principles, modular design, testable chunks. Emphasizes clean architecture and error handling."
        case .codeReview:
            return "Thorough code review with focus on bugs, security issues, style consistency, and constructive feedback."
        case .testing:
            return "Test-first and test-after approaches. Focuses on coverage, edge cases, and test maintainability."
        case .debugging:
            return "Systematic bug hunting with root cause analysis. Focuses on reproduction, isolation, and verification."
        case .security:
            return "Security-focused analysis identifying vulnerabilities, threat vectors, and secure coding practices."
        case .refactoring:
            return "Safe code improvement without changing behavior. Focuses on code smells, patterns, and incremental changes."
        case .devops:
            return "Rollback-first planning with staged execution. Emphasizes safety checks and state verification."
        case .documentation:
            return "Outline-first approach with audience awareness. Focuses on consistency, completeness, and clarity."
        case .productManagement:
            return "User story breakdown with acceptance criteria. Tracks stakeholder alignment and scope."
        }
    }
    
    /// Color for the profile indicator
    var color: Color {
        switch self {
        case .auto: return Color(red: 0.7, green: 0.5, blue: 0.9)         // Auto purple (gradient-like)
        case .general: return Color(red: 0.6, green: 0.6, blue: 0.65)    // Neutral gray
        case .coding: return Color(red: 0.4, green: 0.7, blue: 1.0)      // Code blue
        case .codeReview: return Color(red: 0.3, green: 0.6, blue: 0.9)  // Review blue (slightly different)
        case .testing: return Color(red: 0.3, green: 0.85, blue: 0.6)    // Test green
        case .debugging: return Color(red: 0.95, green: 0.3, blue: 0.3)  // Debug red
        case .security: return Color(red: 0.9, green: 0.2, blue: 0.5)    // Security magenta
        case .refactoring: return Color(red: 0.5, green: 0.8, blue: 0.9) // Refactor cyan
        case .devops: return Color(red: 1.0, green: 0.5, blue: 0.3)      // Infra orange
        case .documentation: return Color(red: 0.6, green: 0.8, blue: 0.4) // Doc green
        case .productManagement: return Color(red: 0.8, green: 0.5, blue: 0.9) // PM purple
        }
    }
    
    /// System prompt addition specific to this profile
    /// Takes the current agent mode to provide mode-appropriate guidance
    /// Note: For .auto profile, use the activeProfile's systemPromptAddition instead
    func systemPromptAddition(for mode: AgentMode) -> String {
        switch self {
        case .auto:
            // Auto mode uses the active profile's prompt - this is a fallback
            return AgentProfilePrompts.autoSystemPrompt(for: mode)
        case .general:
            return AgentProfilePrompts.generalSystemPrompt(for: mode)
        case .coding:
            return AgentProfilePrompts.codingSystemPrompt(for: mode)
        case .codeReview:
            return AgentProfilePrompts.codeReviewSystemPrompt(for: mode)
        case .testing:
            return AgentProfilePrompts.testingSystemPrompt(for: mode)
        case .debugging:
            return AgentProfilePrompts.debuggingSystemPrompt(for: mode)
        case .security:
            return AgentProfilePrompts.securitySystemPrompt(for: mode)
        case .refactoring:
            return AgentProfilePrompts.refactoringSystemPrompt(for: mode)
        case .devops:
            return AgentProfilePrompts.devopsSystemPrompt(for: mode)
        case .documentation:
            return AgentProfilePrompts.documentationSystemPrompt(for: mode)
        case .productManagement:
            return AgentProfilePrompts.productManagementSystemPrompt(for: mode)
        }
    }
    
    /// Planning guidance for this profile (injected when planning is enabled)
    /// Note: For .auto profile, use the activeProfile's planningGuidance instead
    func planningGuidance(for mode: AgentMode) -> String {
        switch self {
        case .auto:
            // Auto mode uses the active profile's guidance - this is a fallback
            return AgentProfilePrompts.generalPlanningGuidance(for: mode)
        case .general:
            return AgentProfilePrompts.generalPlanningGuidance(for: mode)
        case .coding:
            return AgentProfilePrompts.codingPlanningGuidance(for: mode)
        case .codeReview:
            return AgentProfilePrompts.codeReviewPlanningGuidance(for: mode)
        case .testing:
            return AgentProfilePrompts.testingPlanningGuidance(for: mode)
        case .debugging:
            return AgentProfilePrompts.debuggingPlanningGuidance(for: mode)
        case .security:
            return AgentProfilePrompts.securityPlanningGuidance(for: mode)
        case .refactoring:
            return AgentProfilePrompts.refactoringPlanningGuidance(for: mode)
        case .devops:
            return AgentProfilePrompts.devopsPlanningGuidance(for: mode)
        case .documentation:
            return AgentProfilePrompts.documentationPlanningGuidance(for: mode)
        case .productManagement:
            return AgentProfilePrompts.productManagementPlanningGuidance(for: mode)
        }
    }
    
    /// Reflection prompt questions for periodic progress assessment
    /// Note: For .auto profile, use the activeProfile's reflectionPrompt instead
    func reflectionPrompt(for mode: AgentMode) -> String {
        switch self {
        case .auto:
            // Auto mode uses the active profile's reflection - this is a fallback
            return AgentProfilePrompts.generalReflectionPrompt(for: mode)
        case .general:
            return AgentProfilePrompts.generalReflectionPrompt(for: mode)
        case .coding:
            return AgentProfilePrompts.codingReflectionPrompt(for: mode)
        case .codeReview:
            return AgentProfilePrompts.codeReviewReflectionPrompt(for: mode)
        case .testing:
            return AgentProfilePrompts.testingReflectionPrompt(for: mode)
        case .debugging:
            return AgentProfilePrompts.debuggingReflectionPrompt(for: mode)
        case .security:
            return AgentProfilePrompts.securityReflectionPrompt(for: mode)
        case .refactoring:
            return AgentProfilePrompts.refactoringReflectionPrompt(for: mode)
        case .devops:
            return AgentProfilePrompts.devopsReflectionPrompt(for: mode)
        case .documentation:
            return AgentProfilePrompts.documentationReflectionPrompt(for: mode)
        case .productManagement:
            return AgentProfilePrompts.productManagementReflectionPrompt(for: mode)
        }
    }
}
