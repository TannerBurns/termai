import Foundation
import os.log

private let suggestionLogger = Logger(subsystem: "com.termai.app", category: "Suggestions")

// MARK: - Terminal Suggestion Service

/// Service that generates AI-powered command suggestions based on terminal context
/// Create one instance per terminal tab to avoid state sharing issues
@MainActor
final class TerminalSuggestionService: ObservableObject {
    /// Shared instance for backwards compatibility (settings previews, etc.)
    /// Prefer creating per-tab instances for actual terminal use
    static let shared = TerminalSuggestionService()
    
    // MARK: - Published State
    
    @Published var suggestions: [CommandSuggestion] = []
    @Published var isLoading: Bool = false
    @Published var needsModelSetup: Bool = false
    @Published var lastError: String? = nil
    @Published var isVisible: Bool = false
    @Published var sessionContext: SessionContext = SessionContext()
    
    /// Current phase of the agentic suggestion pipeline
    @Published var currentPhase: SuggestionPhase = .idle
    
    /// Detailed status message for the current phase
    @Published var phaseDetail: String? = nil
    
    /// Gathered context from the pipeline (for debugging/display)
    @Published var gatheredContext: GatheredContext = GatheredContext()
    
    // MARK: - Private State
    
    private var debounceTask: Task<Void, Never>?
    private var activeAPITask: Task<Void, Never>?
    private var postCommandTask: Task<Void, Never>?
    private var suggestionCache: [String: (suggestions: [CommandSuggestion], timestamp: Date)] = [:]
    private let cacheExpiration: TimeInterval = 300 // 5 minutes
    private let maxCacheSize: Int = 50
    private var lastContext: TerminalContext?
    
    /// Cooldown after command execution to prevent old cache from showing
    private var commandExecutionCooldown: Date? = nil
    private let cooldownDuration: TimeInterval = 0.5
    private let postCommandDelay: TimeInterval = 1.0
    
    /// Tracks when user manually dismissed suggestions
    private var userDismissed: Bool = false
    
    /// Hash of the last processed output to prevent duplicate triggers
    private var lastProcessedOutputHash: Int = 0
    
    /// Callback to get fresh terminal context for post-command regeneration
    var getTerminalContext: (() -> (cwd: String, lastOutput: String, lastExitCode: Int32, gitInfo: GitInfo?))?
    
    /// Callback to check if the chat agent is currently running
    var checkAgentRunning: (() -> Bool)?
    
    // MARK: - Extracted Module Instances
    
    private let researchPhase = SuggestionResearchPhase()
    
    // MARK: - Initialization
    
    init() {
        updateNeedsModelSetup()
        
        // Wire up phase updates from research phase
        researchPhase.onPhaseUpdate = { [weak self] phase in
            self?.setPhase(phase)
        }
    }
    
    // MARK: - Public API
    
    /// Update the needsModelSetup flag based on current settings
    func updateNeedsModelSetup() {
        let settings = AgentSettings.shared
        needsModelSetup = settings.terminalSuggestionsEnabled && !settings.isTerminalSuggestionsConfigured
    }
    
    /// Set the current phase with an optional detail message
    func setPhase(_ phase: SuggestionPhase, detail: String? = nil) {
        suggestionLogger.debug("Phase transition: \(self.currentPhase.label) → \(phase.label)\(detail.map { " (\($0))" } ?? "")")
        currentPhase = phase
        phaseDetail = detail
        isLoading = phase.isActive
    }
    
    /// Cancel all active work (debounce, API calls, post-command tasks)
    func cancelActiveWork() {
        let hadActiveWork = debounceTask != nil || activeAPITask != nil || postCommandTask != nil
        
        debounceTask?.cancel()
        debounceTask = nil
        
        activeAPITask?.cancel()
        activeAPITask = nil
        
        postCommandTask?.cancel()
        postCommandTask = nil
        
        if hadActiveWork {
            suggestionLogger.info("Cancelled active work (debounce/API/postCommand tasks)")
            setPhase(.idle)
        }
    }
    
