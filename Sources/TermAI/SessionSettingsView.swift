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
    let provider: ChatSession.LocalProvider
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
    
    private var selectedLocalProvider: ChatSession.LocalProvider? {
        ChatSession.LocalProvider(rawValue: session.providerName)
    }
    
    private var isCloudProvider: Bool {
        session.providerType.isCloud
    }
    
    private var availableCloudProviders: [CloudProvider] {
        CloudAPIKeyManager.shared.availableProviders
    }
    
    @ObservedObject private var apiKeyManager = CloudAPIKeyManager.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Quick Start Guide (shown when no model configured)
                if session.model.isEmpty && session.availableModels.isEmpty {
                    quickStartCard
                }
                
                // Provider Selection Card
                providerSelectionCard
                
                // Cloud API Keys Card (for cloud providers)
                if isCloudProvider {
                    cloudAPIKeysCard
                }
                
                // Connection Settings Card (only for local providers)
                if !isCloudProvider {
                    connectionSettingsCard
                }
                
                // Model Selection Card
                modelSelectionCard
                
                // Generation Settings Card
                generationSettingsCard
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            apiURLString = session.apiBaseURL.absoluteString
            if !isCloudProvider {
                testConnection()
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
                    message: "Set OPENAI_API_KEY or ANTHROPIC_API_KEY environment variable to enable cloud providers.",
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
                    ForEach([ChatSession.LocalProvider.ollama, .lmStudio, .vllm], id: \.rawValue) { provider in
                        let isSelected = session.providerType == .local(LocalLLMProvider(rawValue: provider.rawValue)!)
                        
                        ProviderBadge(
                            provider: provider,
                            isSelected: isSelected
                        )
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                session.switchToLocalProvider(LocalLLMProvider(rawValue: provider.rawValue)!)
                                let def = provider.defaultBaseURL
                                apiURLString = def.absoluteString
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
    
    // MARK: - Cloud API Keys Card
    private var cloudAPIKeysCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("API Keys", subtitle: "Configure cloud provider authentication")
            
            VStack(spacing: 16) {
                // OpenAI API Key
                cloudAPIKeyField(for: .openai)
                
                Divider()
                
                // Anthropic API Key
                cloudAPIKeyField(for: .anthropic)
            }
        }
        .settingsCard()
    }
    
    private func cloudAPIKeyField(for provider: CloudProvider) -> some View {
        let hasEnvKey = apiKeyManager.getEnvironmentKey(for: provider) != nil
        let hasOverride = apiKeyManager.hasOverride(for: provider)
        let isFromEnv = apiKeyManager.isFromEnvironment(for: provider)
        
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: provider.icon)
                    .font(.system(size: 14))
                    .foregroundColor(provider == .openai ? .green : .orange)
                
                Text("\(provider.rawValue) API Key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                
                Spacer()
                
                if isFromEnv {
                    Text("from \(provider.apiKeyEnvVariable)")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.green.opacity(0.1))
                        )
                } else if hasOverride {
                    Text("custom")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.1))
                        )
                }
            }
            
            HStack(spacing: 8) {
                SecureField(
                    hasEnvKey ? "Override environment variable..." : "Enter API key...",
                    text: Binding(
                        get: { apiKeyManager.getOverride(for: provider) ?? "" },
                        set: { apiKeyManager.setOverride($0.isEmpty ? nil : $0, for: provider) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(hasOverride ? Color.blue.opacity(0.3) : Color.primary.opacity(0.1), lineWidth: 1)
                )
                
                if hasOverride {
                    Button(action: {
                        apiKeyManager.setOverride(nil, for: provider)
                    }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Revert to environment variable")
                }
            }
            
            if hasEnvKey && !hasOverride {
                Text("Using key from environment variable. Enter a value above to override.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else if !hasEnvKey && !hasOverride {
                Text("No API key found. Set \(provider.apiKeyEnvVariable) environment variable or enter a key above.")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
    }
    
    // MARK: - Connection Settings Card
    private var connectionSettingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SettingsSectionHeader("Connection", subtitle: "API endpoint and authentication")
                Spacer()
                ConnectionStatusBadge(status: connectionStatus)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                // API URL
                VStack(alignment: .leading, spacing: 6) {
                    Text("API URL")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    TextField("http://localhost:11434/v1", text: $apiURLString)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        .onChange(of: apiURLString) { newValue in
                            if let url = URL(string: newValue) {
                                session.apiBaseURL = url
                                session.persistSettings()
                                connectionStatus = .unknown
                            }
                        }
                }
                
                // API Key
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("API Key")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Text("(optional)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    
                    SecureField("Enter API key if required", text: Binding(
                        get: { session.apiKey ?? "" },
                        set: { session.apiKey = $0.isEmpty ? nil : $0; session.persistSettings() }
                    ))
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
                }
            }
            
            // Test Connection Button
            HStack {
                Button(action: testConnection) {
                    HStack(spacing: 6) {
                        if isTestingConnection {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 12))
                        }
                        Text("Test Connection")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor)
                    )
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(isTestingConnection)
                
                Spacer()
            }
            
            // Connection Error
            if case .disconnected(let error) = connectionStatus {
                AlertCallout(message: error, type: .error)
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
                        
                        ForEach(session.availableModels, id: \.self) { modelId in
                            Button(action: {
                                session.model = modelId
                                session.persistSettings()
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(displayName(for: modelId))
                                        if isCloudProvider && displayName(for: modelId) != modelId {
                                            Text(modelId)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    if CuratedModels.supportsReasoning(modelId: modelId) {
                                        Image(systemName: "brain")
                                            .font(.caption)
                                            .foregroundColor(.purple)
                                    }
                                    
                                    if session.model == modelId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "cpu")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            
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
                            
                            if session.currentModelSupportsReasoning {
                                Image(systemName: "brain")
                                    .font(.caption)
                                    .foregroundColor(.purple)
                                    .help("Supports reasoning/thinking")
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
}

