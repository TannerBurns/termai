import SwiftUI
import TermAIModels

// MARK: - Progress Donut Chart

struct ProgressDonut: View {
    let completed: Int
    let total: Int
    let size: CGFloat
    let lineWidth: CGFloat
    
    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(Double(completed) / Double(total), 1.0)
    }
    
    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(
                    Color.secondary.opacity(0.2),
                    lineWidth: lineWidth
                )
            
            // Progress arc
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color.blue.opacity(0.7),
                            Color.blue,
                            Color.cyan.opacity(0.9)
                        ]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * progress)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Agent Mode Selector

struct AgentModeSelector: View {
    @Binding var mode: AgentMode
    @State private var isHovering: Bool = false
    
    var body: some View {
        Menu {
            ForEach(AgentMode.allCases, id: \.self) { agentMode in
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        mode = agentMode
                    }
                }) {
                    HStack {
                        Image(systemName: agentMode.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agentMode.rawValue)
                            Text(agentMode.description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if mode == agentMode {
                            Image(systemName: "checkmark")
                                .foregroundColor(agentMode.color)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                // Mode icon with glow
                ZStack {
                    // Subtle glow effect
                    Circle()
                        .fill(mode.color.opacity(0.25))
                        .frame(width: 14, height: 14)
                        .blur(radius: 2)
                    
                    // Icon background
                    Circle()
                        .fill(mode.color)
                        .frame(width: 12, height: 12)
                    
                    // Icon
                    Image(systemName: mode.icon)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 14, height: 14)
                
                // Mode label
                Text(mode.rawValue)
                    .font(.caption)
                    .foregroundColor(mode.color)
                
                // Dropdown chevron
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(mode.color.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(mode.color.opacity(isHovering ? 0.2 : 0.15))
            )
            .overlay(
                Capsule()
                    .stroke(mode.color.opacity(isHovering ? 0.5 : 0.3), lineWidth: 1)
            )
            .shadow(
                color: mode.color.opacity(0.2),
                radius: isHovering ? 4 : 2,
                x: 0, y: 0
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(mode.detailedDescription)
    }
}

// MARK: - Agent Profile Selector

struct AgentProfileSelector: View {
    @Binding var profile: AgentProfile
    /// The active profile when in Auto mode (shows what profile is currently being used)
    var activeProfile: AgentProfile? = nil
    @State private var isHovering: Bool = false
    
    /// The display profile (active profile when in Auto mode, otherwise the selected profile)
    private var displayProfile: AgentProfile {
        if profile.isAuto, let active = activeProfile {
            return active
        }
        return profile
    }
    
    /// Whether we're in Auto mode with a different active profile
    private var isAutoWithActiveProfile: Bool {
        profile.isAuto && activeProfile != nil && activeProfile != .auto
    }
    
    var body: some View {
        Menu {
            ForEach(AgentProfile.allCases, id: \.self) { agentProfile in
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        profile = agentProfile
                    }
                }) {
                    HStack {
                        Image(systemName: agentProfile.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agentProfile.rawValue)
                            Text(agentProfile.description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if profile == agentProfile {
                            Image(systemName: "checkmark")
                                .foregroundColor(agentProfile.color)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                // Profile icon with subtle background
                ZStack {
                    // Subtle glow effect
                    Circle()
                        .fill(displayProfile.color.opacity(0.25))
                        .frame(width: 14, height: 14)
                        .blur(radius: 2)
                    
                    // Icon background
                    Circle()
                        .fill(displayProfile.color)
                        .frame(width: 12, height: 12)
                    
                    // Icon
                    Image(systemName: displayProfile.icon)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.white)
                    
                    // Small "auto" indicator when in Auto mode
                    if isAutoWithActiveProfile {
                        Circle()
                            .fill(AgentProfile.auto.color)
                            .frame(width: 5, height: 5)
                            .offset(x: 5, y: -5)
                    }
                }
                .frame(width: 14, height: 14)
                
                // Profile label - show "Auto (Coding)" style when in Auto mode
                if isAutoWithActiveProfile, let active = activeProfile {
                    Text("Auto")
                        .font(.caption)
                        .foregroundColor(profile.color)
                    Text("(\(active.rawValue))")
                        .font(.caption2)
                        .foregroundColor(active.color)
                } else {
                    Text(profile.rawValue)
                        .font(.caption)
                        .foregroundColor(profile.color)
                }
                
                // Dropdown chevron
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(displayProfile.color.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(displayProfile.color.opacity(isHovering ? 0.2 : 0.15))
            )
            .overlay(
                Capsule()
                    .stroke(displayProfile.color.opacity(isHovering ? 0.5 : 0.3), lineWidth: 1)
            )
            .shadow(
                color: displayProfile.color.opacity(0.2),
                radius: isHovering ? 4 : 2,
                x: 0, y: 0
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(isAutoWithActiveProfile ? "Auto mode - currently using \(activeProfile?.rawValue ?? "General") profile" : profile.detailedDescription)
    }
}

// MARK: - Agent Summary Badge (Compact action summary during run)

struct AgentSummaryBadge: View {
    @ObservedObject var session: ChatSession
    
    /// Count of tool events (excluding internal events and commands)
    private var toolEventCount: Int {
        session.messages.filter { msg in
            guard let event = msg.agentEvent else { return false }
            return (event.eventCategory == "tool" || (event.toolCallId != nil && event.eventCategory != "command")) && event.isInternal != true
        }.count
    }
    
    /// Count of command events (shell commands)
    private var commandEventCount: Int {
        session.messages.filter { msg in
            msg.agentEvent?.eventCategory == "command"
        }.count
    }
    
    /// Count of file changes
    private var fileChangeCount: Int {
        session.messages.filter { msg in
            msg.agentEvent?.fileChange != nil
        }.count
    }
    
    /// Count of profile changes
    private var profileChangeCount: Int {
        session.messages.filter { msg in
            msg.agentEvent?.eventCategory == "profile"
        }.count
    }
    
    var body: some View {
        if toolEventCount > 0 || fileChangeCount > 0 || profileChangeCount > 0 || commandEventCount > 0 {
            HStack(spacing: 4) {
                if toolEventCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "wrench")
                            .font(.system(size: 8))
                        Text("\(toolEventCount)")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                }
                
                if commandEventCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "terminal")
                            .font(.system(size: 8))
                        Text("\(commandEventCount)")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundColor(.cyan)
                }
                
                if fileChangeCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 8))
                        Text("\(fileChangeCount)")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundColor(.orange)
                }
                
                if profileChangeCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 8))
                        Text("\(profileChangeCount)")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundColor(.purple)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }
}