    /// Resume suggestions after the chat agent has finished running
    func resumeSuggestionsAfterAgent() {
        suggestionLogger.info("Resuming suggestions after agent completed")
        
        guard let getContext = getTerminalContext else {
            suggestionLogger.warning("No terminal context callback available for resume")
            return
        }
        
        let ctx = getContext()
        triggerSuggestions(
            cwd: ctx.cwd,
            lastOutput: ctx.lastOutput,
            lastExitCode: ctx.lastExitCode,
            gitInfo: ctx.gitInfo
        )
    }
    
    /// Called when user activity is detected (command entered, cd, etc.)
    func userActivityDetected(
        command: String? = nil,
        cwd: String,
        gitInfo: GitInfo?,
        lastExitCode: Int32,
        lastOutput: String
    ) {
        // Ignore activity from chat agent
        if let checkAgent = checkAgentRunning, checkAgent() {
            suggestionLogger.info("Activity ignored - chat agent is currently running")
            return
        }
        
        suggestionLogger.info("User activity detected: \(command ?? "unknown command"), aborting active work")
        
        cancelActiveWork()
        userDismissed = false
        lastProcessedOutputHash = 0
        
        if let cmd = command, !cmd.isEmpty {
            sessionContext.addCommand(cmd, exitCode: 0, cwd: cwd)
            gatheredContext.lastCommand = cmd
            researchPhase.recordCommand()
        }
        
        commandExecutionCooldown = Date()
        suggestions = []
        isVisible = false
        lastError = nil
        
        if let ctx = lastContext {
            suggestionCache.removeValue(forKey: ctx.cacheKey)
        }
        
        lastContext = TerminalContext(
            cwd: cwd,
            lastOutput: lastOutput,
            lastExitCode: lastExitCode,
            gitInfo: gitInfo,
            recentCommands: []
        )
        
        suggestionLogger.debug("User activity processed, waiting for context change events to trigger pipeline")
    }
    
    /// Gather structured environment context for the suggestion pipeline
    func getStructuredEnvironmentContext(cwd: String, gitInfo: GitInfo?) -> EnvironmentContext {
        return EnvironmentContextProvider.shared.getStructuredEnvironmentContext(cwd: cwd, gitInfo: gitInfo)
    }
    
    // MARK: - Agentic Suggestion Pipeline
    
