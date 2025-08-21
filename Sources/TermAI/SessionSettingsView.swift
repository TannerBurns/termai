import SwiftUI

struct SessionSettingsView: View {
    @ObservedObject var session: ChatSession
    @State private var apiURLString: String = ""
    @State private var isFetching: Bool = false
    
    var body: some View {
        Form {
            Section("Provider Configuration") {
                HStack {
                    Text("Provider:")
                    Picker("Provider", selection: $session.providerName) {
                        Text("Ollama").tag(ChatSession.LocalProvider.ollama.rawValue)
                        Text("LM Studio").tag(ChatSession.LocalProvider.lmStudio.rawValue)
                        Text("vLLM").tag(ChatSession.LocalProvider.vllm.rawValue)
                    }
                    .labelsHidden()
                    .onChange(of: session.providerName) { newValue in
                        if let prov = ChatSession.LocalProvider(rawValue: newValue) {
                            let def = prov.defaultBaseURL
                            session.apiBaseURL = def
                            apiURLString = def.absoluteString
                        }
                        session.persistSettings()
                        Task { @MainActor in
                            isFetching = true
                            defer { isFetching = false }
                            await session.fetchAvailableModels()
                        }
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
            }
            
            Section("Model Selection") {
                // Show error if no model selected
                if session.model.isEmpty && !session.availableModels.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Please select a model")
                            .foregroundColor(.orange)
                    }
                    .font(.caption)
                }
                
                // Model selector: prefer fetched list when available, else allow manual entry
                if !session.availableModels.isEmpty {
                    Picker("Model", selection: $session.model) {
                        if session.model.isEmpty {
                            Text("Select a model...").tag("")
                        }
                        // Show current model even if not in list
                        if !session.model.isEmpty && !session.availableModels.contains(session.model) {
                            Text("\(session.model) (custom)").tag(session.model)
                        }
                        ForEach(session.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: session.model) { _ in
                        session.persistSettings()
                    }
                    
                    Button("Refresh Models") {
                        Task { @MainActor in
                            isFetching = true
                            defer { isFetching = false }
                            await session.fetchAvailableModels()
                        }
                    }
                    .buttonStyle(.borderless)
                } else {
                    HStack(spacing: 8) {
                        TextField("Model (e.g. llama3.1, mistral, gpt-4o-mini)", text: $session.model)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: session.model) { _ in
                                session.persistSettings()
                            }
                        
                        Button(action: {
                            Task { @MainActor in
                                isFetching = true
                                defer { isFetching = false }
                                await session.fetchAvailableModels()
                            }
                        }) {
                            if isFetching {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Text("Fetch Models")
                            }
                        }
                        .disabled(isFetching)
                        .help("Fetch list of available models from the server")
                    }
                }
                
                if let err = session.modelFetchError {
                    Text(err)
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }
            

            
        }
        .padding(16)
        .frame(width: 600, height: 500)
        .onAppear {
            apiURLString = session.apiBaseURL.absoluteString
            Task { @MainActor in
                isFetching = true
                defer { isFetching = false }
                await session.fetchAvailableModels()
            }
        }
    }
    
}
