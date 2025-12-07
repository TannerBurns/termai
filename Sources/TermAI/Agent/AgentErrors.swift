import Foundation

// MARK: - Chat API Error with User-Friendly Messages

/// Represents an API error with both user-friendly message and full technical details
struct ChatAPIError: Error, LocalizedError {
    /// User-friendly error message to display
    let friendlyMessage: String
    /// Full technical error details (for debugging/copying)
    let fullDetails: String
    /// HTTP status code if applicable
    let statusCode: Int?
    /// The provider that generated the error
    let provider: String?
    
    var errorDescription: String? {
        friendlyMessage
    }
    
    init(friendlyMessage: String, fullDetails: String, statusCode: Int? = nil, provider: String? = nil) {
        self.friendlyMessage = friendlyMessage
        self.fullDetails = fullDetails
        self.statusCode = statusCode
        self.provider = provider
    }
    
    /// Create from an HTTP error response
    static func from(statusCode: Int, errorBody: String, provider: CloudProvider) -> ChatAPIError {
        let friendlyMessage = parseProviderError(statusCode: statusCode, errorBody: errorBody, provider: provider)
        return ChatAPIError(
            friendlyMessage: friendlyMessage,
            fullDetails: "HTTP \(statusCode): \(errorBody)",
            statusCode: statusCode,
            provider: provider.rawValue
        )
    }
    
    /// Parse provider-specific error messages into user-friendly text
    private static func parseProviderError(statusCode: Int, errorBody: String, provider: CloudProvider) -> String {
        // Try to parse JSON error response
        var errorMessage: String? = nil
        var errorStatus: String? = nil
        
        if let data = errorBody.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // OpenAI format: {"error": {"message": "...", "type": "...", "code": "..."}}
            // Anthropic format: {"error": {"type": "...", "message": "..."}}
            // Google format: {"error": {"message": "...", "status": "..."}}
            if let error = json["error"] as? [String: Any] {
                errorMessage = error["message"] as? String
                errorStatus = error["status"] as? String
            }
        }
        
        let providerName = provider.rawValue
        
        // Handle common HTTP status codes with provider-specific context
        switch statusCode {
        case 400:
            if let msg = errorMessage?.lowercased() {
                if msg.contains("api key") || msg.contains("api_key") {
                    return "Invalid API key format. Please check your \(providerName) API key in Settings."
                }
                if msg.contains("model") {
                    return "Invalid model configuration. The selected model may not support this request."
                }
                if msg.contains("content") || msg.contains("safety") {
                    return "Request was blocked due to content policy. Please modify your message."
                }
            }
            return "Bad request to \(providerName). \(errorMessage ?? "Please check your request.")"
            
        case 401:
            return "Authentication failed. Please verify your \(providerName) API key in Settings."
            
        case 403:
            if let msg = errorMessage?.lowercased() {
                if msg.contains("permission") || msg.contains("access") {
                    return "Access denied. Your \(providerName) API key may not have permission for this operation."
                }
                if msg.contains("region") || msg.contains("country") {
                    return "\(providerName) service is not available in your region."
                }
            }
            return "Access forbidden. Please check your \(providerName) API key permissions."
            
        case 404:
            if let msg = errorMessage?.lowercased() {
                if msg.contains("model") {
                    return "Model not found. The selected model may not be available or the name is incorrect."
                }
            }
            return "Resource not found on \(providerName). Please check your configuration."
            
        case 429:
            // Rate limiting
            if let msg = errorMessage?.lowercased() {
                if msg.contains("quota") || errorStatus == "RESOURCE_EXHAUSTED" {
                    return "Quota exceeded on \(providerName). Check your usage limits or upgrade your plan."
                }
                if msg.contains("token") || msg.contains("rpm") || msg.contains("tpm") {
                    return "Rate limit reached. Please wait a moment before sending more requests."
                }
            }
            return "Too many requests to \(providerName). Please wait a moment and try again."
            
        case 500:
            return "\(providerName) server error. The service is experiencing issues. Please try again."
            
        case 502:
            return "\(providerName) gateway error. The service may be updating. Please try again in a moment."
            
        case 503:
            if let msg = errorMessage?.lowercased() {
                if msg.contains("overloaded") || msg.contains("capacity") {
                    return "\(providerName) is currently overloaded. Please try again in a few minutes."
                }
            }
            return "\(providerName) service is temporarily unavailable. Please try again later."
            
        case 504:
            return "\(providerName) request timed out. The service may be slow. Please try again."
            
        case 529:
            return "\(providerName) is overloaded. Please try again in a few minutes."
            
        default:
            if statusCode >= 500 {
                return "\(providerName) server error (HTTP \(statusCode)). Please try again later."
            }
            // For unknown errors, show a truncated message
            let truncatedMsg = errorMessage?.prefix(100) ?? errorBody.prefix(100)
            return "\(providerName) error: \(truncatedMsg)\(truncatedMsg.count >= 100 ? "..." : "")"
        }
    }
}

