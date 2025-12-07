import SwiftUI

// MARK: - Connection Status
enum ConnectionStatus: Equatable {
    case unknown
    case checking
    case connected(modelCount: Int)
    case disconnected(error: String)
    
    var color: Color {
        switch self {
        case .unknown: return .gray
        case .checking: return .orange
        case .connected: return .green
        case .disconnected: return .red
        }
    }
    
    var label: String {
        switch self {
        case .unknown: return "Not checked"
        case .checking: return "Checking..."
        case .connected(let count): return "Connected (\(count) models)"
        case .disconnected: return "Disconnected"
        }
    }
}

// MARK: - Card Style Modifier
struct SettingsCardStyle: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark 
                          ? Color(white: 0.12) 
                          : Color(white: 0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(colorScheme == .dark 
                            ? Color.white.opacity(0.08) 
                            : Color.black.opacity(0.06), lineWidth: 1)
            )
    }
}

extension View {
    func settingsCard() -> some View {
        modifier(SettingsCardStyle())
    }
}

// MARK: - Provider Badge View
struct ProviderBadge: View {
    let provider: LocalLLMProvider
    let isSelected: Bool
    
    var icon: String {
        switch provider {
        case .ollama: return "cube.fill"
        case .lmStudio: return "sparkles"
        case .vllm: return "bolt.fill"
        }
    }
    
    var accentColor: Color {
        switch provider {
        case .ollama: return .blue
        case .lmStudio: return .purple
        case .vllm: return .orange
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isSelected ? accentColor : Color.gray.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .gray)
            }
            
            Text(provider.rawValue)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
        }
        .frame(width: 80)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? accentColor.opacity(0.5) : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Cloud Provider Badge View
struct CloudProviderBadge: View {
    let provider: CloudProvider
    let isSelected: Bool
    let isAvailable: Bool
    
    var accentColor: Color {
        switch provider {
        case .openai: return .green
        case .anthropic: return .orange
        case .google: return .blue
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isSelected ? accentColor : (isAvailable ? Color.gray.opacity(0.2) : Color.gray.opacity(0.1)))
                    .frame(width: 44, height: 44)
                
                Image(systemName: provider.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isSelected ? .white : (isAvailable ? .gray : .gray.opacity(0.4)))
            }
            
            VStack(spacing: 2) {
                Text(provider.rawValue)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : (isAvailable ? .secondary : .secondary.opacity(0.5)))
                
                if !isAvailable {
                    Text("No API Key")
                        .font(.system(size: 8))
                        .foregroundColor(.orange)
                }
            }
        }
        .frame(width: 80)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? accentColor.opacity(0.5) : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .opacity(isAvailable ? 1.0 : 0.6)
    }
}

// MARK: - Connection Status Badge
struct ConnectionStatusBadge: View {
    let status: ConnectionStatus
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
            
            if case .checking = status {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
            
            Text(status.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(status.color.opacity(0.1))
        )
    }
}

// MARK: - Alert Callout View
struct AlertCallout: View {
    let message: String
    let type: AlertType
    
    enum AlertType {
        case warning, error, info
        
