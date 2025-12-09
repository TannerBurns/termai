import Foundation

// MARK: - LLM Stream Events

/// Events emitted during streaming LLM completions with tool support
/// Used to provide real-time feedback as the model generates responses
enum LLMStreamEvent: Sendable {
    /// Incremental text content from the model
    case textDelta(String)
    
    /// A tool call has been initiated (we know the tool name)
    case toolCallStart(id: String, name: String)
    
    /// Incremental JSON argument data for a tool call
    case toolCallArgumentDelta(id: String, delta: String)
    
    /// A complete tool call is ready to execute
    case toolCallComplete(ParsedToolCall)
    
    /// Token usage statistics (may arrive at end of stream)
    case usage(prompt: Int, completion: Int)
    
    /// The stop reason from the model (e.g., "end_turn", "tool_use", "stop")
    case stopReason(String)
    
    /// Stream has finished
    case done
}

// MARK: - Stream Accumulator

/// Accumulates streaming chunks into complete tool calls
/// Handles partial JSON accumulation and multi-tool-call scenarios
final class ToolCallAccumulator: @unchecked Sendable {
    /// Accumulated tool calls by ID
    private var toolCalls: [String: AccumulatingToolCall] = [:]
    
    /// Lock for thread safety
    private let lock = NSLock()
    
    struct AccumulatingToolCall {
        let id: String
        var name: String
        var arguments: String
        var isComplete: Bool
        
        func toParsedToolCall() -> ParsedToolCall {
            ParsedToolCall(
                id: id,
                name: name,
                arguments: parseArguments()
            )
        }
        
        private func parseArguments() -> [String: Any] {
            guard let data = arguments.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return json
        }
    }
    
    /// Start tracking a new tool call
    func startToolCall(id: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        toolCalls[id] = AccumulatingToolCall(id: id, name: name, arguments: "", isComplete: false)
    }
    
    /// Append argument delta to a tool call
    func appendArguments(id: String, delta: String) {
        lock.lock()
        defer { lock.unlock() }
        toolCalls[id]?.arguments.append(delta)
    }
    
    /// Mark a tool call as complete and return it
    func completeToolCall(id: String) -> ParsedToolCall? {
        lock.lock()
        defer { lock.unlock() }
        guard var call = toolCalls[id] else { return nil }
        call.isComplete = true
        toolCalls[id] = call
        return call.toParsedToolCall()
    }
    
    /// Get all completed tool calls
    func getCompletedToolCalls() -> [ParsedToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return toolCalls.values
            .filter { $0.isComplete }
            .map { $0.toParsedToolCall() }
    }
    
    /// Get all tool calls (complete or not) - useful at end of stream
    func getAllToolCalls() -> [ParsedToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return toolCalls.values.map { $0.toParsedToolCall() }
    }
    
    /// Check if we have any pending tool calls
    var hasPendingToolCalls: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !toolCalls.isEmpty
    }
    
    /// Reset the accumulator
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        toolCalls.removeAll()
    }
}

// MARK: - Streaming Result

/// Final result after consuming a complete stream
struct LLMStreamResult {
    let content: String?
    let toolCalls: [ParsedToolCall]
    let promptTokens: Int
    let completionTokens: Int
    let stopReason: String?
    
    var totalTokens: Int { promptTokens + completionTokens }
    var hasToolCalls: Bool { !toolCalls.isEmpty }
}
