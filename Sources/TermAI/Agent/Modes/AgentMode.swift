import Foundation
import SwiftUI

/// Agent mode determines the level of autonomy and tools available
enum AgentMode: String, Codable, CaseIterable {
    case scout = "Scout"           // Read-only tools - explore and understand
    case navigator = "Navigator"   // Read-only with plan creation - charts the course
    case copilot = "Copilot"       // File read/write but no shell execution
    case pilot = "Pilot"           // Full agent with shell access
    
    /// SF Symbol icon for the mode
    var icon: String {
        switch self {
        case .scout: return "binoculars"
        case .navigator: return "map"
        case .copilot: return "airplane"
        case .pilot: return "airplane.departure"
        }
    }
    
    /// Short description for tooltips
    var description: String {
        switch self {
        case .scout: return "Read-only exploration"
        case .navigator: return "Create implementation plans"
        case .copilot: return "File operations, no shell"
        case .pilot: return "Full autonomous agent"
        }
    }
    
    /// Detailed description for settings
    var detailedDescription: String {
        switch self {
        case .scout: return "Can read files and explore the codebase, but cannot make changes"
        case .navigator: return "Explores the codebase and creates implementation plans for Copilot or Pilot to execute"
        case .copilot: return "Can read and write files, but cannot execute shell commands"
        case .pilot: return "Full access to all tools including shell command execution"
        }
    }
    
    /// Color for the mode indicator
    var color: Color {
        switch self {
        case .scout: return Color(red: 0.3, green: 0.7, blue: 0.9)    // Soft blue
        case .navigator: return Color(red: 0.7, green: 0.4, blue: 0.9)  // Purple/violet
        case .copilot: return Color(red: 0.9, green: 0.7, blue: 0.2)  // Amber/gold
        case .pilot: return Color(red: 0.1, green: 0.85, blue: 0.65)  // Neon mint (matches old agent active)
        }
    }
    
    /// Whether this mode enables any tools (vs pure chat)
    var hasTools: Bool {
        true // All modes have tools now
    }
    
    /// Whether this mode can modify files
    var canWriteFiles: Bool {
        self == .copilot || self == .pilot
    }
    
    /// Whether this mode can execute shell commands
    var canExecuteShell: Bool {
        self == .pilot
    }
    
    /// Whether this mode can create implementation plans
    var canCreatePlans: Bool {
        self == .navigator
    }
}
