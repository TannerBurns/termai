import SwiftUI

struct SettingsRootView: View {
    var selectedSession: ChatSession?
    @ObservedObject var ptyModel: PTYModel
    @State private var selectedTab: SettingsTab = .chatModel
    
    enum SettingsTab: String, CaseIterable {
        case chatModel = "Chat & Model"
        case agent = "Agent"
        case terminal = "Terminal Theme"
        case usage = "Usage"
        
        var icon: String {
            switch self {
            case .chatModel: return "message.fill"
            case .agent: return "cpu"
            case .terminal: return "terminal.fill"
            case .usage: return "chart.bar.fill"
            }
        }
    }

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsTabButton(
                        title: tab.rawValue,
                        icon: tab.icon,
                        isSelected: selectedTab == tab
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    }
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 180)
            .background(Color.primary.opacity(0.02))
            
            // Content
            Group {
                switch selectedTab {
                case .chatModel:
                    if let session = selectedSession {
                        SessionSettingsView(session: session)
                    } else {
                        NoSessionPlaceholder()
                    }
                case .agent:
                    AgentSettingsView()
                case .terminal:
                    TerminalThemeSettingsView(ptyModel: ptyModel)
                case .usage:
                    UsageSettingsView()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

// MARK: - Settings Tab Button
struct SettingsTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                
                Spacer()
            }
            .foregroundColor(isSelected ? .accentColor : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - No Session Placeholder
struct NoSessionPlaceholder: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No Chat Session")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.secondary)
            
            Text("Create or select a chat session to configure its model settings.")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Terminal Theme Settings View
struct TerminalThemeSettingsView: View {
    @ObservedObject var ptyModel: PTYModel
    @Environment(\.colorScheme) var colorScheme
    
    private var selectedTheme: TerminalTheme {
        TerminalTheme.presets.first(where: { $0.id == ptyModel.themeId }) ?? TerminalTheme.presets.first ?? TerminalTheme.system()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Theme Selection Grid
                themeSelectionSection
                
                // Live Preview
                livePreviewSection
                
                // Color Palette Details
                colorPaletteSection
            }
            .padding(24)
        }
        .frame(minWidth: 500)
    }
    
    // MARK: - Theme Selection Grid
    private var themeSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Theme", subtitle: "Choose a color scheme for your terminal")
            
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                ForEach(TerminalTheme.presets) { theme in
                    ThemeCard(
                        theme: theme,
                        isSelected: theme.id == ptyModel.themeId
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            ptyModel.themeId = theme.id
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Live Preview Section
    private var livePreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Preview", subtitle: "How your terminal will look")
            
            VStack(alignment: .leading, spacing: 0) {
                // Terminal Title Bar
                HStack(spacing: 8) {
                    Circle().fill(Color.red.opacity(0.8)).frame(width: 12, height: 12)
                    Circle().fill(Color.yellow.opacity(0.8)).frame(width: 12, height: 12)
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 12, height: 12)
                    Spacer()
                    Text("Terminal Preview")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.3))
                
                // Terminal Content
                VStack(alignment: .leading, spacing: 4) {
                    terminalLine(prompt: "~/projects", command: "ls -la")
                    terminalOutputLine("drwxr-xr-x  5 user  staff   160 Nov 28 10:23 ", highlight: "src", highlightColor: ansiColor(4)) // Blue for directories
                    terminalOutputLine("drwxr-xr-x  3 user  staff    96 Nov 28 10:23 ", highlight: "docs", highlightColor: ansiColor(4))
                    terminalOutputLine("-rw-r--r--  1 user  staff  1234 Nov 28 10:23 ", highlight: "README.md", highlightColor: .white)
                    terminalOutputLine("-rwxr-xr-x  1 user  staff   567 Nov 28 10:23 ", highlight: "run.sh", highlightColor: ansiColor(2)) // Green for executables
                    
                    Spacer().frame(height: 8)
                    
                    terminalLine(prompt: "~/projects", command: "git status")
                    HStack(spacing: 0) {
                        Text("On branch ")
                            .foregroundColor(Color(selectedTheme.foreground))
                        Text("main")
                            .foregroundColor(ansiColor(2)) // Green
                    }
                    .font(.system(size: 12, design: .monospaced))
                    
                    HStack(spacing: 0) {
                        Text("Changes not staged: ")
                            .foregroundColor(Color(selectedTheme.foreground))
                        Text("modified: src/app.swift")
                            .foregroundColor(ansiColor(1)) // Red
                    }
                    .font(.system(size: 12, design: .monospaced))
                    
                    Spacer().frame(height: 8)
                    
                    terminalLine(prompt: "~/projects", command: "")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(selectedTheme.background))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
    }
    
    private func terminalLine(prompt: String, command: String) -> some View {
        HStack(spacing: 0) {
            Text(prompt)
                .foregroundColor(ansiColor(6)) // Cyan
            Text(" $ ")
                .foregroundColor(Color(selectedTheme.foreground).opacity(0.6))
            Text(command)
                .foregroundColor(Color(selectedTheme.foreground))
            if command.isEmpty {
                Rectangle()
                    .fill(Color(selectedTheme.caret ?? selectedTheme.foreground))
                    .frame(width: 8, height: 14)
                    .opacity(0.8)
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }
    
    private func terminalOutputLine(_ prefix: String, highlight: String, highlightColor: Color) -> some View {
        HStack(spacing: 0) {
            Text(prefix)
                .foregroundColor(Color(selectedTheme.foreground).opacity(0.7))
            Text(highlight)
                .foregroundColor(highlightColor)
        }
        .font(.system(size: 12, design: .monospaced))
    }
    
    private func ansiColor(_ index: Int) -> Color {
        guard let palette = selectedTheme.ansi16Palette, index < palette.count else {
            // Fallback colors if no palette
            let fallback: [Color] = [.black, .red, .green, .yellow, .blue, .purple, .cyan, .white]
            return index < fallback.count ? fallback[index] : .white
        }
        let c = palette[index]
        return Color(
            red: Double(c.red) / 65535.0,
            green: Double(c.green) / 65535.0,
            blue: Double(c.blue) / 65535.0
        )
    }
    
    // MARK: - Color Palette Section
    private var colorPaletteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("Color Palette", subtitle: "Standard ANSI colors used by the terminal")
            
            VStack(spacing: 16) {
                // Primary Colors Row
                HStack(spacing: 8) {
                    // Background & Foreground
                    ColorSwatch(
                        color: Color(selectedTheme.background),
                        label: "Background",
                        isLarge: true
                    )
                    ColorSwatch(
                        color: Color(selectedTheme.foreground),
                        label: "Foreground",
                        isLarge: true
                    )
                    ColorSwatch(
                        color: Color(selectedTheme.selectionBackground),
                        label: "Selection",
                        isLarge: true
                    )
                }
                
                Divider()
                
                // Normal Colors (0-7)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Normal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 6) {
                        ForEach(0..<8, id: \.self) { index in
                            ColorSwatch(
                                color: ansiColor(index),
                                label: ansiColorName(index),
                                isLarge: false
                            )
                        }
                    }
                }
                
                // Bright Colors (8-15)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bright")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 6) {
                        ForEach(8..<16, id: \.self) { index in
                            ColorSwatch(
                                color: ansiColor(index),
                                label: ansiColorName(index),
                                isLarge: false
                            )
                        }
                    }
                }
            }
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
    
    private func ansiColorName(_ index: Int) -> String {
        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
                     "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        return index < names.count ? names[index] : "\(index)"
    }
}

