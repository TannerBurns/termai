import Foundation
import SwiftUI

// MARK: - Plan Utilities

/// Get the file path for a plan (doesn't need actor isolation)
func planFilePath(for planId: UUID) -> String? {
    guard let dir = try? PersistenceService.appSupportDirectory() else { return nil }
    
    let planFile = dir
        .appendingPathComponent("plans")
        .appendingPathComponent("plan-\(planId.uuidString).md")
    
    if FileManager.default.fileExists(atPath: planFile.path) {
        return planFile.path
    }
    
    return nil
}

// MARK: - Plan Status

enum PlanStatus: String, Codable, CaseIterable {
    case draft = "Draft"           // Still being worked on
    case ready = "Ready"           // Plan is complete and ready to implement
    case implementing = "Implementing"  // Currently being implemented
    case completed = "Completed"   // Implementation finished
    
    var icon: String {
        switch self {
        case .draft: return "pencil.circle"
        case .ready: return "checkmark.circle"
        case .implementing: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.seal.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .draft: return .orange
        case .ready: return .purple
        case .implementing: return .blue
        case .completed: return .green
        }
    }
}

// MARK: - Plan Model

struct Plan: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String  // Markdown content with implementation checklist
    let createdDate: Date
    var updatedDate: Date
    var sessionId: UUID?  // Associated chat session
    var status: PlanStatus
    
    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        createdDate: Date = Date(),
        updatedDate: Date = Date(),
        sessionId: UUID? = nil,
        status: PlanStatus = .ready
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdDate = createdDate
        self.updatedDate = updatedDate
        self.sessionId = sessionId
        self.status = status
    }
    
    /// Get a preview of the plan content (first 100 characters)
    var preview: String {
        let stripped = content
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(stripped.prefix(100))
    }
    
    /// Count of checklist items in the plan
    var checklistItemCount: Int {
        content.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") ||
                     $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [x]") }
            .count
    }
    
    /// Count of completed checklist items
    var completedItemCount: Int {
        content.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [x]") }
            .count
    }
}

// MARK: - Plan Manager

@MainActor
final class PlanManager: ObservableObject {
    static let shared = PlanManager()
    
    private static let maxPlans = 50
    private static let plansFileName = "plans.json"
    private static let plansDirectory = "plans"
    
    @Published private(set) var plans: [Plan] = []
    
    private init() {
        loadPlans()
    }
    
    // MARK: - Public Methods
    
    /// Save a new plan
    func savePlan(_ plan: Plan) {
        // Remove existing plan with same ID if present (updating)
        plans.removeAll { $0.id == plan.id }
        
        // Add new plan at the beginning
        plans.insert(plan, at: 0)
        
        // Keep only the last N plans
        if plans.count > Self.maxPlans {
            let plansToRemove = Array(plans.suffix(from: Self.maxPlans))
            plans = Array(plans.prefix(Self.maxPlans))
            
            // Clean up individual plan files for removed plans
            for removed in plansToRemove {
                cleanupPlanFile(for: removed.id)
            }
        }
        
        // Save the plan content to individual file
        savePlanContent(plan)
        
        // Save the plans index
        savePlansIndex()
    }
    
    /// Update an existing plan
    func updatePlan(_ plan: Plan) {
        if let index = plans.firstIndex(where: { $0.id == plan.id }) {
            var updatedPlan = plan
            updatedPlan.updatedDate = Date()
            plans[index] = updatedPlan
            savePlanContent(updatedPlan)
            savePlansIndex()
        }
    }
    
    /// Update just the status of a plan
    func updatePlanStatus(id: UUID, status: PlanStatus) {
        if let index = plans.firstIndex(where: { $0.id == id }) {
            plans[index].status = status
            plans[index].updatedDate = Date()
            savePlanContent(plans[index])
            savePlansIndex()
        }
    }
    
    /// Get a plan by ID
    func getPlan(id: UUID) -> Plan? {
        plans.first { $0.id == id }
    }
    
    /// Get the full content of a plan (loads from file if needed)
    func getPlanContent(id: UUID) -> String? {
        guard let plan = getPlan(id: id) else { return nil }
        
        // Try to load from individual file for full content
        if let content = loadPlanContent(id: id) {
            return content
        }
        
        // Fall back to stored content
        return plan.content
    }
    
    /// Delete a plan
    func deletePlan(id: UUID) {
        plans.removeAll { $0.id == id }
        cleanupPlanFile(for: id)
        savePlansIndex()
    }
    
    /// Clear all plans
    func clearAllPlans() {
        for plan in plans {
            cleanupPlanFile(for: plan.id)
        }
        plans.removeAll()
        savePlansIndex()
        
        // Also remove the plans directory
        if let dir = try? PersistenceService.appSupportDirectory() {
            let plansDir = dir.appendingPathComponent(Self.plansDirectory)
            try? FileManager.default.removeItem(at: plansDir)
        }
    }
    
    /// Get plans for a specific session
    func plans(for sessionId: UUID) -> [Plan] {
        plans.filter { $0.sessionId == sessionId }
    }
    
    /// Get the most recent plan for a session
    func latestPlan(for sessionId: UUID) -> Plan? {
        plans.first { $0.sessionId == sessionId }
    }
    
    // MARK: - Persistence
    
    private func loadPlans() {
        if let loaded = try? PersistenceService.loadJSON([Plan].self, from: Self.plansFileName) {
            plans = loaded
        }
    }
    
    private func savePlansIndex() {
        try? PersistenceService.saveJSON(plans, to: Self.plansFileName)
    }
    
    /// Save plan content to individual file (for large plans)
    private func savePlanContent(_ plan: Plan) {
        guard let dir = try? PersistenceService.appSupportDirectory() else { return }
        
        let plansDir = dir.appendingPathComponent(Self.plansDirectory)
        try? FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
        
        let planFile = plansDir.appendingPathComponent("plan-\(plan.id.uuidString).md")
        try? plan.content.write(to: planFile, atomically: true, encoding: .utf8)
    }
    
    /// Load plan content from individual file
    private func loadPlanContent(id: UUID) -> String? {
        guard let dir = try? PersistenceService.appSupportDirectory() else { return nil }
        
        let planFile = dir
            .appendingPathComponent(Self.plansDirectory)
            .appendingPathComponent("plan-\(id.uuidString).md")
        
        return try? String(contentsOf: planFile, encoding: .utf8)
    }
    
    /// Clean up plan file when permanently removing
    private func cleanupPlanFile(for planId: UUID) {
        guard let dir = try? PersistenceService.appSupportDirectory() else { return }
        
        let planFile = dir
            .appendingPathComponent(Self.plansDirectory)
            .appendingPathComponent("plan-\(planId.uuidString).md")
        
        try? FileManager.default.removeItem(at: planFile)
    }
    
    /// Get the file path for a plan (for viewing in file viewer)
    /// This instance method ensures the plan file is created if needed
    func planFilePathEnsured(for planId: UUID) -> String? {
        // First check if it already exists using global helper
        if let path = planFilePath(for: planId) {
            return path
        }
        
        // If not, try to create it from the plan content
        if let plan = getPlan(id: planId) {
            savePlanContent(plan)
            return planFilePath(for: planId)
        }
        
        return nil
    }
}
