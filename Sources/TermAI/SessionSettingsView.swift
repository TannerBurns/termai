import SwiftUI

struct SessionSettingsView: View {
    @ObservedObject var session: ChatSession
    @State private var availableModels: [String] = []
    @State private var loadingModels: Bool = false
    @State private var fetchError: String? = nil
    @State private var apiURLString: String = ""
    
    var body: some View {
        Form {
            Section("Provider Configuration") {
                HStack {
                    Text("Provider:")
                    TextField("Provider Name", text: $session.providerName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: session.providerName) { _ in
                            session.persistSettings()
                        }
                }
                
                HStack {
                    Text("API URL:")
                    TextField("API Base URL", text: $apiURLString)
                        .textFieldStyle(.roundedBorder)
                        .onAppear {
                            apiURLString = session.apiBaseURL.absoluteString
                        }
                        .onChange(of: apiURLString) { newValue in
                            if let url = URL(string: newValue) {
                                session.apiBaseURL = url
                                session.persistSettings()
                            }
                        }
                }
                
                HStack {
                    Text("API Key:")
                    SecureField("API Key (optional)", text: Binding(
                        get: { session.apiKey ?? "" },
                        set: { session.apiKey = $0.isEmpty ? nil : $0; session.persistSettings() }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                
                // Quick presets
                HStack {
                    Button("Use Ollama Defaults") {
                        session.apiBaseURL = URL(string: "http://localhost:11434/v1")!
                        session.apiKey = nil
                        session.providerName = "Ollama"
                        // Don't set a default model - let user select from fetched list
                        apiURLString = session.apiBaseURL.absoluteString
                        session.persistSettings()
                        autoFetchModelsIfOllama()
                    }
                    
                    Button("Use OpenAI Defaults") {
                        session.apiBaseURL = URL(string: "https://api.openai.com/v1")!
                        session.providerName = "OpenAI"
                        // Only set model if completely empty
                        if session.model.isEmpty { session.model = "gpt-4o-mini" }
                        apiURLString = session.apiBaseURL.absoluteString
                        session.persistSettings()
                    }
                }
                .buttonStyle(.borderless)
            }
            
            Section("Model Selection") {
                // Show error if no model selected
                if session.model.isEmpty && !availableModels.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Please select a model")
                            .foregroundColor(.orange)
                    }
                    .font(.caption)
                }
                
                // Model selector: prefer fetched list when available, else allow manual entry
                if !availableModels.isEmpty {
                    Picker("Model", selection: $session.model) {
                        if session.model.isEmpty {
                            Text("Select a model...").tag("")
                        }
                        // Show current model even if not in list
                        if !session.model.isEmpty && !availableModels.contains(session.model) {
                            Text("\(session.model) (custom)").tag(session.model)
                        }
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: session.model) { _ in
                        session.persistSettings()
                    }
                    
                    Button("Refresh Models") {
                        loadOllamaModels()
                    }
                    .buttonStyle(.borderless)
                } else {
                    HStack(spacing: 8) {
                        TextField("Model (e.g. llama3.1, mistral, gpt-4o-mini)", text: $session.model)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: session.model) { _ in
                                session.persistSettings()
                            }
                        
                        Button(action: loadOllamaModels) {
                            if loadingModels {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Text("Fetch Models")
                            }
                        }
                        .disabled(loadingModels)
                        .help("Fetch list of available models from the server")
                    }
                }
                
                if let err = fetchError {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                if let err = session.modelFetchError {
                    Text(err)
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }
            

            Section("Session Info") {
                HStack {
                    Text("Session ID:")
                    Text(session.id.uuidString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                
                HStack {
                    Text("Session Title:")
                    TextField("Session Title", text: $session.sessionTitle)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: session.sessionTitle) { _ in
                            session.persistSettings()
                        }
                }
                
                Button("Clear Chat History") {
                    session.clearChat()
                }
                .foregroundColor(.red)
            }
        }
        .padding(16)
        .frame(width: 600, height: 500)
        .onAppear {
            apiURLString = session.apiBaseURL.absoluteString
            autoFetchModelsIfOllama()
        }
    }
    
    private func loadOllamaModels() {
        guard session.apiBaseURL.host == "localhost" || session.apiBaseURL.host == "127.0.0.1" else {
            fetchError = "Model fetching is only available for local Ollama instances (localhost)."
            return
        }
        
        loadingModels = true
        fetchError = nil
        availableModels = []
        
        Task {
            defer { 
                Task { @MainActor in
                    loadingModels = false
                }
            }
            
            do {
                let base = session.apiBaseURL.absoluteString
                let urlString = base.replacingOccurrences(of: "/v1", with: "") + "/api/tags"
                guard let url = URL(string: urlString) else {
                    await MainActor.run { fetchError = "Invalid URL format" }
                    return
                }
                
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.timeoutInterval = 10
                
                let (data, response) = try await URLSession.shared.data(for: req)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    await MainActor.run { 
                        fetchError = "Failed to connect to Ollama. Make sure Ollama is running on \(session.apiBaseURL.host ?? "localhost")." 
                    }
                    return
                }
                
                struct TagsResponse: Decodable {
                    struct Model: Decodable { 
                        let name: String 
                    }
                    let models: [Model]
                }
                
                if let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data) {
                    let modelNames = decoded.models.map { $0.name }.sorted()
                    await MainActor.run {
                        self.availableModels = modelNames
                        if modelNames.isEmpty {
                            fetchError = "No models found. Pull a model with: ollama pull llama3.1"
                        } else {
                            fetchError = nil
                            // Update session's available models
                            session.availableModels = modelNames
                            session.modelFetchError = nil
                            
                            // Auto-select first model if none selected
                            if session.model.isEmpty && !modelNames.isEmpty {
                                session.model = modelNames[0]
                                session.persistSettings()
                            }
                            // Show warning if current model is not in the list, but don't override it
                            // The user may have a valid model that's not currently available
                            else if !session.model.isEmpty && !modelNames.contains(session.model) {
                                fetchError = "Note: Model '\(session.model)' not found in available models. It may still be valid."
                                // Don't automatically change the model - let the user decide
                            }
                        }
                    }
                } else {
                    await MainActor.run { 
                        fetchError = "Unable to decode models list. Check if Ollama is running correctly." 
                    }
                }
            } catch {
                await MainActor.run { 
                    fetchError = "Connection failed: \(error.localizedDescription)\nMake sure Ollama is running: ollama serve"
                }
            }
        }
    }
    
    private func autoFetchModelsIfOllama() {
        let host = session.apiBaseURL.host?.lowercased() ?? ""
        if host == "localhost" || host == "127.0.0.1" {
            loadOllamaModels()
        }
    }
}
