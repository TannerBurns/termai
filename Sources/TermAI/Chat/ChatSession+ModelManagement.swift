import Foundation

// MARK: - Model Cache

extension ChatSession {
    
    /// Cache key for the current provider configuration
    var modelCacheKey: String {
        "modelCache_\(providerName)_\(apiBaseURL.absoluteString)"
    }
    
    /// TTL for cached models (1 hour)
    static let modelCacheTTL: TimeInterval = 3600
    
    /// Check if cached models are still valid
    func getCachedModels() -> [String]? {
        guard let data = UserDefaults.standard.data(forKey: modelCacheKey),
              let cache = try? JSONDecoder().decode(ModelCache.self, from: data) else {
            return nil
        }
        
        if Date().timeIntervalSince(cache.timestamp) > Self.modelCacheTTL {
            return nil
        }
        
        return cache.models
    }
    
    /// Save models to cache
    func cacheModels(_ models: [String]) {
        let cache = ModelCache(models: models, timestamp: Date())
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: modelCacheKey)
        }
    }
}

// MARK: - Model Fetching

extension ChatSession {
    
    func fetchAvailableModels(forceRefresh: Bool = false) async {
        await MainActor.run {
            self.modelFetchError = nil
        }
        
        // Handle cloud providers - use curated model list (no caching needed, these are static)
        if case .cloud(let cloudProvider) = providerType {
            let models = CuratedModels.models(for: cloudProvider).map { $0.id }
            await MainActor.run {
                self.availableModels = models
                if models.isEmpty {
                    self.modelFetchError = "No models available for \(cloudProvider.rawValue)"
                }
            }
            return
        }
        
        // Check cache first for local providers (unless force refresh)
        if !forceRefresh, let cachedModels = getCachedModels(), !cachedModels.isEmpty {
            await MainActor.run {
                self.availableModels = cachedModels
            }
            return
        }
        
        await MainActor.run {
            self.availableModels = []
        }
        
        // Handle local providers
        switch LocalLLMProvider(rawValue: providerName) {
        case .ollama:
            await fetchOllamaModelsInternal()
        case .lmStudio, .vllm:
            await fetchOpenAIStyleModels()
        case .none:
            break
        }
    }
    
    /// Backward-compatible entry point kept for existing call sites
    func fetchOllamaModels() async { await fetchAvailableModels() }
    
    func fetchOllamaModelsInternal() async {
        let base = apiBaseURL.absoluteString
        guard let url = URL(string: base.replacingOccurrences(of: "/v1", with: "") + "/api/tags") else {
            await MainActor.run { self.modelFetchError = "Invalid Ollama URL" }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                await MainActor.run { self.modelFetchError = "Failed to fetch Ollama models (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))" }
                return
            }
            struct TagsResponse: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
            if let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data) {
                let names = decoded.models.map { $0.name }.sorted()
                cacheModels(names)
                await MainActor.run {
                    self.availableModels = names
                    if names.isEmpty {
                        self.modelFetchError = "No models found on Ollama"
                    }
                    self.updateContextLimit()
                    self.persistSettings()
                }
            } else {
                await MainActor.run { self.modelFetchError = "Unable to decode Ollama models" }
            }
        } catch {
            await MainActor.run { self.modelFetchError = "Ollama connection failed: \(error.localizedDescription)" }
        }
    }
    
    func fetchOpenAIStyleModels() async {
        let url = apiBaseURL.appendingPathComponent("models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        if let apiKey {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                await MainActor.run { self.modelFetchError = "Failed to fetch models (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))" }
                return
            }
            struct ModelsResponse: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
            if let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) {
                let ids = decoded.data.map { $0.id }.sorted()
                cacheModels(ids)
                await MainActor.run {
                    self.availableModels = ids
                    if ids.isEmpty {
                        self.modelFetchError = "No models available"
                    }
                    self.updateContextLimit()
                    self.persistSettings()
                }
            } else {
                await MainActor.run { self.modelFetchError = "Unable to decode models list" }
            }
        } catch {
            await MainActor.run { self.modelFetchError = "Model fetch failed: \(error.localizedDescription)" }
        }
    }
}