// MARK: - Published Error State for UI

/// Observable error state that can be displayed in the UI
class ChatErrorState: ObservableObject {
    @Published var currentError: ChatAPIError?
    @Published var isExpanded: Bool = false
    
    func setError(_ error: ChatAPIError) {
        currentError = error
        isExpanded = false
    }
    
    func setError(friendlyMessage: String, fullDetails: String, statusCode: Int? = nil, provider: String? = nil) {
        currentError = ChatAPIError(
            friendlyMessage: friendlyMessage,
            fullDetails: fullDetails,
            statusCode: statusCode,
            provider: provider
        )
        isExpanded = false
    }
    
    func clear() {
        currentError = nil
        isExpanded = false
    }
}

// MARK: - Agent Error Types

/// Specific error types for agent API operations with recovery strategies
enum AgentAPIError: Error, LocalizedError, Equatable {
    // Network errors
    case networkUnavailable
    case connectionFailed(host: String)
    case timeout(operation: String)
    case connectionLost
    
    // Authentication errors
    case apiKeyMissing(provider: String)
    case apiKeyInvalid(provider: String)
    case authenticationFailed(provider: String, message: String)
    
    // Rate limiting
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded(provider: String)
    
    // Server errors
    case serverError(statusCode: Int, message: String)
    case serverOverloaded
    case serviceUnavailable(provider: String)
    
    // Response errors
    case invalidResponse(details: String)
    case emptyResponse
    case decodingFailed(details: String)
    case unexpectedFormat(expected: String, received: String)
    
    // Model errors
    case modelNotFound(modelId: String)
    case modelUnavailable(modelId: String)
    case contextLengthExceeded(limit: Int, requested: Int)
    
