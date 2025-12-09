import Foundation

// MARK: - HTTP Request Tool

struct HttpRequestTool: AgentTool {
    let name = "http_request"
    let description = "Make an HTTP request to test APIs. Args: url (required), method (optional: GET/POST/PUT/DELETE, default: GET), body (optional - JSON string for POST/PUT), headers (optional - comma-separated key:value pairs)"
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Make an HTTP request to test APIs and web endpoints",
            parameters: [
                ToolParameter(name: "url", type: .string, description: "URL to request", required: true),
                ToolParameter(name: "method", type: .string, description: "HTTP method", required: false, enumValues: ["GET", "POST", "PUT", "DELETE", "PATCH"]),
                ToolParameter(name: "body", type: .string, description: "Request body (JSON string for POST/PUT/PATCH)", required: false),
                ToolParameter(name: "headers", type: .string, description: "Headers as comma-separated key:value pairs", required: false)
            ]
        )
    }
    
    func execute(args: [String: String], cwd: String?) async -> AgentToolResult {
        guard let urlString = args["url"], !urlString.isEmpty else {
            return .failure("Missing required argument: url")
        }
        
        guard let url = URL(string: urlString) else {
            return .failure("Invalid URL: \(urlString)")
        }
        
        let method = args["method"]?.uppercased() ?? "GET"
        let body = args["body"]
        let headersStr = args["headers"]
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = AgentSettings.shared.httpRequestTimeout
        
        // Parse headers
        if let headersStr = headersStr {
            for pair in headersStr.components(separatedBy: ",") {
                let parts = pair.components(separatedBy: ":")
                if parts.count >= 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let value = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
        }
        
        // Set content type for POST/PUT with body
        if let body = body, !body.isEmpty, (method == "POST" || method == "PUT" || method == "PATCH") {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = body.data(using: .utf8)
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("Invalid response type")
            }
            
            let statusCode = httpResponse.statusCode
            let statusEmoji = (200..<300).contains(statusCode) ? "✓" : "✗"
            
            var output = "\(statusEmoji) HTTP \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))"
            output += "\nURL: \(method) \(urlString)"
            
            // Add response headers summary
            if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                output += "\nContent-Type: \(contentType)"
            }
            
            // Add response body
            if let bodyString = String(data: data, encoding: .utf8) {
                let truncated = String(bodyString.prefix(2000))
                output += "\n\nResponse body:\n\(truncated)"
                if bodyString.count > 2000 {
                    output += "\n... (truncated, \(bodyString.count) total chars)"
                }
            } else {
                output += "\n\nResponse: \(data.count) bytes (non-text)"
            }
            
            return .success(output)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return .failure("Request timed out after \(AgentSettings.shared.httpRequestTimeout)s")
            case .cannotConnectToHost:
                return .failure("Cannot connect to host. Is the server running?")
            case .networkConnectionLost:
                return .failure("Network connection lost")
            default:
                return .failure("Request failed: \(error.localizedDescription)")
            }
        } catch {
            return .failure("Request failed: \(error.localizedDescription)")
        }
    }
}
