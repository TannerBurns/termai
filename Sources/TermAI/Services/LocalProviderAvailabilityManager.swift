import Foundation
import Combine

/// Manages availability status of local LLM providers (Ollama, LM Studio, vLLM).
/// Checks connectivity at startup and caches results, similar to CloudAPIKeyManager for API keys.
@MainActor
final class LocalProviderAvailabilityManager: ObservableObject {
    static let shared = LocalProviderAvailabilityManager()
    
    /// Availability status for each provider
    @Published private(set) var ollamaAvailable: Bool = false
    @Published private(set) var lmStudioAvailable: Bool = false
    @Published private(set) var vllmAvailable: Bool = false
    
    /// Whether initial availability check has completed
    @Published private(set) var hasCheckedAvailability: Bool = false
    
    /// Whether a check is currently in progress
    @Published private(set) var isChecking: Bool = false
    
    /// Quick timeout for startup checks (we don't want to block the UI)
    private let checkTimeout: TimeInterval = 2.0
    
    private init() {
        // Start availability check on init
        checkAllProviders()
    }
    
    // MARK: - Public API
    
    /// Check if a local provider is available (server is running and responding)
    func isAvailable(for provider: LocalLLMProvider) -> Bool {
        switch provider {
        case .ollama: return ollamaAvailable
        case .lmStudio: return lmStudioAvailable
        case .vllm: return vllmAvailable
        }
    }
    
    /// Get all available local providers
    var availableProviders: [LocalLLMProvider] {
        LocalLLMProvider.allCases.filter { isAvailable(for: $0) }
    }
    
    /// Refresh availability for all providers
    func refreshAll() {
        checkAllProviders()
    }
    
    /// Refresh availability for a specific provider
    func refresh(provider: LocalLLMProvider) {
        Task {
            let available = await checkProvider(provider)
            self.updateAvailability(provider: provider, available: available)
        }
    }
    
    /// Manually set availability for a provider (e.g., after a successful connection test in settings)
    func setAvailable(_ available: Bool, for provider: LocalLLMProvider) {
        updateAvailability(provider: provider, available: available)
    }
    
    // MARK: - Private Implementation
    
    private func checkAllProviders() {
        guard !isChecking else { return }
        isChecking = true
        
        Task {
            // Check all providers in parallel for speed
            // Network I/O automatically runs off MainActor
            async let ollamaCheck = checkProvider(.ollama)
            async let lmStudioCheck = checkProvider(.lmStudio)
            async let vllmCheck = checkProvider(.vllm)
            
            let (ollama, lmStudio, vllm) = await (ollamaCheck, lmStudioCheck, vllmCheck)
            
            // Back on MainActor (class is @MainActor isolated)
            self.ollamaAvailable = ollama
            self.lmStudioAvailable = lmStudio
            self.vllmAvailable = vllm
            self.hasCheckedAvailability = true
            self.isChecking = false
        }
    }
    
    private func checkProvider(_ provider: LocalLLMProvider) async -> Bool {
        let baseURL = AgentSettings.shared.baseURL(for: provider)
        
        // Use a simple health check endpoint
        let checkURL: URL?
        switch provider {
        case .ollama:
            // Ollama: check /api/tags (the same endpoint used for model listing)
            let baseURLString = baseURL.absoluteString.replacingOccurrences(of: "/v1", with: "")
            checkURL = URL(string: baseURLString + "/api/tags")
        case .lmStudio, .vllm:
            // LM Studio / vLLM: check OpenAI-compatible /models endpoint
            checkURL = baseURL.appendingPathComponent("models")
        }
        
        guard let url = checkURL else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = checkTimeout
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return (200..<300).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            // Connection refused, timeout, etc. = not available
            return false
        }
    }
    
    private func updateAvailability(provider: LocalLLMProvider, available: Bool) {
        switch provider {
        case .ollama: ollamaAvailable = available
        case .lmStudio: lmStudioAvailable = available
        case .vllm: vllmAvailable = available
        }
    }
}