    // Cancellation
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "No network connection available"
        case .connectionFailed(let host):
            return "Cannot connect to \(host)"
        case .timeout(let operation):
            return "Request timed out during \(operation)"
        case .connectionLost:
            return "Network connection was lost"
        case .apiKeyMissing(let provider):
            return "\(provider) API key not configured"
        case .apiKeyInvalid(let provider):
            return "\(provider) API key is invalid"
        case .authenticationFailed(let provider, let message):
            return "\(provider) authentication failed: \(message)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Try again in \(Int(seconds)) seconds"
            }
            return "Rate limited. Please wait before retrying"
        case .quotaExceeded(let provider):
            return "\(provider) usage quota exceeded"
        case .serverError(let statusCode, let message):
            return "Server error (\(statusCode)): \(message)"
        case .serverOverloaded:
            return "Server is temporarily overloaded"
        case .serviceUnavailable(let provider):
            return "\(provider) service is temporarily unavailable"
        case .invalidResponse(let details):
            return "Invalid response from server: \(details)"
        case .emptyResponse:
            return "Empty response from server"
        case .decodingFailed(let details):
            return "Failed to parse response: \(details)"
        case .unexpectedFormat(let expected, let received):
            return "Expected \(expected) format but received: \(received.prefix(100))"
        case .modelNotFound(let modelId):
            return "Model '\(modelId)' not found"
        case .modelUnavailable(let modelId):
            return "Model '\(modelId)' is currently unavailable"
        case .contextLengthExceeded(let limit, let requested):
            return "Context length exceeded (limit: \(limit), requested: \(requested))"
        case .cancelled:
            return "Operation was cancelled"
        }
    }
    
    /// Suggested recovery action for this error
    var recoveryStrategy: RecoveryStrategy {
        switch self {
        case .networkUnavailable, .connectionFailed, .connectionLost:
            return .retryWithBackoff(initialDelay: 2.0, maxRetries: 3)
        case .timeout:
            return .retryWithBackoff(initialDelay: 1.0, maxRetries: 2)
        case .apiKeyMissing, .apiKeyInvalid:
            return .userActionRequired("Please configure your API key in Settings")
        case .authenticationFailed:
            return .userActionRequired("Check your API key in Settings")
        case .rateLimited(let retryAfter):
            let delay = retryAfter ?? 60.0
            return .retryWithBackoff(initialDelay: delay, maxRetries: 1)
        case .quotaExceeded:
            return .userActionRequired("Check your usage limits with your provider")
        case .serverError(let code, _):
            if code >= 500 && code < 600 {
                return .retryWithBackoff(initialDelay: 5.0, maxRetries: 2)
            }
            return .fail
        case .serverOverloaded, .serviceUnavailable:
            return .retryWithBackoff(initialDelay: 10.0, maxRetries: 3)
        case .invalidResponse, .decodingFailed, .unexpectedFormat:
            return .retryWithBackoff(initialDelay: 1.0, maxRetries: 2)
        case .emptyResponse:
            return .retryWithBackoff(initialDelay: 0.5, maxRetries: 3)
        case .modelNotFound, .modelUnavailable:
            return .userActionRequired("Select a different model")
        case .contextLengthExceeded:
            return .reduceContext
        case .cancelled:
            return .fail
        }
    }
    
    /// Whether this error is transient and might succeed on retry
    var isTransient: Bool {
        switch self {
        case .networkUnavailable, .connectionFailed, .connectionLost, .timeout,
             .rateLimited, .serverOverloaded, .serviceUnavailable, .emptyResponse:
            return true
        case .serverError(let code, _):
            return code >= 500 && code < 600
        default:
            return false
        }
    }
    
    /// Create an AgentAPIError from a URLError
    static func from(_ urlError: URLError, host: String? = nil) -> AgentAPIError {
        switch urlError.code {
        case .timedOut:
            return .timeout(operation: "network request")
        case .notConnectedToInternet:
            return .networkUnavailable
        case .cannotConnectToHost, .cannotFindHost:
            return .connectionFailed(host: host ?? "unknown")
        case .networkConnectionLost:
            return .connectionLost
        case .cancelled:
            return .cancelled
        default:
            return .connectionFailed(host: host ?? urlError.localizedDescription)
        }
    }
    
    /// Create an AgentAPIError from an HTTP response
    static func from(statusCode: Int, data: Data?, provider: String) -> AgentAPIError? {
        guard statusCode >= 400 else { return nil }
        
        let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No details"
        
        switch statusCode {
        case 401:
            return .apiKeyInvalid(provider: provider)
        case 403:
            return .authenticationFailed(provider: provider, message: message)
        case 404:
            return .modelNotFound(modelId: "unknown")
        case 429:
            // Try to parse retry-after from response
            return .rateLimited(retryAfter: parseRetryAfter(from: message))
        case 500...599:
            if statusCode == 503 {
                return .serviceUnavailable(provider: provider)
            }
            if statusCode == 529 || message.contains("overloaded") {
                return .serverOverloaded
            }
            return .serverError(statusCode: statusCode, message: message)
        default:
            return .serverError(statusCode: statusCode, message: message)
        }
    }
    
    private static func parseRetryAfter(from message: String) -> TimeInterval? {
        // Try to find retry-after value in error message
        if let range = message.range(of: "retry.{0,10}(\\d+)", options: .regularExpression) {
            let match = message[range]
            if let numRange = match.range(of: "\\d+", options: .regularExpression) {
                return TimeInterval(match[numRange]) ?? 60.0
            }
        }
        return nil
    }
}

// MARK: - Recovery Strategy

/// Describes how to recover from an error
enum RecoveryStrategy: Equatable {
    case fail
    case retryWithBackoff(initialDelay: TimeInterval, maxRetries: Int)
    case reduceContext
    case switchModel
    case userActionRequired(String)
}

// MARK: - Agent Execution State Machine

/// Represents the distinct phases of agent execution
enum AgentExecutionPhase: Equatable, CustomStringConvertible {
    case idle
    case starting
    case deciding
    case settingGoal
    case planning
    case executing(step: Int, estimatedTotal: Int)
    case reflecting(iteration: Int)
    case verifying
    case summarizing
    case completed
    case failed(reason: String)
    case cancelled
    case waitingForApproval(command: String)
    case waitingForFileLock(file: String)
    
    var description: String {
        switch self {
        case .idle:
            return ""
        case .starting:
            return "Starting"
        case .deciding:
            return "Deciding"
        case .settingGoal:
            return "Setting goal"
        case .planning:
            return "Planning"
        case .executing(let step, let total):
            if total > 0 {
                return "Step \(step)/\(total)"
            }
            return "Step \(step)"
        case .reflecting(let iteration):
            return "Reflecting (iter \(iteration))"
        case .verifying:
            return "Verifying"
        case .summarizing:
            return "Summarizing"
        case .completed:
            return "Completed"
        case .failed(let reason):
            return "Failed: \(reason)"
        case .cancelled:
            return "Cancelled"
        case .waitingForApproval:
            return "Awaiting approval"
        case .waitingForFileLock(let file):
            return "Waiting for \(URL(fileURLWithPath: file).lastPathComponent)"
        }
    }
    