    /// Run the full agentic suggestion pipeline
    func runAgenticPipeline(context: TerminalContext, isStartup: Bool = false) async {
        suggestionLogger.info(">>> Starting agentic pipeline (startup: \(isStartup)) <<<")
        
        // Pause suggestions while chat agent is running
        if let checkAgent = checkAgentRunning, checkAgent() {
            suggestionLogger.info("Pipeline: Skipping - chat agent is currently running")
            setPhase(.idle)
            return
        }
        
        let settings = AgentSettings.shared
        
        guard settings.isTerminalSuggestionsConfigured,
              let provider = settings.terminalSuggestionsProvider,
              let modelId = settings.terminalSuggestionsModelId else {
            suggestionLogger.warning("Pipeline: Model not configured")
            updateNeedsModelSetup()
            setPhase(.idle)
            return
        }
        
        lastContext = context
        lastError = nil
        isVisible = true
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 1: Gather Context (Programmatic)
        // ═══════════════════════════════════════════════════════════════════
        setPhase(.gatheringContext(detail: "Reading shell history..."))
        
        var gathered = GatheredContext()
        gathered.terminalOutput = context.lastOutput
        gathered.lastExitCode = context.lastExitCode
        
        let envContext = getStructuredEnvironmentContext(cwd: context.cwd, gitInfo: context.gitInfo)
        
        if settings.readShellHistory && ShellHistoryParser.shared.isAvailable() {
            let historyContext = ShellHistoryParser.shared.getFormattedHistoryContext(topN: 15, recentN: 10)
            let rawFrequent = ShellHistoryParser.shared.getFrequentCommands(limit: 15)
            
            let filteredFrequent = CommandClassifier.filterForCurrentContext(
                commands: rawFrequent,
                cwd: context.cwd,
                envContext: envContext
            )
            
            if filteredFrequent.isEmpty {
                gathered.frequentCommandsFormatted = "(no relevant history for this context)"
            } else {
                gathered.frequentCommandsFormatted = filteredFrequent.prefix(10).map { freq in
                    let cmd = freq.command.count > 50 ? String(freq.command.prefix(47)) + "..." : freq.command
                    return "\(cmd) (\(freq.count))"
                }.joined(separator: ", ")
            }
            
            gathered.recentCommands = historyContext.recent
            suggestionLogger.info("Phase 1: Got \(gathered.recentCommands.count, privacy: .public) recent commands")
        }
        
        if !sessionContext.commandsThisSession.isEmpty {
            let sessionCmds = sessionContext.recentCommandStrings(limit: 5)
            gathered.recentCommands.insert(contentsOf: sessionCmds, at: 0)
        }
        
        setPhase(.gatheringContext(detail: "Detecting environment..."))
        
        gathered.environmentInfo.append(envContext.formattedForPrompt)
        gathered.shellConfigInsights = EnvironmentContextProvider.shared.gatherEnvironmentInfo(lastContextCwd: context.cwd)
        
        gatheredContext = gathered
        
        suggestionLogger.info("Phase 1 complete")
        
        guard !Task.isCancelled else {
            setPhase(.idle)
            return
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 1.5: Research Phase (AI-Driven Context Exploration)
        // ═══════════════════════════════════════════════════════════════════
        var researchFindings = ResearchFindings()
        if researchPhase.shouldRunResearch(isStartup: isStartup, terminalContext: context, gathered: gathered, envContext: envContext) {
            suggestionLogger.info("Phase 1.5: Starting research phase...")
            
            researchFindings = await researchPhase.runResearchPhase(
                gathered: gathered,
                envContext: envContext,
                terminalContext: context,
                provider: provider,
                modelId: modelId
            )
            
            suggestionLogger.info("Phase 1.5 complete: \(researchFindings.stepsTaken) steps, \(researchFindings.discoveries.count) discoveries")
            
            researchPhase.updateResearchState(cwd: context.cwd)
            
            guard !Task.isCancelled else {
                setPhase(.idle)
                return
            }
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 2: Planning (AI Call)
        // ═══════════════════════════════════════════════════════════════════
        setPhase(.planning)
        suggestionLogger.info("Phase 2: Planning...")
        
        let plan = await SuggestionPlanningPhase.planSuggestions(
            gathered: gathered,
            envContext: envContext,
            terminalContext: context,
            researchFindings: researchFindings,
            provider: provider,
            modelId: modelId
        )
        
        guard plan.shouldSuggest else {
            suggestionLogger.info("Planning decided no suggestions needed")
            suggestions = []
            setPhase(.idle)
            isVisible = false
            return
        }
        
        guard !Task.isCancelled else {
            setPhase(.idle)
            return
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // PHASE 3: Generate Suggestions (AI Call)
        // ═══════════════════════════════════════════════════════════════════
        setPhase(.generating)
        suggestionLogger.info("Phase 3: Generating suggestions (type: \(plan.suggestionType))...")
        
        do {
            let generatedSuggestions = try await SuggestionGenerator.generateSuggestionsFromPlan(
                plan: plan,
                gathered: gathered,
                envContext: envContext,
                terminalContext: context,
                researchFindings: researchFindings,
                provider: provider,
                modelId: modelId
            )
            
            suggestions = generatedSuggestions
            cacheSuggestions(generatedSuggestions, for: context)
            
            suggestionLogger.info("Pipeline complete: \(generatedSuggestions.count) suggestions generated")
        } catch {
            suggestionLogger.error("Generate suggestions failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
        
        setPhase(.idle)
        isVisible = !suggestions.isEmpty
    }
    
    // MARK: - Trigger and Debounce
    
    /// Trigger suggestion generation with debouncing
    func triggerSuggestions(
        cwd: String,
        lastOutput: String,
        lastExitCode: Int32,
        gitInfo: GitInfo?,
        recentCommands: [String] = []
    ) {
        suggestionLogger.info(">>> triggerSuggestions called - cwd: \(cwd, privacy: .public), exitCode: \(lastExitCode)")
        
        if let checkAgent = checkAgentRunning, checkAgent() {
            suggestionLogger.info("Skipping suggestions - chat agent is currently running")
            cancelActiveWork()
            suggestions = []
            isVisible = false
            return
        }
        
        let settings = AgentSettings.shared
        
        guard settings.terminalSuggestionsEnabled else {
            suggestionLogger.debug("Suggestions disabled in settings")
            suggestions = []
            isVisible = false
            return
        }
        
        updateNeedsModelSetup()
        
        guard settings.isTerminalSuggestionsConfigured else {
            suggestionLogger.debug("Model not configured, showing setup prompt")
            isVisible = true
            return
        }
        
        let outputHash = "\(cwd)|\(lastOutput.count)|\(lastExitCode)".hashValue
        
        let cwdChanged = lastContext?.cwd != cwd
        let exitCodeChanged = lastContext?.lastExitCode != lastExitCode
        let outputLengthChanged = (lastContext?.lastOutput.count ?? 0) != lastOutput.count
        
        var meaningfulContextChange = false
        
        if cwdChanged || exitCodeChanged || outputLengthChanged {
            if userDismissed {
                suggestionLogger.info("Meaningful context change detected, resetting userDismissed flag")
            }
            userDismissed = false
            meaningfulContextChange = true
            
            if activeAPITask != nil {
                let changeReason = cwdChanged ? "CWD" : (exitCodeChanged ? "exit code" : "output")
                suggestionLogger.info(">>> Context changed (\(changeReason)), cancelling active API task")
                cancelActiveWork()
            }
        }
        
        if outputHash == lastProcessedOutputHash && !cwdChanged && !exitCodeChanged {
            suggestionLogger.debug("Same context as last trigger, skipping")
            return
        }
        lastProcessedOutputHash = outputHash
        
        let context = TerminalContext(
            cwd: cwd,
            lastOutput: lastOutput,
            lastExitCode: lastExitCode,
            gitInfo: gitInfo,
            recentCommands: recentCommands
        )
        
        let inCooldown = commandExecutionCooldown.map { Date().timeIntervalSince($0) < cooldownDuration } ?? false
        
        if !inCooldown && !userDismissed, let cached = getCachedSuggestions(for: context) {
            suggestionLogger.debug("Using cached suggestions: \(cached.count) items")
            suggestions = cached
            isVisible = !cached.isEmpty
            return
        }
        
        debounceTask?.cancel()
        
        let debounceSeconds = meaningfulContextChange ? 0.3 : settings.terminalSuggestionsDebounceSeconds
        suggestionLogger.debug("Starting debounce timer (\(debounceSeconds)s)")
        
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(debounceSeconds * 1_000_000_000))
                
                guard !Task.isCancelled else { return }
                guard let self = self else { return }
                
                suggestionLogger.debug("Debounce complete, running agentic pipeline")
                
                if let existingTask = self.activeAPITask {
                    suggestionLogger.debug("Cancelling existing API task before starting new one")
                    existingTask.cancel()
                    self.activeAPITask = nil
                }
                
                let freshContext: TerminalContext
                if let getContext = self.getTerminalContext {
                    let ctx = getContext()
                    freshContext = TerminalContext(
                        cwd: ctx.cwd,
                        lastOutput: ctx.lastOutput,
                        lastExitCode: ctx.lastExitCode,
                        gitInfo: ctx.gitInfo,
                        recentCommands: []
                    )
                    self.lastContext = freshContext
                } else {
                    freshContext = context
                }
                
                self.activeAPITask = Task { [weak self] in
                    guard let self = self else { return }
                    await self.runAgenticPipeline(context: freshContext, isStartup: false)
                    self.activeAPITask = nil
                }
            } catch {
                suggestionLogger.debug("Debounce sleep threw: \(error.localizedDescription)")
            }
        }
    }
    
    /// Force immediate suggestion generation (no debounce)
    func generateSuggestionsNow(
        cwd: String,
        lastOutput: String,
        lastExitCode: Int32,
        gitInfo: GitInfo?,
        recentCommands: [String] = []
    ) async {
        let context = TerminalContext(
            cwd: cwd,
            lastOutput: lastOutput,
            lastExitCode: lastExitCode,
            gitInfo: gitInfo,
            recentCommands: recentCommands
        )
        
        await runAgenticPipeline(context: context, isStartup: false)
    }
    
    /// Clear current suggestions and hide overlay
    func clearSuggestions(userInitiated: Bool = false) {
        debounceTask?.cancel()
        suggestions = []
        isVisible = false
        lastError = nil
        if userInitiated {
            userDismissed = true
            suggestionLogger.debug("User dismissed suggestions - will not show cached until meaningful event")
        }
    }
    
    /// Called when a suggested command is executed
    func commandExecuted(command: String? = nil, cwd: String? = nil, waitForCWDUpdate: Bool = false) {
        if let checkAgent = checkAgentRunning, checkAgent() {
            suggestionLogger.info("Command executed ignored - chat agent is currently running")
            return
        }
        
        suggestionLogger.debug("Command executed: \(command ?? "unknown"), clearing and setting cooldown")
        debounceTask?.cancel()
        postCommandTask?.cancel()
        suggestions = []
        isVisible = false
        lastError = nil
        setPhase(.idle)
        
        userDismissed = false
        lastProcessedOutputHash = 0
        commandExecutionCooldown = Date()
        
        researchPhase.recordCommand()
        
        if let ctx = lastContext {
            suggestionCache.removeValue(forKey: ctx.cacheKey)
        }
        
        if let cmd = command, let dir = cwd ?? lastContext?.cwd {
            sessionContext.addCommand(cmd, exitCode: 0, cwd: dir)
            gatheredContext.lastCommand = cmd
        }
        
        guard !waitForCWDUpdate else {
            suggestionLogger.info("Waiting for CWD update event to trigger pipeline")
            return
        }
        
        let totalDelay = cooldownDuration + postCommandDelay
        suggestionLogger.info("Scheduling post-command agentic pipeline in \(totalDelay)s")
        
        postCommandTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(totalDelay * 1_000_000_000))
                
                guard !Task.isCancelled else { return }
                guard let self = self else { return }
                
                suggestionLogger.info(">>> Post-command delay complete, running agentic pipeline <<<")
                
                if let getContext = self.getTerminalContext {
                    let ctx = getContext()
                    
                    if !self.sessionContext.commandsThisSession.isEmpty {
                        let lastIdx = self.sessionContext.commandsThisSession.count - 1
                        var lastCmd = self.sessionContext.commandsThisSession[lastIdx]
                        lastCmd = SessionCommand(command: lastCmd.command, exitCode: ctx.lastExitCode, cwd: lastCmd.cwd)
                        self.sessionContext.commandsThisSession[lastIdx] = lastCmd
                    }
                    
                    let terminalContext = TerminalContext(
                        cwd: ctx.cwd,
                        lastOutput: ctx.lastOutput,
                        lastExitCode: ctx.lastExitCode,
                        gitInfo: ctx.gitInfo,
                        recentCommands: self.sessionContext.recentCommandStrings(limit: 5)
                    )
                    
                    await self.runAgenticPipeline(context: terminalContext, isStartup: false)
                } else {
                    suggestionLogger.warning("No terminal context callback available")
                }
            } catch {
                suggestionLogger.debug("Post-command sleep threw: \(error.localizedDescription)")
            }
        }
    }
    
    /// Toggle visibility of suggestions overlay
    func toggleVisibility() {
        isVisible.toggle()
        
        if isVisible && suggestions.isEmpty && lastContext != nil {
            if let ctx = lastContext {
                triggerSuggestions(
                    cwd: ctx.cwd,
                    lastOutput: ctx.lastOutput,
                    lastExitCode: ctx.lastExitCode,
                    gitInfo: ctx.gitInfo,
                    recentCommands: ctx.recentCommands
                )
            }
        }
    }
    
    // MARK: - Cache Management
    
    private func getCachedSuggestions(for context: TerminalContext) -> [CommandSuggestion]? {
        let key = context.cacheKey
        guard let cached = suggestionCache[key] else { return nil }
        
        if Date().timeIntervalSince(cached.timestamp) > cacheExpiration {
            suggestionCache.removeValue(forKey: key)
            return nil
        }
        
        return cached.suggestions
    }
    
    private func cacheSuggestions(_ suggestions: [CommandSuggestion], for context: TerminalContext) {
        let key = context.cacheKey
        suggestionCache[key] = (suggestions, Date())
        
        let now = Date()
        suggestionCache = suggestionCache.filter { now.timeIntervalSince($0.value.timestamp) < cacheExpiration }
        
        if suggestionCache.count > maxCacheSize {
            let sortedEntries = suggestionCache.sorted { $0.value.timestamp > $1.value.timestamp }
            let keysToKeep = Set(sortedEntries.prefix(maxCacheSize).map { $0.key })
            suggestionCache = suggestionCache.filter { keysToKeep.contains($0.key) }
        }
    }
    
    // MARK: - Project Detection (Delegated)
    
    func detectProjectType(at path: String) -> ProjectType {
        return EnvironmentContextProvider.shared.detectProjectType(at: path)
    }
    
    // MARK: - Startup Suggestions
    
    func triggerStartupSuggestions(
        cwd: String,
        gitInfo: GitInfo?,
        isNewDirectory: Bool = false
    ) {
        suggestionLogger.info("triggerStartupSuggestions called - cwd: \(cwd), isNew: \(isNewDirectory)")
        
        if let checkAgent = checkAgentRunning, checkAgent() {
            suggestionLogger.info("Startup: Skipping - chat agent is currently running")
            setPhase(.idle)
            return
        }
        
        let settings = AgentSettings.shared
        
        guard settings.terminalSuggestionsEnabled else {
            suggestionLogger.debug("Suggestions disabled, returning")
            suggestions = []
            isVisible = false
            setPhase(.idle)
            return
        }
        
        updateNeedsModelSetup()
        
        if settings.isTerminalSuggestionsConfigured {
            let projectType = detectProjectType(at: cwd)
            suggestionLogger.info("Model configured, starting agentic startup pipeline")
            suggestionLogger.info("Project type detected: \(projectType.rawValue, privacy: .public)")
            
            isVisible = true
            
            let recentCmds = sessionContext.recentCommandStrings(limit: 5)
            
            Task { [weak self] in
                guard let self = self else { return }
                
                let terminalContext = TerminalContext(
                    cwd: cwd,
                    lastOutput: "",
                    lastExitCode: 0,
                    gitInfo: gitInfo,
                    recentCommands: recentCmds
                )
                
                await self.runAgenticPipeline(context: terminalContext, isStartup: true)
                
                suggestionLogger.info("Startup pipeline complete: \(self.suggestions.count) suggestions")
                if self.suggestions.isEmpty {
                    self.isVisible = false
                }
            }
        } else {
            suggestionLogger.info("No AI configured, showing setup prompt only")
            suggestions = []
            isVisible = true
            setPhase(.idle)
        }
        
        CommandHistoryStore.shared.markVisited(cwd)
    }
}