// MARK: - Agent Controls Bar (Per-Chat)

struct AgentControlsBar: View {
    @ObservedObject var session: ChatSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingChecklistPopover: Bool = false
    @State private var isHoveringProgress: Bool = false
    
    var body: some View {
        HStack(spacing: 8) {
            if session.isAgentRunning {
                // Show progress and stop button when agent is running
                HStack(spacing: 8) {
                    // Progress indicator - shows checklist progress when available, otherwise simple generating state
                    if let checklist = session.agentChecklist {
                        // Has checklist - show progress with clickable popover
                        Button(action: { showingChecklistPopover.toggle() }) {
                            HStack(spacing: 6) {
                                let completedSteps = checklist.completedCount
                                let totalSteps = checklist.items.count
                                
                                ProgressDonut(
                                    completed: completedSteps,
                                    total: totalSteps,
                                    size: 14,
                                    lineWidth: 2.5
                                )
                                
                                Text("\(completedSteps)/\(totalSteps)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                                
                                if !session.agentPhase.isEmpty {
                                    Text("·")
                                        .foregroundColor(.secondary.opacity(0.5))
                                    Text(session.agentPhase)
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                }
                                
                                // Chevron indicator for popover
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(isHoveringProgress ? Color.blue.opacity(0.18) : Color.blue.opacity(0.1))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isHoveringProgress ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringProgress = $0 }
                        .help("Click to view task checklist")
                        .popover(isPresented: $showingChecklistPopover, arrowEdge: .bottom) {
                            AgentChecklistPopover(
                                checklist: session.agentChecklist,
                                currentStep: session.agentCurrentStep,
                                estimatedSteps: session.agentEstimatedSteps,
                                phase: session.agentPhase
                            )
                        }
                    } else {
                        // No checklist yet - show simple generating state
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                            
                            Text("Generating")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.1))
                        )
                    }
                    
                    // Compact summary badge
                    AgentSummaryBadge(session: session)
                    
                    // Stop button
                    Button(action: { session.cancelAgent() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8))
                            Text("Stop")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.red.opacity(0.15))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                        )
                        .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop agent execution")
                }
            } else {
                // Show agent mode selector when not running
                AgentModeSelector(
                    mode: Binding(
                        get: { session.agentMode },
                        set: { session.agentMode = $0; session.persistSettings() }
                    )
                )
                
                // Show agent profile selector
                AgentProfileSelector(
                    profile: Binding(
                        get: { session.agentProfile },
                        set: { session.agentProfile = $0; session.persistSettings() }
                    ),
                    activeProfile: session.agentProfile.isAuto ? session.activeProfile : nil
                )
            }
            
            Spacer()
            
            // Context usage indicator (per-chat) - always visible
            ContextUsageIndicator(session: session)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(colorScheme == .dark
            ? Color(red: 0.16, green: 0.17, blue: 0.20)  // #282c34
            : Color(red: 0.98, green: 0.98, blue: 0.98)) // #fafafa
    }
}