    /// Whether the agent is actively running
    var isActive: Bool {
        switch self {
        case .idle, .completed, .failed, .cancelled:
            return false
        default:
            return true
        }
    }
    
    /// Whether user interaction is required
    var requiresUserAction: Bool {
        switch self {
        case .waitingForApproval:
            return true
        default:
            return false
        }
    }
    
    /// Whether this is a terminal state
    var isTerminal: Bool {
        switch self {
        case .idle, .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
    
    /// Current step number if executing
    var currentStep: Int {
        if case .executing(let step, _) = self {
            return step
        }
        return 0
    }
    
    /// Estimated total steps if known
    var estimatedSteps: Int {
        if case .executing(_, let total) = self {
            return total
        }
        return 0
    }
}

// MARK: - State Machine Transitions

extension AgentExecutionPhase {
    /// Valid transitions from the current state
    func canTransition(to newPhase: AgentExecutionPhase) -> Bool {
        switch (self, newPhase) {
        // From idle, can only start
        case (.idle, .starting):
            return true
            
        // From starting, can decide or fail
        case (.starting, .deciding), (.starting, .failed), (.starting, .cancelled):
            return true
            
        // From deciding, can set goal, go to executing (direct reply), or fail
        case (.deciding, .settingGoal), (.deciding, .executing), (.deciding, .failed), (.deciding, .cancelled):
            return true
            
        // From settingGoal, can plan or execute
        case (.settingGoal, .planning), (.settingGoal, .executing), (.settingGoal, .failed), (.settingGoal, .cancelled):
            return true
            
        // From planning, can execute or fail
        case (.planning, .executing), (.planning, .failed), (.planning, .cancelled):
            return true
            
        // From executing, many transitions possible
        case (.executing, .executing), // next step
             (.executing, .reflecting),
             (.executing, .verifying),
             (.executing, .summarizing),
             (.executing, .waitingForApproval),
             (.executing, .waitingForFileLock),
             (.executing, .completed),
             (.executing, .failed),
             (.executing, .cancelled):
            return true
            
        // From reflecting, back to executing
        case (.reflecting, .executing), (.reflecting, .failed), (.reflecting, .cancelled):
            return true
            
        // From waiting states, back to executing
        case (.waitingForApproval, .executing), (.waitingForApproval, .cancelled):
            return true
        case (.waitingForFileLock, .executing), (.waitingForFileLock, .failed), (.waitingForFileLock, .cancelled):
            return true
            
        // From verifying, can complete, summarize, continue executing, or fail
        case (.verifying, .completed), (.verifying, .summarizing), (.verifying, .executing), (.verifying, .failed), (.verifying, .cancelled):
            return true
            
        // From summarizing, complete
        case (.summarizing, .completed), (.summarizing, .failed), (.summarizing, .cancelled):
            return true
            
        // Terminal states can only go to idle
        case (.completed, .idle), (.failed, .idle), (.cancelled, .idle):
            return true
            
        default:
            return false
        }
    }
}

// MARK: - API Result Type

/// Result type for API operations with specific error handling
typealias APIResult<T> = Result<T, AgentAPIError>

/// Wrapper for one-shot API call results
struct OneShotResult {
    let raw: String
    let parsed: ParsedAgentResponse?
    let error: AgentAPIError?
    
    var isSuccess: Bool {
        error == nil && !raw.isEmpty
    }
    
    static func success(_ raw: String, parsed: ParsedAgentResponse? = nil) -> OneShotResult {
        OneShotResult(raw: raw, parsed: parsed, error: nil)
    }
    
    static func failure(_ error: AgentAPIError) -> OneShotResult {
        OneShotResult(raw: "", parsed: nil, error: error)
    }
}

/// Parsed response from agent API calls
struct ParsedAgentResponse {
    var action: String?
    var reason: String?
    var goal: String?
    var step: String?
    var command: String?
    var tool: String?
    var toolArgs: [String: String]?
    var done: Bool?
    var plan: [String]?
    var estimatedCommands: Int?
    var checklistItem: Int?
    var progressPercent: Int?
    var onTrack: Bool?
    var shouldAdjust: Bool?
    var newApproach: String?
    var isStuck: Bool?
    var shouldStop: Bool?
}