// MARK: - Theme Card
struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Mini Terminal Preview
                VStack(alignment: .leading, spacing: 2) {
                    miniTerminalLine("$ ls", color: Color(theme.foreground))
                    miniTerminalLine("src/  docs/", color: previewColor(4)) // Blue-ish
                    miniTerminalLine("$ git status", color: Color(theme.foreground))
                    miniTerminalLine("✓ clean", color: previewColor(2)) // Green-ish
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(theme.background))
                
                // Theme Name
                HStack {
                    Text(theme.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func previewColor(_ index: Int) -> Color {
        guard let palette = theme.ansi16Palette, index < palette.count else {
            let fallback: [Color] = [.black, .red, .green, .yellow, .blue, .purple, .cyan, .white]
            return index < fallback.count ? fallback[index] : Color(theme.foreground)
        }
        let c = palette[index]
        return Color(
            red: Double(c.red) / 65535.0,
            green: Double(c.green) / 65535.0,
            blue: Double(c.blue) / 65535.0
        )
    }
    
    private func miniTerminalLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(color)
    }
}

// MARK: - Color Swatch
struct ColorSwatch: View {
    let color: Color
    let label: String
    let isLarge: Bool
    
    @State private var isHovering = false
    
    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: isLarge ? 8 : 6)
                .fill(color)
                .frame(width: isLarge ? 60 : 36, height: isLarge ? 36 : 24)
                .overlay(
                    RoundedRectangle(cornerRadius: isLarge ? 8 : 6)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: color.opacity(0.3), radius: isHovering ? 4 : 0)
                .scaleEffect(isHovering ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)
            
            if isLarge || isHovering {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: isLarge ? 60 : 36)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Agent Settings View
struct AgentSettingsView: View {
    @ObservedObject private var settings = AgentSettings.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var showResetConfirmation = false
    
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
                
                // Advanced Section
                advancedSection
                
                // Reset Button
                resetSection
            }
            .padding(24)
        }
        .frame(minWidth: 500)
        .onChange(of: settings.agentModeEnabledByDefault) { _ in settings.save() }
        .onChange(of: settings.maxIterations) { _ in settings.save() }
        .onChange(of: settings.maxFixAttempts) { _ in settings.save() }
        .onChange(of: settings.commandTimeout) { _ in settings.save() }
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
        .onChange(of: settings.verboseLogging) { _ in settings.save() }
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
                // Agent Mode Enabled by Default
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Agent Mode by Default")
                            .font(.system(size: 13, weight: .medium))
                        Text("New chat sessions will start with agent mode enabled.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.agentModeEnabledByDefault)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
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
                        Text("\(Int(settings.commandTimeout))s")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $settings.commandTimeout, in: 5...120, step: 5)
                    
                    Text("How long to wait for command output before timing out.")
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
            SettingsSectionHeader("Context & Memory", subtitle: "Control how much context the agent retains")
            
            VStack(spacing: 16) {
                // Max Output Capture
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Output Capture Limit")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(settings.maxOutputCapture) chars")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxOutputCapture) },
                        set: { settings.maxOutputCapture = Int($0) }
                    ), in: 500...10000, step: 500)
                    
                    Text("Maximum characters to capture from each command's output.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Max Context Size
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Context Window Size")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(settings.maxContextSize) chars")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxContextSize) },
                        set: { settings.maxContextSize = Int($0) }
                    ), in: 2000...32000, step: 1000)
                    
                    Text("Maximum size of the agent's working memory across iterations.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .settingsCard()
        }
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
            }
            .settingsCard()
            .animation(.easeInOut(duration: 0.2), value: settings.requireCommandApproval)
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
