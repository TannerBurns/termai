import SwiftUI
import AppKit
import TermAIModels

// MARK: - Agent Event View

struct AgentEventView: View {
    @State private var expanded: Bool = false
    @State private var showCopied: Bool = false
    @State private var showingDiffSheet: Bool = false
    @State private var approvalHandled: Bool = false
    let event: AgentEvent
    let ptyModel: PTYModel
    
    /// Check if this event has a pending approval that hasn't been handled
    private var hasPendingApproval: Bool {
        event.pendingApprovalId != nil && !approvalHandled
    }
    
    /// Check if this is a tool event with status
    private var isToolEvent: Bool {
        event.toolCallId != nil
    }
    
    /// Get the effective color based on tool status
    private var effectiveColor: Color {
        // Handle "thinking" kind
        if event.kind == "thinking" {
            return .purple
        }
        if let status = event.toolStatus {
            switch status {
            case "streaming": return .purple
            case "pending": return .orange
            case "running": return .blue
            case "succeeded": return .green
            case "failed": return .red
            default: return colorForKind
            }
        }
        return colorForKind
    }
    
    /// Get the icon for tool status
    private var toolStatusIcon: String {
        // Handle "thinking" kind
        if event.kind == "thinking" {
            return "brain"
        }
        if let status = event.toolStatus {
            switch status {
            case "streaming": return "ellipsis"
            case "pending": return "clock"
            case "running": return "arrow.triangle.2.circlepath"
            case "succeeded": return "checkmark"
            case "failed": return "xmark"
            default: return symbol(for: event.kind)
            }
        }
        return symbol(for: event.kind)
    }
    
