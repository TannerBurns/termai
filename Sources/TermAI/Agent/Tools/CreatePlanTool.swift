import Foundation

// MARK: - Create Plan Tool (Navigator Mode)

/// Tool for creating implementation plans in Navigator mode
final class CreatePlanTool: AgentTool {
    let name = "create_plan"
    let description = "Create an implementation plan. Use after exploring codebase and clarifying requirements with the user."
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Create an implementation plan. Structure: 1) Summary, 2) Phases with context (NO checkboxes), 3) Technical notes, 4) Final flat checklist of high-level objectives at the end.",
            parameters: [
                ToolParameter(name: "title", type: .string, description: "Clear, descriptive title for the plan (e.g., 'Add User Authentication System')", required: true),
                ToolParameter(name: "content", type: .string, description: "Markdown content with phases/context first (no checkboxes), then a single flat checklist at the end with high-level objectives using - [ ] syntax", required: true)
            ]
        )
    }
    
    /// Weak reference to the delegate (set by ChatSession when in Navigator mode)
    weak var delegate: CreatePlanDelegate?
    
    init(delegate: CreatePlanDelegate? = nil) {
        self.delegate = delegate
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let delegate = delegate else {
            return .failure("Create plan delegate not configured. This is an internal error.")
        }
        
        guard let title = args["title"], !title.isEmpty else {
            return .failure("Missing required argument: title. Provide a clear, descriptive title for the plan.")
        }
        
        guard let content = args["content"], !content.isEmpty else {
            return .failure("Missing required argument: content. Provide the full markdown plan with implementation checklist.")
        }
        
        // Validate content has checklist items
        let hasChecklist = content.contains("- [ ]") || content.contains("- [x]")
        if !hasChecklist {
            return .failure("Plan content must include a checklist with '- [ ]' items. Please restructure the plan with actionable checklist items.")
        }
        
        // Create the plan through the delegate
        let planId = await delegate.createPlan(title: title, content: content)
        
        return .success("""
            ✅ PLAN CREATED SUCCESSFULLY
            
            Plan ID: \(planId.uuidString)
            Title: \(title)
            
            Your work as Navigator is complete. STOP HERE.
            
            The user will now review the plan and can:
            - View the full plan
            - Build with Copilot (file operations only)
            - Build with Pilot (full shell access)
            
            Do not create any more plans or continue exploring.
            """)
    }
}
