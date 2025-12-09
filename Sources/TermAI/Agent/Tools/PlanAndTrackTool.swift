import Foundation

// MARK: - Plan and Track Tool

/// Tool for setting goals and managing task checklists during agent execution
/// The agent calls this at the start of complex tasks to establish a plan
final class PlanAndTrackTool: AgentTool {
    let name = "plan_and_track"
    let description = "CALL THIS FIRST to set a goal and create a task checklist. Essential for multi-step work. Also use to mark tasks complete."
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "IMPORTANT: Call this FIRST before starting any multi-step work. Sets your goal and creates a trackable task checklist. Also use to mark tasks as complete when done. Only skip for trivial single-command requests.",
            parameters: [
                ToolParameter(name: "goal", type: .string, description: "Clear, actionable goal statement (required when setting up a new plan)", required: false),
                ToolParameter(name: "tasks", type: .string, description: "JSON array of task descriptions, e.g. [\"task 1\", \"task 2\"]. Break work into 3-7 concrete steps.", required: false),
                ToolParameter(name: "start_task", type: .integer, description: "Task ID to mark as in-progress (1-based)", required: false),
                ToolParameter(name: "complete_task", type: .integer, description: "Task ID to mark complete (1-based). Call this after finishing each task.", required: false),
                ToolParameter(name: "task_note", type: .string, description: "Optional note for the completed task", required: false)
            ]
        )
    }
    
    /// Weak reference to the delegate (set by ChatSession when starting agent mode)
    weak var delegate: PlanTrackDelegate?
    
    init(delegate: PlanTrackDelegate? = nil) {
        self.delegate = delegate
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let delegate = delegate else {
            return .failure("Plan tracking delegate not configured. This is an internal error.")
        }
        
        // Check if this is a start_task operation (marking task as in-progress)
        if let startTaskStr = args["start_task"], let taskId = Int(startTaskStr) {
            await delegate.markTaskInProgress(id: taskId)
            
            // Return current status
            if let status = await delegate.getChecklistStatus() {
                return .success("Started task \(taskId).\n\nCurrent checklist:\n\(status)")
            } else {
                return .success("Started task \(taskId).")
            }
        }
        
        // Check if this is a complete_task operation
        if let completeTaskStr = args["complete_task"], let taskId = Int(completeTaskStr) {
            let note = args["task_note"]
            
            await delegate.markTaskComplete(id: taskId, note: note)
            
            // Return current status
            if let status = await delegate.getChecklistStatus() {
                return .success("Marked task \(taskId) complete.\n\nCurrent checklist:\n\(status)")
            } else {
                return .success("Marked task \(taskId) complete.")
            }
        }
        
        // This is a setup operation - need a goal
        guard let goal = args["goal"], !goal.isEmpty else {
            return .failure("Missing required argument: goal. Provide a clear, actionable goal statement.")
        }
        
        // Parse tasks array if provided (comes as JSON string)
        var taskList: [String]? = nil
        if let tasksJson = args["tasks"], !tasksJson.isEmpty {
            // Try to parse as JSON array
            if let data = tasksJson.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
                taskList = parsed
            } else {
                // If not valid JSON array, try splitting by newlines or commas
                let cleaned = tasksJson.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if cleaned.contains("\n") {
                    taskList = cleaned.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                } else if cleaned.contains(",") {
                    taskList = cleaned.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\""))) }
                        .filter { !$0.isEmpty }
                }
            }
        }
        
        await delegate.setGoalAndTasks(goal: goal, tasks: taskList)
        
        // Build response
        var response = "Goal set: \(goal)"
        if let tasks = taskList, !tasks.isEmpty {
            response += "\n\nTask checklist created with \(tasks.count) items:"
            for (idx, task) in tasks.enumerated() {
                response += "\n  \(idx + 1). \(task)"
            }
        }
        
        return .success(response)
    }
}