    /// Check if this event is actively streaming
    private var isActivelyStreaming: Bool {
        event.isStreaming == true || event.toolStatus == "streaming" || event.kind == "thinking"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Icon - shows spinner for running/streaming tools, checkmark/X for completed
                ZStack {
                    Circle()
                        .fill(effectiveColor.opacity(0.15))
                        .frame(width: 24, height: 24)
                        .overlay(
                            // Pulsing ring for streaming events
                            Circle()
                                .stroke(effectiveColor.opacity(isActivelyStreaming ? 0.6 : 0), lineWidth: 2)
                                .scaleEffect(isActivelyStreaming ? 1.3 : 1.0)
                                .opacity(isActivelyStreaming ? 0 : 1)
                                .animation(
                                    isActivelyStreaming 
                                        ? Animation.easeOut(duration: 1.0).repeatForever(autoreverses: false)
                                        : .default,
                                    value: isActivelyStreaming
                                )
                        )
                    
                    if isToolEvent && (event.toolStatus == "running" || event.toolStatus == "streaming") {
                        // Spinning indicator for running/streaming tools
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    } else if event.kind == "thinking" {
                        // Brain icon with pulse for thinking
                        Image(systemName: "brain")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(effectiveColor)
                            .opacity(0.8)
                    } else {
                        Image(systemName: isToolEvent ? toolStatusIcon : symbol(for: event.kind))
                            .font(.system(size: 10, weight: isToolEvent ? .bold : .regular))
                            .foregroundColor(effectiveColor)
                    }
                }
                
                // Compact title for tool events
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(isToolEvent && event.toolStatus == "failed" ? .red : .primary)
                    
                    // Compact inline summary when collapsed
                    if !expanded {
                        if let fileChange = event.fileChange {
                            Text(fileChange.fileName)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        } else if let cmd = event.command, !cmd.isEmpty {
                            Text(String(cmd.prefix(40)) + (cmd.count > 40 ? "..." : ""))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                
                Spacer()
                
                // Inline approval buttons (shown for pending approvals)
                if hasPendingApproval, let approvalId = event.pendingApprovalId {
                    HStack(spacing: 8) {
                        // View Changes button (opens modal with approve/reject)
                        if let fileChange = event.fileChange {
                            ViewChangesButton(
                                fileChange: fileChange,
                                pendingApprovalId: approvalId,
                                toolName: event.pendingToolName,
                                onApprovalHandled: { approvalHandled = true }
                            )
                        }
                        
                        // Reject button (X)
                        Button(action: { rejectApproval(approvalId) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.red))
                        }
                        .buttonStyle(.plain)
                        .help("Reject")
                        
                        // Approve button (checkmark)
                        Button(action: { approveApproval(approvalId) }) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.green))
                        }
                        .buttonStyle(.plain)
                        .help("Approve")
                    }
                } else {
                    // View Changes button (shown when there's a file change but not pending)
                    if let fileChange = event.fileChange {
                        ViewChangesButton(fileChange: fileChange)
                    }
                }
                
                // Action buttons (shown when there's a command)
                if let cmd = event.command, !cmd.isEmpty {
                    HStack(spacing: 4) {
                        // Copy button
                        Button(action: { copyCommand(cmd) }) {
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(showCopied ? .green : .secondary)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .help("Copy command")
                        
                        // Re-run button
                        Button(action: { rerunCommand(cmd) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .help("Re-run in terminal")
                    }
                }
                
                Button(action: { withAnimation(.spring(response: 0.3)) { expanded.toggle() } }) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    // File change inline preview
                    if let fileChange = event.fileChange {
                        InlineDiffPreview(fileChange: fileChange, maxLines: 8)
                    }
                    
                    if let cmd = event.command, !cmd.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(cmd)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                            
                            Spacer()
                            
                            // Inline action buttons
                            HStack(spacing: 8) {
                                Button(action: { copyCommand(cmd) }) {
                                    Label(showCopied ? "Copied" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundColor(showCopied ? .green : .accentColor)
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { rerunCommand(cmd) }) {
                                    Label("Re-run", systemImage: "arrow.clockwise")
                                        .font(.caption2)
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.03))
                        )
                    }
                    
                    if let details = event.details, !details.isEmpty, event.fileChange == nil {
                        // Truncate details to 150 chars for compactness
                        let truncatedDetails = details.count > 150 ? String(details.prefix(150)) + "..." : details
                        Text(truncatedDetails)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                    
                    if let output = event.output, !output.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            // Truncate output to first 500 chars with "show more" link
                            let truncatedOutput = output.count > 500 ? String(output.prefix(500)) + "..." : output
                            let lineCount = output.components(separatedBy: "\n").count
                            
                            ScrollView {
                                Text(truncatedOutput)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 40, maxHeight: 120)
                            
                            if output.count > 500 || lineCount > 8 {
                                Text("\(output.count) chars, \(lineCount) lines")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(isToolEvent ? 10 : 12) // Slightly more compact for tool events
        .background(
            RoundedRectangle(cornerRadius: isToolEvent ? 10 : 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isToolEvent ? 10 : 14)
                .stroke(effectiveColor.opacity(0.2), lineWidth: 1)
        )
        .onAppear { expanded = !(event.collapsed ?? true) }
    }
    
    private var colorForKind: Color {
        switch event.kind.lowercased() {
        case "status": return .blue
        case "step": return .green
        case "summary": return .purple
        case "file_change":
            // Use red for destructive operations (delete file), orange for others
            if event.fileChange?.operationType == .deleteFile {
                return .red
            }
            return .orange
        case "command_approval": return .orange
        case "plan_created": return Color(red: 0.7, green: 0.4, blue: 0.9)  // Navigator purple
        case "mode_switch": return .cyan  // Distinctive color for mode switching
        default: return .gray
        }
    }

    private func symbol(for kind: String) -> String {
        switch kind.lowercased() {
        case "status": return "bolt.fill"
        case "step": return "play.fill"
        case "summary": return "checkmark"
        case "file_change":
            // Use trash icon for delete, doc icon for others
            if event.fileChange?.operationType == .deleteFile {
                return "trash.fill"
            }
            return "doc.text.fill"
        case "command_approval": return "exclamationmark.shield.fill"
        case "plan_created": return "map.fill"
        case "mode_switch": return "arrow.triangle.swap"
        default: return "info.circle"
        }
    }
    
    /// Check if this is a command approval (vs file change approval)
    private var isCommandApproval: Bool {
        event.kind.lowercased() == "command_approval"
    }
    
    private func copyCommand(_ cmd: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        
        withAnimation {
            showCopied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopied = false
            }
        }
    }
    
    private func rerunCommand(_ cmd: String) {
        // Send command to terminal
        ptyModel.sendInput?(cmd + "\n")
    }
    
    private func approveApproval(_ approvalId: UUID) {
        approvalHandled = true
        // Use different notification based on approval type
        let notificationName: Notification.Name = isCommandApproval 
            ? .TermAICommandApprovalResponse 
            : .TermAIFileChangeApprovalResponse
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [
                "approvalId": approvalId,
                "approved": true
            ]
        )
    }
    
    private func rejectApproval(_ approvalId: UUID) {
        approvalHandled = true
        // Use different notification based on approval type
        let notificationName: Notification.Name = isCommandApproval 
            ? .TermAICommandApprovalResponse 
            : .TermAIFileChangeApprovalResponse
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [
                "approvalId": approvalId,
                "approved": false
            ]
        )
    }
}

