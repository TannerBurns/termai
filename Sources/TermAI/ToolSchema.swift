import Foundation

// MARK: - Tool Parameter Definition

/// Represents a parameter for a tool/function call
struct ToolParameter {
    let name: String
    let type: ToolParameterType
    let description: String
    let required: Bool
    let enumValues: [String]?
    
    init(name: String, type: ToolParameterType, description: String, required: Bool = true, enumValues: [String]? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.enumValues = enumValues
    }
}

/// Supported parameter types for tool schemas
enum ToolParameterType: String {
    case string = "string"
    case integer = "integer"
    case number = "number"
    case boolean = "boolean"
    case array = "array"
    case object = "object"
}

// MARK: - Tool Schema Definition

/// Represents a tool schema that can be converted to provider-specific formats
struct ToolSchema {
    let name: String
    let description: String
    let parameters: [ToolParameter]
    
    init(name: String, description: String, parameters: [ToolParameter] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
    
    // MARK: - OpenAI Format
    
    /// Convert to OpenAI function calling format
    /// Returns: {"type": "function", "function": {"name": ..., "description": ..., "parameters": {...}}}
    func toOpenAI() -> [String: Any] {
        var properties: [String: Any] = [:]
        var requiredParams: [String] = []
        
        for param in parameters {
            var paramDef: [String: Any] = [
                "type": param.type.rawValue,
                "description": param.description
            ]
            
            if let enumValues = param.enumValues {
                paramDef["enum"] = enumValues
            }
            
            properties[param.name] = paramDef
            
            if param.required {
                requiredParams.append(param.name)
            }
        }
        
        var parametersSchema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        
        if !requiredParams.isEmpty {
            parametersSchema["required"] = requiredParams
        }
        
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parametersSchema
            ]
        ]
    }
    
    // MARK: - Anthropic Format
    
    /// Convert to Anthropic tool format
    /// Returns: {"name": ..., "description": ..., "input_schema": {...}}
    func toAnthropic() -> [String: Any] {
        var properties: [String: Any] = [:]
        var requiredParams: [String] = []
        
        for param in parameters {
            var paramDef: [String: Any] = [
                "type": param.type.rawValue,
                "description": param.description
            ]
            
            if let enumValues = param.enumValues {
                paramDef["enum"] = enumValues
            }
            
            properties[param.name] = paramDef
            
            if param.required {
                requiredParams.append(param.name)
            }
        }
        
        var inputSchema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        
        if !requiredParams.isEmpty {
            inputSchema["required"] = requiredParams
        }
        
        return [
            "name": name,
            "description": description,
            "input_schema": inputSchema
        ]
    }
    
    // MARK: - Google Format
    
    /// Convert to Google Gemini function declaration format
    /// Returns: {"name": ..., "description": ..., "parameters": {...}}
    func toGoogle() -> [String: Any] {
        var properties: [String: Any] = [:]
        var requiredParams: [String] = []
        
        for param in parameters {
            // Google uses uppercase type names
            let googleType = param.type.rawValue.uppercased()
            
            var paramDef: [String: Any] = [
                "type": googleType,
                "description": param.description
            ]
            
            if let enumValues = param.enumValues {
                paramDef["enum"] = enumValues
            }
            
            properties[param.name] = paramDef
            
            if param.required {
                requiredParams.append(param.name)
            }
        }
        
        var parametersSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": properties
        ]
        
        if !requiredParams.isEmpty {
            parametersSchema["required"] = requiredParams
        }
        
        return [
            "name": name,
            "description": description,
            "parameters": parametersSchema
        ]
    }
}

// MARK: - Tool Call Parsing

/// Represents a parsed tool call from any provider's response
struct ParsedToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
    
    /// Parse arguments as string dictionary (for compatibility with existing tool execution)
    var stringArguments: [String: String] {
        var result: [String: String] = [:]
        for (key, value) in arguments {
            if let strValue = value as? String {
                result[key] = strValue
            } else if let intValue = value as? Int {
                result[key] = String(intValue)
            } else if let doubleValue = value as? Double {
                result[key] = String(doubleValue)
            } else if let boolValue = value as? Bool {
                result[key] = boolValue ? "true" : "false"
            } else {
                // For complex types, serialize to JSON
                if let data = try? JSONSerialization.data(withJSONObject: value),
                   let str = String(data: data, encoding: .utf8) {
                    result[key] = str
                }
            }
        }
        return result
    }
}

// MARK: - Tool Call Parser

/// Parses tool calls from different provider response formats
enum ToolCallParser {
    
    /// Parse tool calls from OpenAI response format
    /// Expected format: {"tool_calls": [{"id": "...", "type": "function", "function": {"name": "...", "arguments": "{...}"}}]}
    static func parseOpenAI(from message: [String: Any]) -> [ParsedToolCall] {
        guard let toolCalls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }
        
        var parsed: [ParsedToolCall] = []
        
