import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @State var showAdvanced: Bool
    @State private var availableModels: [String] = []
    @State private var loadingModels: Bool = false
    @State private var fetchError: String? = nil

    var body: some View {
        Form {
            Section("Provider") {
                TextField("API Base URL", text: Binding(
                    get: { chat.apiBaseURL.absoluteString },
                    set: { if let u = URL(string: $0) { chat.apiBaseURL = u } }
                ))
                .textFieldStyle(.roundedBorder)

                SecureField("API Key (optional)", text: Binding(
                    get: { chat.apiKey ?? "" },
                    set: { chat.apiKey = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)

                // Model selector: prefer fetched list when available, else allow manual entry
                if !availableModels.isEmpty {
                    Picker("Model", selection: $chat.model) {
                        ForEach(availableModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    HStack(spacing: 8) {
                        TextField("Model (e.g. llama3.1, mistral, gpt-4o-mini)", text: $chat.model)
                            .textFieldStyle(.roundedBorder)
                        Button(action: loadOllamaModels) {
                            if loadingModels { ProgressView() } else { Text("Fetch Models") }
                        }
                        .help("Fetch list of Ollama models from the local server")
                    }
                }
                if let err = fetchError {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }


            if showAdvanced {
                Section("Advanced") {
                    Text("Future advanced settings go here.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            autoFetchModelsIfOllama()
        }
    }

    private func loadOllamaModels() {
        guard chat.apiBaseURL.host == "localhost" || chat.apiBaseURL.host == "127.0.0.1" else {
            fetchError = "Models fetch available only for local Ollama (localhost)."
            return
        }
        loadingModels = true
        fetchError = nil
        Task {
            defer { loadingModels = false }
            do {
                let url = URL(string: chat.apiBaseURL.absoluteString.replacingOccurrences(of: "/v1", with: "") + "/api/tags")!
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                let (data, _) = try await URLSession.shared.data(for: req)
                struct TagsResponse: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
                if let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data) {
                    await MainActor.run {
                        availableModels = decoded.models.map { $0.name }
                        if let first = availableModels.first, !availableModels.contains(chat.model) || chat.model.isEmpty {
                            chat.model = first
                        }
                    }
                } else {
                    await MainActor.run { fetchError = "Unable to decode models list." }
                }
            } catch {
                await MainActor.run { fetchError = "Failed to fetch models from Ollama." }
            }
        }
    }

    private func autoFetchModelsIfOllama() {
        let host = chat.apiBaseURL.host?.lowercased() ?? ""
        if host == "localhost" || host == "127.0.0.1" { loadOllamaModels() }
    }
}


