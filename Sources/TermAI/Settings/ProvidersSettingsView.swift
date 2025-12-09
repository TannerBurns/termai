import SwiftUI

// MARK: - Providers Settings View

struct ProvidersSettingsView: View {
    @ObservedObject private var apiKeyManager = CloudAPIKeyManager.shared
    @ObservedObject private var agentSettings = AgentSettings.shared
    @Environment(\.colorScheme) var colorScheme
    
    // Connection testing state for each local provider
    @State private var ollamaStatus: ConnectionStatus = .unknown
    @State private var lmStudioStatus: ConnectionStatus = .unknown
    @State private var vllmStatus: ConnectionStatus = .unknown
    @State private var isTestingOllama = false
    @State private var isTestingLMStudio = false
    @State private var isTestingVLLM = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Cloud Providers Section
                cloudProvidersSection
                
                // Local Providers Section
                localProvidersSection
            }
            .padding(24)
        }
        .frame(minWidth: 500)
    }
    
    // MARK: - Cloud Providers Section
    private var cloudProvidersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Cloud Providers", subtitle: "Configure API keys for cloud AI services")
            
            VStack(spacing: 16) {
                // OpenAI
                cloudProviderCard(for: .openai)
                
                Divider()
                
                // Anthropic
                cloudProviderCard(for: .anthropic)
                
                Divider()
                
                // Google AI Studio
                cloudProviderCard(for: .google)
            }
            .settingsCard()
        }
    }
    
    private func cloudProviderCard(for provider: CloudProvider) -> some View {
        let hasEnvKey = apiKeyManager.getEnvironmentKey(for: provider) != nil
        let hasOverride = apiKeyManager.hasOverride(for: provider)
        let isFromEnv = apiKeyManager.isFromEnvironment(for: provider)
        let hasKey = apiKeyManager.hasAPIKey(for: provider)
        
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Provider badge
                ZStack {
                    Circle()
                        .fill(hasKey ? providerColor(for: provider) : Color.gray.opacity(0.2))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: provider.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(hasKey ? .white : .gray)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                    
                    if isFromEnv {
                        Text("Using \(provider.apiKeyEnvVariable)")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    } else if hasOverride {
                        Text("Custom key configured")
                            .font(.system(size: 11))
                            .foregroundColor(.blue)
                    } else {
                        Text("Not configured")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Status indicator
                if hasKey {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Ready")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.1))
                    )
                }
            }
            
            // API Key field
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
                        .stroke(hasOverride ? providerColor(for: provider).opacity(0.3) : Color.primary.opacity(0.1), lineWidth: 1)
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
            
            // Help text
            if hasEnvKey && !hasOverride {
                Text("Using key from environment variable. Enter a value above to override.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else if !hasEnvKey && !hasOverride {
                Text("Set \(provider.apiKeyEnvVariable) environment variable or enter a key above.")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
    }
    
    private func providerColor(for provider: CloudProvider) -> Color {
        switch provider {
        case .openai: return .green
        case .anthropic: return .orange
        case .google: return .blue
        }
    }
    
    // MARK: - Local Providers Section
    private var localProvidersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Local Providers", subtitle: "Configure URLs for local LLM servers")
            
            VStack(spacing: 16) {
                // Ollama
                localProviderCard(
                    provider: .ollama,
                    url: $agentSettings.ollamaBaseURL,
                    status: ollamaStatus,
                    isTesting: isTestingOllama,
                    onTest: testOllama
                )
                
                Divider()
                
                // LM Studio
                localProviderCard(
                    provider: .lmStudio,
                    url: $agentSettings.lmStudioBaseURL,
                    status: lmStudioStatus,
                    isTesting: isTestingLMStudio,
                    onTest: testLMStudio
                )
                
                Divider()
                
                // vLLM
                localProviderCard(
                    provider: .vllm,
                    url: $agentSettings.vllmBaseURL,
                    status: vllmStatus,
                    isTesting: isTestingVLLM,
                    onTest: testVLLM
                )
            }
            .settingsCard()
        }
    }
    
    private func localProviderCard(
        provider: LocalLLMProvider,
        url: Binding<String>,
        status: ConnectionStatus,
        isTesting: Bool,
        onTest: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Provider badge
                ZStack {
                    Circle()
                        .fill(localProviderColor(for: provider))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: provider.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                    
                    Text("Default: \(provider.defaultBaseURL.absoluteString)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Connection status
                ConnectionStatusBadge(status: status)
            }
            
            // URL field
            HStack(spacing: 8) {
                TextField("API URL", text: url)
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
                    .onChange(of: url.wrappedValue) { _ in
                        agentSettings.save()
                    }
                
                // Test button
                Button(action: onTest) {
                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(0.1))
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(isTesting)
                .help("Test connection")
                
                // Reset to default
                if url.wrappedValue != provider.defaultBaseURL.absoluteString {
                    Button(action: {
                        url.wrappedValue = provider.defaultBaseURL.absoluteString
                        agentSettings.save()
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
                    .help("Reset to default URL")
                }
            }
            
            // Connection error
            if case .disconnected(let error) = status {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
            }
        }
    }
    
    private func localProviderColor(for provider: LocalLLMProvider) -> Color {
        switch provider {
        case .ollama: return .blue
        case .lmStudio: return .purple
        case .vllm: return .orange
        }
    }
    
    // MARK: - Connection Testing
    
    private func testOllama() {
        testLocalProvider(.ollama, status: $ollamaStatus, isTesting: $isTestingOllama)
    }
    
    private func testLMStudio() {
        testLocalProvider(.lmStudio, status: $lmStudioStatus, isTesting: $isTestingLMStudio)
    }
    
    private func testVLLM() {
        testLocalProvider(.vllm, status: $vllmStatus, isTesting: $isTestingVLLM)
    }
    
    private func testLocalProvider(_ provider: LocalLLMProvider, status: Binding<ConnectionStatus>, isTesting: Binding<Bool>) {
        isTesting.wrappedValue = true
        status.wrappedValue = .checking
        
        Task {
            defer {
                Task { @MainActor in
                    isTesting.wrappedValue = false
                }
            }
            
            do {
                let models = try await LocalProviderService.fetchModels(for: provider)
                await MainActor.run {
                    status.wrappedValue = .connected(modelCount: models.count)
                    // Update global availability so provider is no longer greyed out
                    LocalProviderAvailabilityManager.shared.setAvailable(true, for: provider)
                }
            } catch {
                await MainActor.run {
                    status.wrappedValue = .disconnected(error: error.localizedDescription)
                    // Update global availability to mark provider as unavailable
                    LocalProviderAvailabilityManager.shared.setAvailable(false, for: provider)
                }
            }
        }
    }
}
