import Foundation

// MARK: - Memory Tool

struct MemoryTool: AgentTool {
    let name = "memory"
    let description = "Store and recall notes during task execution. Args: action ('save'/'recall'/'list'), key (for save/recall), value (for save)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Store and recall notes during task execution",
            parameters: [
                ToolParameter(name: "action", type: .string, description: "Action to perform", required: true, enumValues: ["save", "recall", "list"]),
                ToolParameter(name: "key", type: .string, description: "Key for save/recall operations", required: false),
                ToolParameter(name: "value", type: .string, description: "Value to save (required for save action)", required: false)
            ]
        )
    }
    
    private let store: MemoryStore
    
    init(store: MemoryStore) {
        self.store = store
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let action = args["action"]?.lowercased() else {
            return .failure("Missing required argument: action (save/recall/list)")
        }
        
        switch action {
        case "save":
            guard let key = args["key"], !key.isEmpty else {
                return .failure("Missing required argument: key")
            }
            guard let value = args["value"] else {
                return .failure("Missing required argument: value")
            }
            store.save(key: key, value: value)
            return .success("Saved '\(key)'")
            
        case "recall":
            guard let key = args["key"], !key.isEmpty else {
                return .failure("Missing required argument: key")
            }
            if let value = store.recall(key: key) {
                return .success(value)
            } else {
                return .success("No value stored for '\(key)'")
            }
            
        case "list":
            let keys = store.list()
            if keys.isEmpty {
                return .success("No stored memories")
            }
            return .success("Stored keys: \(keys.joined(separator: ", "))")
            
        default:
            return .failure("Unknown action: \(action). Use save/recall/list")
        }
    }
}