// MARK: - Plan Ready View (Navigator Mode)

/// Displays when a plan has been created in Navigator mode
/// Shows plan title and action buttons to view, build with Copilot, or build with Pilot
struct PlanReadyView: View {
    let planId: UUID
    let planTitle: String
    @ObservedObject var session: ChatSession
    let onOpenPlan: (UUID) -> Void
    
    @Environment(\.colorScheme) var colorScheme
    
    private let navigatorColor = Color(red: 0.7, green: 0.4, blue: 0.9)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with title and view button
            HStack(spacing: 8) {
                Image(systemName: "map.fill")
                    .font(.system(size: 12))
                    .foregroundColor(navigatorColor)
                
                Text(planTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Spacer()
                
                // View Plan button (inline with title)
                Button(action: { onOpenPlan(planId) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .font(.system(size: 10))
                        Text("View")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(navigatorColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(navigatorColor.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .help("Open plan in file viewer")
            }
            
            // Build buttons row
            HStack(spacing: 8) {
                Text("Build with:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                // Build with Copilot button
                Button(action: { buildWithMode(.copilot) }) {
                    HStack(spacing: 4) {
                        Image(systemName: AgentMode.copilot.icon)
                            .font(.system(size: 10))
                        Text("Copilot")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AgentMode.copilot.color)
                    )
                }
                .buttonStyle(.plain)
                .help("File operations only")
                
                // Build with Pilot button
                Button(action: { buildWithMode(.pilot) }) {
                    HStack(spacing: 4) {
                        Image(systemName: AgentMode.pilot.icon)
                            .font(.system(size: 10))
                        Text("Pilot")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AgentMode.pilot.color)
                    )
                }
                .buttonStyle(.plain)
                .help("Full shell access")
                
                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(colorScheme == .dark
                    ? Color(red: 0.17, green: 0.19, blue: 0.23)  // #2c313a Atom One Dark elevated
                    : Color(red: 0.96, green: 0.96, blue: 0.96)) // #f5f5f5 Atom One Light
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(navigatorColor.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func buildWithMode(_ mode: AgentMode) {
        // Add mode switch indicator to chat
        session.messages.append(ChatMessage(
            role: "assistant",
            content: "",
            agentEvent: AgentEvent(
                kind: "mode_switch",
                title: "Navigator → \(mode.rawValue)",
                details: "Switching to \(mode.rawValue) mode to implement the plan",
                command: nil,
                output: nil,
                collapsed: true
            )
        ))
        session.messages = session.messages
        session.persistMessages()
        
        // Switch to the selected mode
        session.agentMode = mode
        session.persistSettings()
        
        // Load the plan content
        if let planContent = PlanManager.shared.getPlanContent(id: planId) {
            // Update plan status to implementing
            Task { @MainActor in
                PlanManager.shared.updatePlanStatus(id: planId, status: .implementing)
            }
            
            // Extract checklist from plan and set it directly (so agent doesn't recreate it)
            let checklistItems = extractChecklistFromPlan(planContent)
            if !checklistItems.isEmpty {
                session.agentChecklist = TaskChecklist(from: checklistItems, goal: "Implement: \(planTitle)")
                
                // Add a checklist message to the UI
                let checklistDisplay = session.agentChecklist!.displayString
                session.messages.append(ChatMessage(
                    role: "assistant",
                    content: "",
                    agentEvent: AgentEvent(
                        kind: "checklist",
                        title: "Task Checklist (\(session.agentChecklist!.completedCount)/\(session.agentChecklist!.items.count) done)",
                        details: checklistDisplay,
                        command: nil,
                        output: nil,
                        collapsed: false,
                        checklistItems: session.agentChecklist!.items
                    )
                ))
                session.messages = session.messages
                session.persistMessages()
            }
            
            // Attach the plan as context and send implementation request
            let planContext = PinnedContext(
                type: .snippet,
                path: "plan://\(planId.uuidString)",
                displayName: "Implementation Plan: \(planTitle)",
                content: planContent
            )
            session.pendingAttachedContexts.append(planContext)
            
            // Track current plan
            session.currentPlanId = planId
            session.persistSettings()
            
            // Send the implementation message
            // Tell the agent the checklist is already set
            let implementationMessage = checklistItems.isEmpty
                ? "Please implement the attached implementation plan. Follow the checklist items in order."
                : "Please implement the attached implementation plan. The checklist has already been extracted and is shown above - use it to track your progress. Focus on completing each item in order. Do NOT call plan_and_track to create a new checklist."
            
            Task {
                await session.sendUserMessage(implementationMessage)
            }
        }
    }
    
    /// Extract checklist items from plan markdown content
    private func extractChecklistFromPlan(_ content: String) -> [String] {
        var items: [String] = []
        var inChecklistSection = false
        
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Look for Checklist header
            if trimmed.lowercased().contains("## checklist") || trimmed.lowercased() == "checklist" {
                inChecklistSection = true
                continue
            }
            
            // Stop at next section
            if inChecklistSection && trimmed.hasPrefix("##") && !trimmed.lowercased().contains("checklist") {
                break
            }
            
            // Extract checklist items (- [ ] format)
            if inChecklistSection && (trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")) {
                let item = trimmed
                    .replacingOccurrences(of: "- [ ] ", with: "")
                    .replacingOccurrences(of: "- [x] ", with: "")
                    .replacingOccurrences(of: "- [X] ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                
                if !item.isEmpty {
                    items.append(item)
                }
            }
        }
        
        return items
    }
}

// MARK: - Agent Event Group View (Compact grouped events: tools, profile changes, etc.)

struct AgentEventGroupView: View {
    let events: [AgentEvent]
    let ptyModel: PTYModel
    
    @State private var expanded: Bool = false
    
    // Tool counts
    private var toolEvents: [AgentEvent] {
        events.filter { $0.eventCategory == "tool" || ($0.toolCallId != nil && $0.eventCategory != "command") }
    }
    
    private var succeededCount: Int {
        toolEvents.filter { $0.toolStatus == "succeeded" }.count
    }
    
    private var failedCount: Int {
        toolEvents.filter { $0.toolStatus == "failed" }.count
    }
    
    private var runningCount: Int {
        toolEvents.filter { $0.toolStatus == "running" || $0.toolStatus == "streaming" }.count
    }
    
    // Command counts (shell commands that needed approval)
    private var commandEvents: [AgentEvent] {
        events.filter { $0.eventCategory == "command" }
    }
    
    private var commandSucceededCount: Int {
        commandEvents.filter { $0.toolStatus == "succeeded" }.count
    }
    
    private var commandFailedCount: Int {
        commandEvents.filter { $0.toolStatus == "failed" }.count
    }
    
    // Profile change counts
    private var profileChangeCount: Int {
        events.filter { $0.eventCategory == "profile" }.count
    }
    
    // Other status events
    private var otherStatusCount: Int {
        events.filter { 
            $0.eventCategory != "tool" && $0.eventCategory != "profile" && $0.eventCategory != "command" && $0.toolCallId == nil
        }.count
    }
    
    private var streamingCount: Int {
        toolEvents.filter { $0.toolStatus == "streaming" || $0.isStreaming == true }.count
    }
    
    private var summaryParts: [(text: String, color: Color)] {
        var parts: [(text: String, color: Color)] = []
        
        // Tool summary
        let toolCount = toolEvents.count
        if toolCount > 0 {
            parts.append(("\(toolCount) tool\(toolCount == 1 ? "" : "s")", .secondary))
            if failedCount > 0 {
                parts.append(("(\(failedCount) failed)", .red))
            } else if streamingCount > 0 {
                parts.append(("(\(streamingCount) streaming)", .purple))
            } else if runningCount > 0 {
                parts.append(("(\(runningCount) running)", .blue))
            }
        }
        
        // Command summary (shell commands)
        let cmdCount = commandEvents.count
        if cmdCount > 0 {
            parts.append(("\(cmdCount) cmd\(cmdCount == 1 ? "" : "s")", .cyan))
            if commandFailedCount > 0 {
                parts.append(("(\(commandFailedCount) failed)", .red))
            }
        }
        
        // Profile changes
        if profileChangeCount > 0 {
            parts.append(("\(profileChangeCount) profile Δ", .purple))
        }
        
        // Other status
        if otherStatusCount > 0 {
            parts.append(("\(otherStatusCount) status", .secondary))
        }
        
        return parts
    }
    
    private var hasRunning: Bool {
        runningCount > 0
    }
    
    /// Header color is neutral/blue - we don't want to alarm users with red
    /// Failures are shown in the summary text and individual rows
    private var headerColor: Color {
        if runningCount > 0 { return .blue }
        return .secondary
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact header
            Button(action: { withAnimation(.spring(response: 0.3)) { expanded.toggle() } }) {
                HStack(spacing: 8) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(headerColor.opacity(0.15))
                            .frame(width: 22, height: 22)
                        
                        if hasRunning {
                            ProgressView()
                                .scaleEffect(0.45)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "gearshape.2")
                                .font(.system(size: 9))
                                .foregroundColor(headerColor)
                        }
                    }
                    
                    // Dynamic title based on content
                    Text("Actions")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    // Summary badges - show each category with appropriate colors
                    HStack(spacing: 4) {
                        ForEach(Array(summaryParts.enumerated()), id: \.offset) { _, part in
                            Text(part.text)
                                .font(.system(size: 10))
                                .foregroundColor(part.color)
                        }
                    }
                    
                    Spacer()
                    
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            
            // Expanded list of tool events
            if expanded {
                Divider()
                    .padding(.horizontal, 10)
                
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        CompactToolRow(event: event, ptyModel: ptyModel)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(headerColor.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Compact Event Row (for grouped view - handles tools, profile changes, etc.)

struct CompactToolRow: View {
    let event: AgentEvent
    let ptyModel: PTYModel
    
    @State private var showDetails: Bool = false
    
    /// Is this a tool event?
    private var isToolEvent: Bool {
        event.eventCategory == "tool" || (event.toolCallId != nil && event.eventCategory != "command")
    }
    
    /// Is this a command (shell) event?
    private var isCommandEvent: Bool {
        event.eventCategory == "command"
    }
    
    /// Is this a profile change event?
    private var isProfileChange: Bool {
        event.eventCategory == "profile"
    }
    
    private var statusColor: Color {
        if isProfileChange {
            return .purple
        }
        if isCommandEvent {
            switch event.toolStatus {
            case "running": return .blue
            case "succeeded": return .cyan
            case "failed": return .red
            default: return .orange
            }
        }
        switch event.toolStatus {
        case "streaming": return .purple
        case "pending": return .orange
        case "running": return .blue
        case "succeeded": return .green
        case "failed": return .red
        default: return .gray
        }
    }
    
    private var statusIcon: String {
        if isProfileChange {
            return "person.crop.circle.badge.checkmark"
        }
        if isCommandEvent {
            switch event.toolStatus {
            case "running": return "terminal"
            case "succeeded": return "checkmark.circle"
            case "failed": return "xmark.circle"
            default: return "terminal"
            }
        }
        switch event.toolStatus {
        case "streaming": return "ellipsis"
        case "pending": return "clock"
        case "running": return "arrow.triangle.2.circlepath"
        case "succeeded": return "checkmark"
        case "failed": return "xmark"
        default: return "info.circle"
        }
    }
    
    /// Check if this event is actively streaming
    private var isActivelyStreaming: Bool {
        event.isStreaming == true || event.toolStatus == "streaming"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation(.spring(response: 0.25)) { showDetails.toggle() } }) {
                HStack(spacing: 6) {
                    // Status indicator
                    if isToolEvent && (event.toolStatus == "running" || event.toolStatus == "streaming") {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(statusColor)
                            .frame(width: 12, height: 12)
                    }
                    
                    // Event title - different styling for different types
                    if isProfileChange {
                        Text("Profile: \(event.title)")
                            .font(.system(size: 11))
                            .foregroundColor(.purple)
                    } else if isCommandEvent {
                        // Show command with terminal styling
                        let cmdPreview = event.command.map { String($0.prefix(35)) + ($0.count > 35 ? "…" : "") } ?? event.title
                        Text("$ \(cmdPreview)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(event.toolStatus == "failed" ? .red : .cyan)
                    } else {
                        Text(event.title)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(event.toolStatus == "failed" ? .red : .primary)
                    }
                    
                    // File change indicator
                    if event.fileChange != nil {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                    
                    Spacer()
                    
                    if event.output != nil || event.details != nil || event.fileChange != nil {
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(showDetails ? Color.primary.opacity(0.04) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            
            // Expanded details
            if showDetails {
                VStack(alignment: .leading, spacing: 6) {
                    // File change preview
                    if let fileChange = event.fileChange {
                        InlineDiffPreview(fileChange: fileChange, maxLines: 4)
                    }
                    
                    // Details/reason
                    if let details = event.details, !details.isEmpty, event.fileChange == nil {
                        Text(details)
                            .font(.system(size: 10, design: isToolEvent ? .monospaced : .default))
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                    
                    // Output (truncated) - only for tool events
                    if isToolEvent, let output = event.output, !output.isEmpty, event.fileChange == nil {
                        Text(String(output.prefix(200)) + (output.count > 200 ? "..." : ""))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(4)
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, 4)
            }
        }
    }
}