        for call in toolCalls {
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else {
                continue
            }
            
            // Arguments come as a JSON string that needs to be parsed
            var arguments: [String: Any] = [:]
            if let argsString = function["arguments"] as? String,
               let argsData = argsString.data(using: .utf8),
               let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                arguments = argsDict
            }
            
            parsed.append(ParsedToolCall(id: id, name: name, arguments: arguments))
        }
        
        return parsed
    }
    
    /// Parse tool calls from Anthropic response format
    /// Expected format: {"content": [{"type": "tool_use", "id": "...", "name": "...", "input": {...}}]}
    static func parseAnthropic(from content: [[String: Any]]) -> [ParsedToolCall] {
        var parsed: [ParsedToolCall] = []
        
        for block in content {
            guard let type = block["type"] as? String,
                  type == "tool_use",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String else {
                continue
            }
            
            let arguments = block["input"] as? [String: Any] ?? [:]
            parsed.append(ParsedToolCall(id: id, name: name, arguments: arguments))
        }
        
        return parsed
    }
    
    /// Parse tool calls from Google Gemini response format
    /// Expected format: {"parts": [{"functionCall": {"name": "...", "args": {...}}}]}
    static func parseGoogle(from parts: [[String: Any]]) -> [ParsedToolCall] {
        var parsed: [ParsedToolCall] = []
        
        for (index, part) in parts.enumerated() {
            guard let functionCall = part["functionCall"] as? [String: Any],
                  let name = functionCall["name"] as? String else {
                continue
            }
            
            let arguments = functionCall["args"] as? [String: Any] ?? [:]
            // Google doesn't provide call IDs, generate one
            let id = "google_call_\(index)"
            parsed.append(ParsedToolCall(id: id, name: name, arguments: arguments))
        }
        
        return parsed
    }
}

// MARK: - Tool Result Formatting

/// Formats tool results for different provider APIs
enum ToolResultFormatter {
    
    /// Format tool result for OpenAI API
    /// Returns a message dict with role "tool"
    static func formatForOpenAI(toolCallId: String, result: String) -> [String: Any] {
        return [
            "role": "tool",
            "tool_call_id": toolCallId,
            "content": result
        ]
    }
    
    /// Format tool result for Anthropic API
    /// Returns a content block for a user message
    static func formatForAnthropic(toolUseId: String, result: String, isError: Bool = false) -> [String: Any] {
        var block: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": toolUseId,
            "content": result
        ]
        if isError {
            block["is_error"] = true
        }
        return block
    }
    
    /// Format tool result for Google Gemini API
    /// Returns a function response part
    static func formatForGoogle(functionName: String, result: [String: Any]) -> [String: Any] {
        return [
            "functionResponse": [
                "name": functionName,
                "response": result
            ]
        ]
    }
    
    // MARK: - Assistant Message with Tool Calls
    
    /// Format assistant message containing tool calls for OpenAI
    static func assistantMessageWithToolCallsOpenAI(content: String?, toolCalls: [ParsedToolCall]) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant"]
        if let content = content {
            message["content"] = content
        }
        
        var formattedCalls: [[String: Any]] = []
        for call in toolCalls {
            let argsJson = (try? JSONSerialization.data(withJSONObject: call.arguments))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            formattedCalls.append([
                "id": call.id,
                "type": "function",
                "function": [
                    "name": call.name,
                    "arguments": argsJson
                ]
            ])
        }
        message["tool_calls"] = formattedCalls
        return message
    }
    
    /// Format assistant message containing tool calls for Anthropic
    static func assistantMessageWithToolCallsAnthropic(content: String?, toolCalls: [ParsedToolCall]) -> [String: Any] {
        var contentBlocks: [[String: Any]] = []
        
        if let content = content, !content.isEmpty {
            contentBlocks.append(["type": "text", "text": content])
        }
        
        for call in toolCalls {
            contentBlocks.append([
                "type": "tool_use",
                "id": call.id,
                "name": call.name,
                "input": call.arguments
            ])
        }
        
        return [
            "role": "assistant",
            "content": contentBlocks
        ]
    }
    
    /// Format user message with tool results for Anthropic
    static func userMessageWithToolResultsAnthropic(results: [(toolUseId: String, result: String, isError: Bool)]) -> [String: Any] {
        var contentBlocks: [[String: Any]] = []
        
        for result in results {
            contentBlocks.append(formatForAnthropic(
                toolUseId: result.toolUseId,
                result: result.result,
                isError: result.isError
            ))
        }
        
        return [
            "role": "user",
            "content": contentBlocks
        ]
    }
    
    /// Format function response message for Google
    static func functionResponseMessageGoogle(results: [(name: String, result: [String: Any])]) -> [String: Any] {
        var parts: [[String: Any]] = []
        
        for result in results {
            parts.append(formatForGoogle(functionName: result.name, result: result.result))
        }
        
        return [
            "role": "function",
            "parts": parts
        ]
    }
}
