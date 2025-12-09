import SwiftUI
// MARK: - Agent Settings View
struct AgentSettingsView: View {
    @ObservedObject private var settings = AgentSettings.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var showResetConfirmation = false
    @State private var newBlockedPattern: String = ""
    @State private var isBlockedCommandsExpanded: Bool = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Default Behavior Section
                defaultBehaviorSection
                
                // Execution Limits Section
                executionLimitsSection
                
                // Planning & Reflection Section
                planningReflectionSection
                
                // Context & Memory Section
                contextMemorySection
                
                // Output Handling Section
                outputHandlingSection
                
                // Safety Section
                safetySection
                
                // Test Runner Section
                testRunnerSection
                
                // Advanced Section
                advancedSection
                
                // Reset Button
                resetSection
            }
            .padding(24)
        }
        .frame(minWidth: 500)
        .onChange(of: settings.defaultAgentMode) { _ in settings.save() }
        .onChange(of: settings.defaultAgentProfile) { _ in settings.save() }
        .onChange(of: settings.maxIterations) { _ in settings.save() }
        .onChange(of: settings.maxToolCallsPerStep) { _ in settings.save() }
        .onChange(of: settings.maxFixAttempts) { _ in settings.save() }
        .onChange(of: settings.commandTimeout) { _ in settings.save() }
        // Dynamic context settings
        .onChange(of: settings.outputCapturePercent) { _ in settings.save() }
        .onChange(of: settings.agentMemoryPercent) { _ in settings.save() }
        .onChange(of: settings.maxOutputCaptureCap) { _ in settings.save() }
        .onChange(of: settings.maxAgentMemoryCap) { _ in settings.save() }
        .onChange(of: settings.minOutputCapture) { _ in settings.save() }
        .onChange(of: settings.minContextSize) { _ in settings.save() }
        // Legacy (kept for compatibility)
        .onChange(of: settings.maxOutputCapture) { _ in settings.save() }
        .onChange(of: settings.maxContextSize) { _ in settings.save() }
        .onChange(of: settings.outputSummarizationThreshold) { _ in settings.save() }
        .onChange(of: settings.enableOutputSummarization) { _ in settings.save() }
        .onChange(of: settings.maxFullOutputBuffer) { _ in settings.save() }
        .onChange(of: settings.enablePlanning) { _ in settings.save() }
        .onChange(of: settings.reflectionInterval) { _ in settings.save() }
        .onChange(of: settings.enableReflection) { _ in settings.save() }
        .onChange(of: settings.stuckDetectionThreshold) { _ in settings.save() }
        .onChange(of: settings.requireCommandApproval) { _ in settings.save() }
        .onChange(of: settings.autoApproveReadOnly) { _ in settings.save() }
        .onChange(of: settings.requireFileEditApproval) { _ in settings.save() }
        .onChange(of: settings.enableApprovalNotifications) { newValue in
            settings.save()
            // Request notification permissions when enabling
            if newValue {
                SystemNotificationService.shared.requestAuthorization()
            }
        }
        .onChange(of: settings.enableApprovalNotificationSound) { _ in settings.save() }
        .onChange(of: settings.verboseLogging) { _ in settings.save() }
        .onChange(of: settings.testRunnerEnabled) { _ in settings.save() }
        .alert("Reset Agent Settings", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
            }
        } message: {
            Text("Are you sure you want to reset all agent settings to their default values?")
        }
    }
    
    // MARK: - Default Behavior Section
    private var defaultBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Default Behavior", subtitle: "Control how new chat sessions behave")
            
            VStack(spacing: 16) {
                // Default Agent Mode
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default Agent Mode")
                            .font(.system(size: 13, weight: .medium))
                        Text("The agent mode that new chat sessions will start with.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Picker("", selection: $settings.defaultAgentMode) {
                        ForEach(AgentMode.allCases, id: \.self) { mode in
                            HStack(spacing: 6) {
                                Image(systemName: mode.icon)
                                    .foregroundColor(mode.color)
                                Text(mode.rawValue)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
                
                // Mode descriptions
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AgentMode.allCases, id: \.self) { mode in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 11))
                                .foregroundColor(mode.color)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                                Text(mode.detailedDescription)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 8)
                
                Divider()
                
                // Default Agent Profile
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default Agent Profile")
                            .font(.system(size: 13, weight: .medium))
                        Text("The task profile that new chat sessions will start with.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Picker("", selection: $settings.defaultAgentProfile) {
                        ForEach(AgentProfile.allCases, id: \.self) { profile in
                            HStack(spacing: 6) {
                                Image(systemName: profile.icon)
                                    .foregroundColor(profile.color)
                                Text(profile.rawValue)
                            }
                            .tag(profile)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
                
                // Profile descriptions
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AgentProfile.allCases, id: \.self) { profile in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: profile.icon)
                                .font(.system(size: 11))
                                .foregroundColor(profile.color)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                                Text(profile.detailedDescription)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
            .settingsCard()
        }
    }
    
    // MARK: - Execution Limits Section
    private var executionLimitsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Execution Limits", subtitle: "Control how the agent executes commands")
            
            VStack(spacing: 16) {
                // Max Iterations
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Maximum Steps")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        TextField("", value: Binding(
                            get: { settings.maxIterations },
                            set: { settings.maxIterations = max(0, min(500, $0)) }
                        ), format: .number)
                        .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                        .frame(width: 60)
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
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxIterations) },
                        set: { settings.maxIterations = Int($0) }
                    ), in: 0...500, step: 10)
                    
                    Text("Maximum number of steps (0 = unlimited). Recommended: 50-200 for complex tasks.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Max Tool Calls Per Step
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tool Calls Per Step")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        TextField("", value: Binding(
                            get: { settings.maxToolCallsPerStep },
                            set: { settings.maxToolCallsPerStep = max(10, min(500, $0)) }
                        ), format: .number)
                        .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                        .frame(width: 60)
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
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxToolCallsPerStep) },
                        set: { settings.maxToolCallsPerStep = Int($0) }
                    ), in: 10...500, step: 10)
                    
                    Text("Maximum tool calls within a single step. Increase for complex multi-tool operations.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Max Fix Attempts
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Maximum Fix Attempts")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(settings.maxFixAttempts)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxFixAttempts) },
                        set: { settings.maxFixAttempts = Int($0) }
                    ), in: 1...10, step: 1)
                    
                    Text("How many times the agent will try to fix a failed command.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Command Timeout
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Command Timeout")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(formatTimeout(settings.commandTimeout))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $settings.commandTimeout, in: 30...3600, step: 30)
                    
                    Text("Default wait time for command output. Agent can override per-command for long tasks. Recommended: 5-10 minutes.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .settingsCard()
        }
    }
    
    // MARK: - Planning & Reflection Section
    private var planningReflectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Planning & Reflection", subtitle: "Control how the agent plans and reviews progress")
            
            VStack(spacing: 16) {
                // Enable Planning
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Planning Phase")
                            .font(.system(size: 13, weight: .medium))
                        Text("Generate a step-by-step plan before executing commands.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.enablePlanning)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                Divider()
                
                // Enable Reflection
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Periodic Reflection")
                            .font(.system(size: 13, weight: .medium))
                        Text("Pause to assess progress and adjust approach if needed.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.enableReflection)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                if settings.enableReflection {
                    // Reflection Interval
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Reflection Interval")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("Every \(settings.reflectionInterval) steps")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: Binding(
                            get: { Double(settings.reflectionInterval) },
                            set: { settings.reflectionInterval = Int($0) }
                        ), in: 3...25, step: 1)
                        
                        Text("How often the agent pauses to review progress.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                // Stuck Detection
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Stuck Detection Threshold")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(settings.stuckDetectionThreshold) similar commands")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.stuckDetectionThreshold) },
                        set: { settings.stuckDetectionThreshold = Int($0) }
                    ), in: 2...10, step: 1)
                    
                    Text("Trigger a strategy change after this many similar failed commands.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .settingsCard()
            .animation(.easeInOut(duration: 0.2), value: settings.enableReflection)
        }
    }
    
    // MARK: - Context & Memory Section
    private var contextMemorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Context Budget", subtitle: "Dynamic allocation based on model's context window")
            
            VStack(spacing: 16) {
                // Info about dynamic scaling
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("Context limits scale automatically with your model's capabilities. A 128K model gets much more context than a 4K model.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
                
                Divider()
                
                // Per-Output Capture Percent
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Per-Output Capture")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(Int(settings.outputCapturePercent * 100))% of context")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $settings.outputCapturePercent, in: 0.05...0.30, step: 0.01)
                    
                    HStack {
                        Text("How much of the model's context each file read or command output can use.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Min: \(formatChars(settings.minOutputCapture))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                
                Divider()
                
                // Agent Memory Percent
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Agent Working Memory")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(Int(settings.agentMemoryPercent * 100))% of context")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $settings.agentMemoryPercent, in: 0.20...0.60, step: 0.05)
                    
                    HStack {
                        Text("Total context budget for the agent's accumulated memory during long tasks.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Min: \(formatChars(settings.minContextSize))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                
                Divider()
                
                // Example allocation display
                contextBudgetExample
            }
            .settingsCard()
            
            // Advanced limits (collapsed by default)
            DisclosureGroup("Advanced Limits") {
                VStack(spacing: 12) {
                    // Hard caps
                    HStack {
                        Text("Output Capture Cap")
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(formatChars(settings.maxOutputCaptureCap))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxOutputCaptureCap) },
                        set: { settings.maxOutputCaptureCap = Int($0) }
                    ), in: 20000...100000, step: 5000)
                    
                    Divider()
                    
                    HStack {
                        Text("Agent Memory Cap")
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(formatChars(settings.maxAgentMemoryCap))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxAgentMemoryCap) },
                        set: { settings.maxAgentMemoryCap = Int($0) }
                    ), in: 50000...200000, step: 10000)
                    
                    Text("Hard limits prevent excessive memory use even with very large context models.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.top, 8)
            }
            .settingsCard()
        }
    }
    
    // MARK: - Context Budget Example
    private var contextBudgetExample: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Example Allocations")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            
            HStack(spacing: 16) {
                contextExampleColumn(modelName: "32K Model", tokens: 32_000)
                Divider().frame(height: 50)
                contextExampleColumn(modelName: "128K Model", tokens: 128_000)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(6)
        }
    }
    
    private func contextExampleColumn(modelName: String, tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(modelName)
                .font(.system(size: 11, weight: .semibold))
            
            let outputLimit = settings.effectiveOutputCaptureLimit(forContextTokens: tokens)
            let memoryLimit = settings.effectiveAgentMemoryLimit(forContextTokens: tokens)
            
            Text("Per-output: \(formatChars(outputLimit))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            
            Text("Memory: \(formatChars(memoryLimit))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func formatChars(_ chars: Int) -> String {
        if chars >= 1000 {
            return "\(chars / 1000)K"
        }
        return "\(chars)"
    }
    
    private func formatTimeout(_ seconds: TimeInterval) -> String {
        let secs = Int(seconds)
        if secs >= 3600 {
            let hours = secs / 3600
            let mins = (secs % 3600) / 60
            if mins > 0 {
                return "\(hours)h \(mins)m"
            }
            return "\(hours)h"
        } else if secs >= 60 {
            let mins = secs / 60
            let remainingSecs = secs % 60
            if remainingSecs > 0 {
                return "\(mins)m \(remainingSecs)s"
            }
            return "\(mins)m"
        }
        return "\(secs)s"
    }
    
    // MARK: - Output Handling Section
    private var outputHandlingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Long Output Handling", subtitle: "Control how large terminal outputs are processed")
            
            VStack(spacing: 16) {
                // Enable Output Summarization
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Output Summarization")
                            .font(.system(size: 13, weight: .medium))
                        Text("Automatically summarize long command outputs to preserve context.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.enableOutputSummarization)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                if settings.enableOutputSummarization {
                    Divider()
                    
                    // Summarization Threshold
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Summarization Threshold")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(settings.outputSummarizationThreshold) chars")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: Binding(
                            get: { Double(settings.outputSummarizationThreshold) },
                            set: { settings.outputSummarizationThreshold = Int($0) }
                        ), in: 1000...20000, step: 1000)
                        
                        Text("Outputs longer than this will be summarized to preserve key information.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                // Full Output Buffer
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Full Output Buffer")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(settings.maxFullOutputBuffer / 1000)K chars")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxFullOutputBuffer) },
                        set: { settings.maxFullOutputBuffer = Int($0) }
                    ), in: 10000...100000, step: 10000)
                    
                    Text("Full outputs are stored up to this size for search and reference.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .settingsCard()
            .animation(.easeInOut(duration: 0.2), value: settings.enableOutputSummarization)
        }
    }
    
    // MARK: - Safety Section
    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Safety", subtitle: "Control command execution approval")
            
            VStack(spacing: 16) {
                // Require Command Approval
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Require Command Approval")
                            .font(.system(size: 13, weight: .medium))
                        Text("Ask for confirmation before executing each command.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.requireCommandApproval)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                if settings.requireCommandApproval {
                    Divider()
                    
                    // Auto-approve Read-Only
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto-Approve Read-Only Commands")
                                .font(.system(size: 13, weight: .medium))
                            Text("Automatically approve safe commands like ls, cat, git status, etc.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: $settings.autoApproveReadOnly)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                
                Divider()
                
                // Require File Edit Approval
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Require File Edit Approval")
                            .font(.system(size: 13, weight: .medium))
                        Text("Show a diff preview and ask for confirmation before modifying files.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.requireFileEditApproval)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                Divider()
                
                // System Notifications
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System Notifications")
                            .font(.system(size: 13, weight: .medium))
                        Text("Show macOS notifications when approvals are needed while you're away.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.enableApprovalNotifications)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                if settings.enableApprovalNotifications {
                    // Notification Sound
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Text("Notification Sound")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            Text("Play a sound when approval notifications appear.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: $settings.enableApprovalNotificationSound)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(.leading, 16)
                }
            }
            .settingsCard()
            .animation(.easeInOut(duration: 0.2), value: settings.requireCommandApproval)
            .animation(.easeInOut(duration: 0.2), value: settings.enableApprovalNotifications)
            
            // Command Blocklist Section
            commandBlocklistSection
        }
    }
    
    // MARK: - Command Blocklist Section
    private var commandBlocklistSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Blocked Commands", subtitle: "Commands that always require approval, regardless of other settings")
            
            VStack(spacing: 16) {
                // Info callout
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    
                    Text("These command patterns will always require your approval before execution. This helps prevent accidental data loss or system changes.")
                        .font(.system(size: 12))
                        .foregroundColor(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
                
                // Add new pattern
                HStack(spacing: 8) {
                    TextField("Add command pattern (e.g., npm publish)", text: $newBlockedPattern)
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
                        .onSubmit {
                            addNewBlockedPattern()
                        }
                    
                    Button(action: addNewBlockedPattern) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(newBlockedPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                Divider()
                
                // Collapsible blocked patterns list
                VStack(spacing: 0) {
                    // Header button to expand/collapse
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isBlockedCommandsExpanded.toggle()
                        }
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: isBlockedCommandsExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 12)
                            
                            Text("Blocked Patterns")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            
                            // Count badge
                            Text("\(settings.blockedCommandPatterns.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.orange)
                                )
                            
                            Spacer()
                            
                            Text(isBlockedCommandsExpanded ? "Hide" : "Show")
                                .font(.system(size: 11))
                                .foregroundColor(.accentColor)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    
                    // Expandable list
                    if isBlockedCommandsExpanded {
                        if settings.blockedCommandPatterns.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "checkmark.shield")
                                        .font(.system(size: 24))
                                        .foregroundColor(.secondary.opacity(0.5))
                                    Text("No blocked commands")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 20)
                                Spacer()
                            }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(settings.blockedCommandPatterns.enumerated()), id: \.offset) { index, pattern in
                                    HStack(spacing: 12) {
                                        Image(systemName: "xmark.octagon.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(.red.opacity(0.7))
                                        
                                        Text(pattern)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(.primary)
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            settings.removeBlockedPattern(pattern)
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove this pattern")
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        index % 2 == 0 
                                            ? Color.clear 
                                            : Color.primary.opacity(0.02)
                                    )
                                    
                                    if index < settings.blockedCommandPatterns.count - 1 {
                                        Divider()
                                            .padding(.leading, 36)
                                    }
                                }
                            }
                            .padding(.top, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.02))
                            )
                        }
                        
                        // Reset to defaults button (inside expanded area)
                        HStack {
                            Spacer()
                            
                            Button(action: {
                                settings.resetBlockedPatternsToDefaults()
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 11))
                                    Text("Reset to Defaults")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Restore the default blocked command patterns")
                        }
                        .padding(.top, 12)
                    }
                }
            }
            .settingsCard()
            .animation(.easeInOut(duration: 0.2), value: isBlockedCommandsExpanded)
        }
    }
    
    private func addNewBlockedPattern() {
        let trimmed = newBlockedPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.addBlockedPattern(trimmed)
        newBlockedPattern = ""
    }
    
    // MARK: - Test Runner Section
    private var testRunnerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Test Runner", subtitle: "Automated test detection and execution")
            
            VStack(spacing: 16) {
                // Enable Test Runner
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Test Runner")
                            .font(.system(size: 13, weight: .medium))
                        Text("Show the Test Runner button in the chat toolbar to analyze and run project tests.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.testRunnerEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            .settingsCard()
        }
    }
    
    // MARK: - Advanced Section
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader("Advanced", subtitle: "Developer and debugging options")
            
            VStack(spacing: 16) {
                // Verbose Logging
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Verbose Logging")
                            .font(.system(size: 13, weight: .medium))
                        Text("Log detailed agent operations to the console (for debugging).")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.verboseLogging)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            .settingsCard()
        }
    }
    
    // MARK: - Reset Section
    private var resetSection: some View {
        HStack {
            Spacer()
            
            Button(action: { showResetConfirmation = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12))
                    Text("Reset to Defaults")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