        var icon: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .warning: return .orange
            case .error: return .red
            case .info: return .blue
            }
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: type.icon)
                .font(.system(size: 14))
                .foregroundColor(type.color)
            
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(type.color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(type.color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Section Header
struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String?
    
    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Main Session Settings View
struct SessionSettingsView: View {
    @ObservedObject var session: ChatSession
    @State private var apiURLString: String = ""
    @State private var isFetching: Bool = false
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var isTestingConnection: Bool = false
    
    // Terminal suggestions local models (fetched independently from session)
    @State private var terminalSuggestionsLocalModels: [String] = []
    @State private var isFetchingTerminalSuggestionsModels: Bool = false
    @State private var terminalSuggestionsModelsError: String? = nil
    
    private var selectedLocalProvider: LocalLLMProvider? {
        LocalLLMProvider(rawValue: session.providerName)
    }
    
    private var isCloudProvider: Bool {
        session.providerType.isCloud
    }
    
    private var availableCloudProviders: [CloudProvider] {
        CloudAPIKeyManager.shared.availableProviders
    }
    
    @ObservedObject private var apiKeyManager = CloudAPIKeyManager.shared
    @ObservedObject private var agentSettings = AgentSettings.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Quick Start Guide (shown when no model configured)
                if session.model.isEmpty && session.availableModels.isEmpty {
                    quickStartCard
                }
                
                // Provider Selection Card
                providerSelectionCard
                
                // Model Selection Card
                modelSelectionCard
                
                // Generation Settings Card
                generationSettingsCard
                
                // Context Size Card (only for local providers)
                if !isCloudProvider {
                    contextSizeCard
                }
                
                // Terminal Suggestions Card (global setting)
                terminalSuggestionsCard
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            // For local providers, sync the URL from global AgentSettings
            if case .local(let provider) = session.providerType {
                let url = agentSettings.baseURL(for: provider)
                session.apiBaseURL = url
                apiURLString = url.absoluteString
                testConnection()
            } else {
                apiURLString = session.apiBaseURL.absoluteString
            }
            
            // Auto-fetch models for terminal suggestions if local provider is selected
            if case .local(let provider) = agentSettings.terminalSuggestionsProvider {
                fetchTerminalSuggestionsModels(for: provider)
            }
        }
    }
    
    // MARK: - Quick Start Card
    private var quickStartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundColor(.blue)
                
                Text("Get Started")
                    .font(.system(size: 15, weight: .semibold))
            }
            
            Text("Connect to a local LLM provider to start chatting. Make sure your provider is running, then select it below and fetch available models.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            HStack(spacing: 16) {
                quickStartStep(number: 1, text: "Select provider")
                quickStartStep(number: 2, text: "Verify connection")
                quickStartStep(number: 3, text: "Choose model")
            }
            .padding(.top, 4)
        }
        .settingsCard()
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func quickStartStep(number: Int, text: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.blue)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Provider Selection Card
    private var providerSelectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Provider", subtitle: "Choose your LLM backend")
            
            // Cloud Providers Section
            if !availableCloudProviders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cloud Providers")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 12) {
                        ForEach(CloudProvider.allCases, id: \.rawValue) { provider in
                            let isAvailable = apiKeyManager.hasAPIKey(for: provider)
                            let isSelected = session.providerType == .cloud(provider)
                            
                            CloudProviderBadge(
                                provider: provider,
                                isSelected: isSelected,
                                isAvailable: isAvailable
                            )
                            .onTapGesture {
                                guard isAvailable else { return }
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    session.switchToCloudProvider(provider)
                                    connectionStatus = .connected(modelCount: session.availableModels.count)
                                }
                            }
                        }
                        
                        Spacer()
                    }
                }
            } else {
                AlertCallout(
                    message: "Configure API keys in the Providers tab to enable cloud providers.",
                    type: .info
                )
            }
            
            Divider()
            
            // Local Providers Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Local Providers")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    ForEach([LocalLLMProvider.ollama, .lmStudio, .vllm], id: \.rawValue) { provider in
                        let isSelected = session.providerType == .local(provider)
                        
                        ProviderBadge(
                            provider: provider,
                            isSelected: isSelected
                        )
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                session.switchToLocalProvider(LocalLLMProvider(rawValue: provider.rawValue)!)
                                // Use URL from global AgentSettings
                                let url = agentSettings.baseURL(for: provider)
                                session.apiBaseURL = url
                                apiURLString = url.absoluteString
                                connectionStatus = .unknown
                                testConnection()
                            }
                        }
                    }
                    
                    Spacer()
                }
            }
        }
        .settingsCard()
    }
    
    // MARK: - Model Selection Card
    private var modelSelectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SettingsSectionHeader("Model", subtitle: "Select the AI model to use for chat")
                Spacer()
                
                if isFetching {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            
            // Warning if no model selected
            if session.model.isEmpty && !session.availableModels.isEmpty {
                AlertCallout(message: "Please select a model to start chatting", type: .warning)
            }
            
            // Model Picker or Manual Entry
            if !session.availableModels.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    // Model Picker
                    Menu {
                        if session.model.isEmpty {
                            Button("Select a model...") { }
                                .disabled(true)
                        }
                        
                        if !session.model.isEmpty && !session.availableModels.contains(session.model) {
                            Button("\(session.model) (custom)") {
                                // Keep current
                            }
                            Divider()
                        }
                        
                        // Favorites section
                        let favoriteModels = session.availableModels.filter { agentSettings.isFavorite($0) }
                        if !favoriteModels.isEmpty {
                            Section {
                                ForEach(favoriteModels, id: \.self) { modelId in
                                    modelMenuButton(for: modelId, isFavorite: true)
                                }
                            } header: {
                                Label("Favorites", systemImage: "star.fill")
                            }
                            
                            Divider()
                        }
                        
                        // All models section
                        Section {
                            ForEach(session.availableModels, id: \.self) { modelId in
                                modelMenuButton(for: modelId, isFavorite: agentSettings.isFavorite(modelId))
                            }
                        } header: {
                            Text("All Models")
                        }
                    } label: {
                        HStack {
                            // Show enhanced brain for reasoning models, cpu for others
                            if session.currentModelSupportsReasoning {
                                ReasoningBrainIcon(size: .medium, showGlow: true)
                                    .help("Supports reasoning/thinking")
                            } else {
                                Image(systemName: "cpu")
                                .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.model.isEmpty ? "Select a model..." : displayName(for: session.model))
                                    .font(.system(size: 13, weight: session.model.isEmpty ? .regular : .medium))
                                    .foregroundColor(session.model.isEmpty ? .secondary : .primary)
                                
                                if !session.model.isEmpty && isCloudProvider && displayName(for: session.model) != session.model {
                                    Text(session.model)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            // Favorite indicator - RIGHT of model name
                            if !session.model.isEmpty && agentSettings.isFavorite(session.model) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.yellow)
                            }
                            
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(session.model.isEmpty ? Color.orange.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .help("Click a model to see options including favorite toggle")
                    
                    // Refresh button (only for local providers)
                    if !isCloudProvider {
                        Button(action: fetchModels) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                                Text("Refresh model list")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(isFetching)
                    }
                }
            } else {
                // Manual entry with fetch button
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        TextField("e.g. llama3.1, mistral, gpt-4o-mini", text: $session.model)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                            .onChange(of: session.model) { _ in
                                session.persistSettings()
                            }
                        
                        Button(action: fetchModels) {
                            HStack(spacing: 6) {
                                if isFetching {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 12))
                                }
                                Text("Fetch Models")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isFetching)
                        .help("Fetch list of available models from the server")
                    }
                    
                    if case .connected = connectionStatus {
                        Text("Connection verified. Click 'Fetch Models' to load available models.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else if case .disconnected = connectionStatus {
                        Text("Cannot fetch models while disconnected. Check your connection settings.")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }
            }
            
            // Model fetch error
            if let err = session.modelFetchError {
                AlertCallout(message: err, type: .warning)
            }
        }
        .settingsCard()
    }
    
    private func displayName(for modelId: String) -> String {
        CuratedModels.find(id: modelId)?.displayName ?? modelId
    }
    
    /// Creates a menu button for model selection with favorite toggle via submenu
    @ViewBuilder
    private func modelMenuButton(for modelId: String, isFavorite: Bool) -> some View {
        Menu {
            // Select this model
        Button(action: {
            session.model = modelId
            session.updateContextLimit()
            session.persistSettings()
        }) {
                Label("Select", systemImage: "checkmark.circle")
            }
            
            Divider()
            
            // Toggle favorite
            Button(action: {
                agentSettings.toggleFavorite(modelId)
            }) {
                if isFavorite {
                    Label("Remove from Favorites", systemImage: "star.slash")
                } else {
                    Label("Add to Favorites", systemImage: "star")
                }
            }
        } label: {
            HStack {
                // Show enhanced brain for reasoning models (in menu items)
                if CuratedModels.supportsReasoning(modelId: modelId) {
                    ReasoningBrainIcon(size: .small)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: modelId))
                    if isCloudProvider && displayName(for: modelId) != modelId {
                        Text(modelId)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Favorite indicator - RIGHT of model name
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.yellow)
                }
                
                if session.model == modelId {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
    
    // MARK: - Generation Settings Card
    private var generationSettingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Generation Settings", subtitle: "Control model output behavior")
            
            VStack(alignment: .leading, spacing: 16) {
                // Temperature Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Temperature")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        if session.currentModelSupportsReasoning {
                            Text("(locked for reasoning models)")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                        
                        Spacer()
                        
                        Text(String(format: "%.1f", session.currentModelSupportsReasoning ? 1.0 : session.temperature))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(session.currentModelSupportsReasoning ? .orange : .primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(session.currentModelSupportsReasoning ? Color.orange.opacity(0.1) : Color.primary.opacity(0.05))
                            )
                    }
                    
                    HStack(spacing: 8) {
                        Text("0.1")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        
                        Slider(value: $session.temperature, in: 0.1...1.0, step: 0.1)
                            .disabled(session.currentModelSupportsReasoning)
                            .onChange(of: session.temperature) { _ in
                                session.persistSettings()
                            }
                        
                        Text("1.0")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .opacity(session.currentModelSupportsReasoning ? 0.5 : 1.0)
                    
                    if session.currentModelSupportsReasoning {
                        Text("Reasoning models require temperature = 1.0 for optimal performance.")
                            .font(.system(size: 11))
                            .foregroundColor(.orange.opacity(0.8))
                    } else {
                        Text("Lower values make output more focused and deterministic. Higher values make it more creative and varied.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }
                
                Divider()
                
                // Max Tokens
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Max Tokens")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        TextField("", value: $session.maxTokens, format: .number)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                            .onChange(of: session.maxTokens) { _ in
                                session.persistSettings()
                            }
                    }
                    
                    Text("Maximum number of tokens in the response. Higher values allow longer responses.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                
                // Reasoning Effort (only for models that support it)
                if session.currentModelSupportsReasoning {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reasoning Effort")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Picker("", selection: $session.reasoningEffort) {
                            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                                Text(effort.rawValue).tag(effort)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: session.reasoningEffort) { _ in
                            session.persistSettings()
                        }
                        
                        Text("Controls how much the model 'thinks' before responding. Higher effort may produce better results for complex tasks.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                        
                        if case .cloud(let provider) = session.providerType {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 10))
                                Text(provider == .openai ? "Uses OpenAI's reasoning_effort parameter" : "Uses Anthropic's extended thinking feature")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(.blue.opacity(0.8))
                            .padding(.top, 2)
                        }
                    }
                }
            }
        }
        .settingsCard()
    }
    
    // MARK: - Context Size Card
    private var contextSizeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SettingsSectionHeader("Context Window", subtitle: "Set the context size for your local model")
                Spacer()
                
                // Current usage indicator (show 0% until first response)
                HStack(spacing: 4) {
                    Circle()
                        .fill(contextUsageColor)
                        .frame(width: 6, height: 6)
                    let usagePercent = session.hasAssistantResponse ? session.contextUsagePercent : 0
                    Text(String(format: "%.0f%% used", usagePercent * 100))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            VStack(alignment: .leading, spacing: 12) {
                // Custom context size toggle
                Toggle(isOn: Binding(
                    get: { session.customLocalContextSize != nil },
                    set: { enabled in
                        if enabled {
                            session.customLocalContextSize = session.contextLimitTokens
                        } else {
                            session.customLocalContextSize = nil
                            session.updateContextLimit()
                        }
                        session.persistSettings()
                    }
                )) {
                    HStack {
                        Text("Use custom context size")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                
                if session.customLocalContextSize != nil {
                    // Context size input
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Context Size (tokens)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            TextField("", value: Binding(
                                get: { session.customLocalContextSize ?? 32000 },
                                set: { newValue in
                                    session.customLocalContextSize = newValue
                                    session.updateContextLimit()
                                    session.persistSettings()
                                }
                            ), format: .number)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        }
                        
                        // Preset buttons
                        HStack(spacing: 8) {
                            Text("Presets:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            ForEach([4_096, 8_192, 16_384, 32_768, 65_536, 131_072], id: \.self) { size in
                                Button(action: {
                                    session.customLocalContextSize = size
                                    session.updateContextLimit()
                                    session.persistSettings()
                                }) {
                                    Text(formatContextSize(size))
                                        .font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(session.customLocalContextSize == size 
                                                      ? Color.accentColor.opacity(0.15) 
                                                      : Color.primary.opacity(0.05))
                                        )
                                        .foregroundColor(session.customLocalContextSize == size 
                                                        ? .accentColor 
                                                        : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                // Current model's detected context size
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    if session.customLocalContextSize != nil {
                        Text("Auto-detected size for '\(session.model.isEmpty ? "unknown model" : session.model)': \(formatContextSize(ModelDefinition.contextSize(for: session.model)))")
                    } else {
                        Text("Using auto-detected context size: \(formatContextSize(session.contextLimitTokens))")
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.8))
                
                // Help text
                Text("Set a custom context size if your local model supports a different context window than detected. Common sizes: 4K, 8K, 32K, 128K.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsCard()
    }
    
    private var contextUsageColor: Color {
        // Show 0% (green) until first assistant response
        let percent = session.hasAssistantResponse ? session.contextUsagePercent : 0
        switch percent {
        case 0..<0.6: return .green
        case 0.6..<0.8: return .yellow
        case 0.8..<0.9: return .orange
        default: return .red
        }
    }
    
    private func formatContextSize(_ size: Int) -> String {
        if size >= 1_000_000 {
            return String(format: "%.0fM", Double(size) / 1_000_000)
        } else if size >= 1_000 {
            return String(format: "%.0fK", Double(size) / 1_000)
        }
        return "\(size)"
    }
    
    // MARK: - Terminal Suggestions Model Fetching
    
    private func fetchTerminalSuggestionsModels(for provider: LocalLLMProvider) {
        isFetchingTerminalSuggestionsModels = true
        terminalSuggestionsModelsError = nil
        
        Task {
            defer {
                Task { @MainActor in
                    isFetchingTerminalSuggestionsModels = false
                }
            }
            
            do {
                let models = try await LocalProviderService.fetchModels(for: provider)
                await MainActor.run {
                    terminalSuggestionsLocalModels = models
                    if models.isEmpty {
                        terminalSuggestionsModelsError = "No models found"
                    }
                }
            } catch {
                await MainActor.run {
                    terminalSuggestionsModelsError = error.localizedDescription
                    terminalSuggestionsLocalModels = []
                }
            }
        }
    }
    
    // MARK: - Actions
    private func testConnection() {
        isTestingConnection = true
        connectionStatus = .checking
        
        Task { @MainActor in
            defer { isTestingConnection = false }
            
            // Try to fetch models to test connection
            await session.fetchAvailableModels()
            
            if let error = session.modelFetchError {
                connectionStatus = .disconnected(error: error)
            } else if !session.availableModels.isEmpty {
                connectionStatus = .connected(modelCount: session.availableModels.count)
            } else {
                connectionStatus = .disconnected(error: "No models found or connection failed")
            }
        }
    }
    
    private func fetchModels() {
        isFetching = true
        Task { @MainActor in
            defer { isFetching = false }
            await session.fetchAvailableModels()
            
            if session.modelFetchError == nil && !session.availableModels.isEmpty {
                connectionStatus = .connected(modelCount: session.availableModels.count)
            }
        }
    }
    
    // MARK: - Terminal Suggestions Card
    
    /// Helper to check if terminal suggestions are fully configured
    /// Using a local computed property ensures SwiftUI properly tracks the @Published dependencies
    private var isTerminalSuggestionsFullyConfigured: Bool {
        agentSettings.terminalSuggestionsEnabled &&
        agentSettings.terminalSuggestionsModelId != nil &&
        agentSettings.terminalSuggestionsProvider != nil
    }
    
    private var terminalSuggestionsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SettingsSectionHeader("Terminal AI Suggestions", subtitle: "Real-time command suggestions as you work")
                Spacer()
                
                // Configuration status badge
                if !isTerminalSuggestionsFullyConfigured && agentSettings.terminalSuggestionsEnabled {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text("Setup Required")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.15))
                    )
                } else if isTerminalSuggestionsFullyConfigured {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                        Text("Configured")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.15))
                    )
                }
            }
            
            VStack(spacing: 16) {
                // Enable/Disable Toggle
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Terminal Suggestions")
                            .font(.system(size: 13, weight: .medium))
                        Text("Show AI-powered command suggestions while working in the terminal.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: Binding(
                        get: { agentSettings.terminalSuggestionsEnabled },
                        set: { 
                            agentSettings.terminalSuggestionsEnabled = $0
                            agentSettings.save()
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                
                if agentSettings.terminalSuggestionsEnabled {
                    Divider()
                    
                    // Warning if not configured
                    if agentSettings.terminalSuggestionsModelId == nil {
                        AlertCallout(
                            message: "Select a model below to enable terminal suggestions. A lightweight model like gpt-4o-mini or claude-3-5-haiku is recommended for fast responses.",
                            type: .warning
                        )
                    }
                    
                    // Provider Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Suggestions Provider")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        terminalSuggestionsProviderPicker
                    }
                    
                    // Model Selection (only if provider is selected)
                    if agentSettings.terminalSuggestionsProvider != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suggestions Model")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            terminalSuggestionsModelPicker
                        }
                        
                        // Reasoning Effort (only for models that support it)
                        if let modelId = agentSettings.terminalSuggestionsModelId,
                           CuratedModels.supportsReasoning(modelId: modelId) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Reasoning Effort")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                
                                Picker("", selection: Binding(
                                    get: { agentSettings.terminalSuggestionsReasoningEffort },
                                    set: {
                                        agentSettings.terminalSuggestionsReasoningEffort = $0
                                        agentSettings.save()
                                    }
                                )) {
                                    ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                                        Text(effort.rawValue).tag(effort)
                                    }
                                }
                                .pickerStyle(.segmented)
                                
                                Text("Controls how much the model 'thinks' before responding. Higher effort may improve suggestions but takes longer.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary.opacity(0.8))
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Shell History Toggle
                    shellHistorySection
                    
                    Divider()
                    
                    // Debounce Setting
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Suggestion Delay")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Text(String(format: "%.1fs", agentSettings.terminalSuggestionsDebounceSeconds))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.05))
                                )
                        }
                        
                        Slider(
                            value: Binding(
                                get: { agentSettings.terminalSuggestionsDebounceSeconds },
                                set: { 
                                    agentSettings.terminalSuggestionsDebounceSeconds = $0
                                    agentSettings.save()
                                }
                            ),
                            in: 1.0...5.0,
                            step: 0.5
                        )
                        
                        Text("Time to wait after terminal activity before generating suggestions.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }
            }
        }
        .settingsCard()
        .animation(.easeInOut(duration: 0.2), value: agentSettings.terminalSuggestionsEnabled)
        .animation(.easeInOut(duration: 0.2), value: agentSettings.terminalSuggestionsModelId)
        .animation(.easeInOut(duration: 0.2), value: agentSettings.terminalSuggestionsProvider)
        .animation(.easeInOut(duration: 0.2), value: agentSettings.terminalSuggestionsReasoningEffort)
    }
    
    // MARK: - Terminal Suggestions Provider Picker
    private var terminalSuggestionsProviderPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Cloud Providers
            if apiKeyManager.availableProviders.isEmpty {
                Text("Configure API keys in the Providers tab to use cloud models.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cloud Providers")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 12) {
                        ForEach(CloudProvider.allCases, id: \.rawValue) { provider in
                            let isAvailable = apiKeyManager.hasAPIKey(for: provider)
                            let isSelected = agentSettings.terminalSuggestionsProvider == .cloud(provider)
                            
                            CloudProviderBadge(
                                provider: provider,
                                isSelected: isSelected,
                                isAvailable: isAvailable
                            )
                            .onTapGesture {
                                guard isAvailable else { return }
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    agentSettings.terminalSuggestionsProvider = .cloud(provider)
                                    // Reset model if switching provider
                                    if !isSelected {
                                        agentSettings.terminalSuggestionsModelId = nil
                                        agentSettings.terminalSuggestionsReasoningEffort = .none
                                    }
                                    agentSettings.save()
                                }
                            }
                        }
                        
                        Spacer()
                    }
                }
            }
            
            // Local Providers
            VStack(alignment: .leading, spacing: 8) {
                Text("Local Providers")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    ForEach(LocalLLMProvider.allCases, id: \.rawValue) { provider in
                        let isSelected = agentSettings.terminalSuggestionsProvider == .local(provider)
                        
                        ProviderBadge(
                            provider: provider,
                            isSelected: isSelected
                        )
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                agentSettings.terminalSuggestionsProvider = .local(provider)
                                // Reset model if switching provider
                                if !isSelected {
                                    agentSettings.terminalSuggestionsModelId = nil
                                    agentSettings.terminalSuggestionsReasoningEffort = .none
                                    // Fetch models for this provider
                                    fetchTerminalSuggestionsModels(for: provider)
                                }
                                agentSettings.save()
                            }
                        }
                    }
                    
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Shell History Section
    
    private var shellHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use Shell History")
                        .font(.system(size: 13, weight: .medium))
                    Text("Read your shell history file to suggest frequently used commands.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Toggle("", isOn: Binding(
                    get: { agentSettings.readShellHistory },
                    set: {
                        agentSettings.readShellHistory = $0
                        agentSettings.save()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            
            // Show history file info if enabled and available
            if agentSettings.readShellHistory {
                if let info = ShellHistoryParser.shared.getHistoryFileInfo() {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reading: \(info.path)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            
                            Text("\(info.shellType.rawValue) • ~\(info.entryCount) entries")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.03))
                    )
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text("No shell history file found")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }
    
    // MARK: - Terminal Suggestions Model Picker
    @ViewBuilder
    private var terminalSuggestionsModelPicker: some View {
        if let provider = agentSettings.terminalSuggestionsProvider {
            switch provider {
            case .cloud(let cloudProvider):
                cloudModelPicker(for: cloudProvider)
            case .local:
                localModelPicker
            }
        }
    }
    
    private func cloudModelPicker(for cloudProvider: CloudProvider) -> some View {
        let models = CuratedModels.models(for: cloudProvider)
        
        return Menu {
            if agentSettings.terminalSuggestionsModelId == nil {
                Button("Select a model...") { }
                    .disabled(true)
            }
            
            // All models with reasoning icon support
            ForEach(models, id: \.id) { model in
                let isSelected = agentSettings.terminalSuggestionsModelId == model.id
                
                Button(action: {
                    agentSettings.terminalSuggestionsModelId = model.id
                    agentSettings.save()
                }) {
                    HStack {
                        if model.supportsReasoning {
                            ReasoningBrainLabel(model.displayName, size: .small)
                        } else {
                            Text(model.displayName)
                        }
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            modelPickerLabel
        }
        .menuStyle(.borderlessButton)
    }
    
    private var localModelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    if agentSettings.terminalSuggestionsModelId == nil {
                        Button("Select a model...") { }
                            .disabled(true)
                    }
                    
                    // Use independently fetched models for terminal suggestions
                    if !terminalSuggestionsLocalModels.isEmpty {
                        ForEach(terminalSuggestionsLocalModels, id: \.self) { modelId in
                            Button(action: {
                                agentSettings.terminalSuggestionsModelId = modelId
                                agentSettings.save()
                            }) {
                                HStack {
                                    Text(modelId)
                                    if agentSettings.terminalSuggestionsModelId == modelId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } else if isFetchingTerminalSuggestionsModels {
                        Text("Loading models...")
                            .foregroundColor(.secondary)
                    } else {
                        Button("Click refresh to load models") { }
                            .disabled(true)
                    }
                } label: {
                    modelPickerLabel
                }
                .menuStyle(.borderlessButton)
                
                // Refresh button
                Button(action: {
                    if case .local(let provider) = agentSettings.terminalSuggestionsProvider {
                        fetchTerminalSuggestionsModels(for: provider)
                    }
                }) {
                    if isFetchingTerminalSuggestionsModels {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(isFetchingTerminalSuggestionsModels)
                .help("Refresh models from provider")
            }
            
            // Error message
            if let error = terminalSuggestionsModelsError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            } else if terminalSuggestionsLocalModels.isEmpty && !isFetchingTerminalSuggestionsModels {
                Text("Make sure your local provider is running, then click refresh.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var modelPickerLabel: some View {
        HStack {
            // Show brain icon for reasoning models, cpu for others
            if let modelId = agentSettings.terminalSuggestionsModelId,
               CuratedModels.supportsReasoning(modelId: modelId) {
                ReasoningBrainIcon(size: .medium, showGlow: true)
            } else {
                Image(systemName: "cpu")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            
            if let modelId = agentSettings.terminalSuggestionsModelId {
                Text(CuratedModels.find(id: modelId)?.displayName ?? modelId)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            } else {
                Text("Select a model...")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(agentSettings.terminalSuggestionsModelId == nil ? Color.orange.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

