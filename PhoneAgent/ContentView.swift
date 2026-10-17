import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedDestination: WorkspaceDestination = .tasks
    @State private var navigationForward = true
    @State private var calibration: CalibrationModel?
    @State private var showCalibration = false
    @State private var showCall = false
    @State private var sheet: WorkspaceSheet?
    @State private var pendingSheet: WorkspaceSheet?
    @State private var dismissingSheet = false
    @State private var confirmingWorkbenchExit = false
    @State private var pendingDestination: WorkspaceDestination?
    @State private var pendingDestinationSheet: WorkspaceSheet?
    @State private var screen: TaskScreen = .draft
    @State private var sidebarOpen = false
    @State private var modeSwitcherOpen = false
    @State private var newAssistantRequest = UUID()
    @State private var reviewVoicePhase: DictationPhase?
    private let reviewVoiceError: String
    @State private var dictatedDraft: String?
    @State private var voiceCommandTask: Task<Void, Never>?
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.28, dampingFraction: 1))) private var sidebarDrag: CGFloat = 0
    @State private var viewportWidth: CGFloat = 393
    @State private var preparationExpanded = false
    @State private var expandedSteps = false
    @State private var followLatest = true
    @State private var appeared = false
    @State private var discardingDraft = false
    @State private var amendmentDrafts: [UUID: String] = [:]
    @State private var searchText = ""
    @State private var sidebarSearchExpanded = false
    @FocusState private var composing: Bool
    @Namespace private var glassNamespace
    private var calibrated: Bool { model.calibrationReady }
    private var sidebarWidth: CGFloat { min(viewportWidth * 0.77, 360) }
    private var sidebarScrimColor: Color {
        colorScheme == .light ? Color.white.opacity(0.4) : Color.black.opacity(0.4)
    }
    private var busy: Bool { model.interactionBusy }
    private var displayedRecord: PhoneTaskRecord? {
        guard case .conversation(let id) = screen else { return nil }
        if model.engine.currentRecord?.id == id { return model.engine.currentRecord }
        return model.history.records.first { $0.id == id }
    }
    private var isCurrentConversation: Bool {
        guard let record = displayedRecord else { return false }
        return record.id == model.engine.currentRecord?.id
    }
    private var composingSupplement: Bool {
        guard let record = displayedRecord, isCurrentConversation else { return false }
        return model.engine.hasCurrentTask || !(amendmentDrafts[record.id] ?? "").isEmpty
    }
    private var composerText: Binding<String> {
        if composingSupplement, let id = displayedRecord?.id {
            return Binding(get: { amendmentDrafts[id] ?? "" }, set: { amendmentDrafts[id] = $0 })
        }
        return $model.goal
    }
    private var queueingDraft: Bool { !composingSupplement && (model.engine.hasCurrentTask || model.taskQueue.pendingCount > 0 || model.queueRunning) }
    private var inputBlocked: Bool {
        model.recordingAudioOwner != nil || model.queueSwitching || model.calibrating || model.manualBusy || model.voicePending || model.engine.releasing
    }
    init(reviewDestination: WorkspaceDestination = .tasks, reviewConversation: UUID? = nil, reviewVoice: DictationPhase? = nil, reviewVoiceError: String = "") {
        _selectedDestination = State(initialValue: reviewDestination)
        _reviewVoicePhase = State(initialValue: reviewVoice)
        self.reviewVoiceError = reviewVoiceError
        _screen = State(initialValue: reviewConversation.map { .conversation($0) } ?? .draft)
    }
    var body: some View {
        lifecycleWorkspace
    }

    private var workspace: some View {
        ZStack {
            // The shifted main page is the raised surface; the sidebar stays flat.
            (sidebarOpen ? AgentPalette.surface : AgentPalette.background)
                .ignoresSafeArea().accessibilityHidden(true)
            Group {
                switch selectedDestination {
                case .screenShare: CaptureView()
                case .device: DeviceView(onCalibration: beginCalibration)
                case .settings: SettingsView(onBack: { navigate(.tasks) })
                case .assistant: AssistantView(newConversationRequest: newAssistantRequest, reviewDictation: reviewVoicePhase, allowsDictation: sheet == nil && !sidebarOpen && !modeSwitcherOpen, onModelSetup: { navigate(.settings) })
                case .memory: MemoryView()
                case .workbench: WorkbenchView()
                case .queue: TaskQueueView()
                case .tasks: taskPage
                }
            }.id(selectedDestination).transition(pageTransition)
        }
        .animation(pageAnimation, value: selectedDestination).tint(AgentPalette.accent)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if selectedDestination != .settings { topBar }
                AgentPiPPanel(controller: model.pip)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .modifier(SidebarMainSurface(open: sidebarOpen))
        .offset(x: sidebarOpen && !reduceMotion ? max(0, sidebarWidth + sidebarDrag) : 0)
        .accessibilityHidden(sidebarOpen)
        .overlay { sidebarOverlay }
    }

    private var presentedWorkspace: some View {
        workspace
        .sheet(item: $sheet, onDismiss: {
            dismissingSheet = false
            if let next = pendingSheet {
                pendingSheet = nil
                sheet = next
            } else { consumeModalRequests() }
        }) { route in
            Group { switch route {
            case .task(let id): TaskDetailView(id: id)
            case .plan: TaskPlanView()
            case .preparation:
                PreparationView { destination in sheet = nil; model.showPreparation = false; navigate(destination) }
            case .consent: DataConsentView(onDecision: dismissCurrentSheet)
            case .policy: DataPolicyView()
            case .settings: SettingsView(onBack: dismissCurrentSheet)
            } }.agentSheetStyle()
        }
        .fullScreenCover(isPresented: $showCalibration, onDismiss: { model.calibrating = false; model.cancelCalibration = nil }) {
            if let calibration { CalibrationView(model: calibration) }
        }
        .fullScreenCover(isPresented: $showCall) { CallView(call: model.call) }
    }

    private var lifecycleWorkspace: some View {
        presentedWorkspace
        .onAppear {
            if model.engine.hasCurrentTask, let record = model.engine.currentRecord { screen = .conversation(record.id) }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { appeared = true }
            configureAutomaticPiP(model.settings.autoPiPOnExit ?? false)
            consumeModalRequests()
            if let mode = model.voiceMode { routeInlineVoice(mode) }
        }
        .onOpenURL { url in if url.scheme == "phoneagent", url.host == "task", let record = model.engine.currentRecord { openConversation(record) } }
        .onChange(of: model.engine.currentRecord?.id) { _, id in
            if let id {
                if screen == .draft, model.goal == model.engine.currentRecord?.goal { model.goal = "" }
                screen = .conversation(id); expandedSteps = false; followLatest = true
            }
        }
        .onChange(of: model.history.records.map(\.id)) { _, ids in
            if case .conversation(let id) = screen, !ids.contains(id), model.engine.currentRecord?.id != id { screen = .draft }
        }
        .onChange(of: model.showPrivacyConsent) { _, show in
            if show { consumeModalRequests() }
        }
        .onChange(of: model.showPreparation) { _, show in if show { consumeModalRequests() } }
        .onChange(of: model.showPrivacyPolicy) { _, show in if show { consumeModalRequests() } }
        .onChange(of: model.voiceRequestID) { _, _ in navigate(model.voiceMode == .question ? .assistant : .tasks); setSidebar(false); composing = false }
        .onChange(of: model.voiceMode) { _, mode in
            if let mode { routeInlineVoice(mode) }
        }
        .onChange(of: model.showAssistant) { _, show in if show { model.showAssistant = false; navigate(.assistant) } }
        .onChange(of: model.settings.autoPiPOnExit) { _, value in
            configureAutomaticPiP(value ?? false)
        }
        .alert("Leave Notes & Files?", isPresented: $confirmingWorkbenchExit) {
            Button("Keep Editing", role: .cancel) { pendingDestination = nil; pendingDestinationSheet = nil }
            Button("Leave and Discard Drafts", role: .destructive) {
                if let destination = pendingDestination {
                    let route = pendingDestinationSheet
                    pendingDestination = nil; pendingDestinationSheet = nil
                    completeNavigation(destination, showing: route)
                }
            }
        } message: { Text("Source text, file drafts, and minutes exist only in this workbench session. Keep editing to save them to memory or export; leaving clears this page.") }
        .confirmationDialog("Discard unsent task?", isPresented: $discardingDraft, titleVisibility: .visible) {
            Button("Discard and Start New", role: .destructive) { resetDraft() }
            Button("Keep Editing", role: .cancel) {}
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentPiPController.restoreTask)) { _ in
            if let record = model.engine.currentRecord { openConversation(record) } else { navigate(.tasks) }
        }
        .onChange(of: phase) { _, new in
            if new == .active { model.ble.refresh() }
            if new == .active && !model.speech.usingAudio { model.pip.applicationBecameActive() }
            if new == .background && !model.speech.usingAudio { model.pip.applicationEnteredBackground() }
            if new == .background {
                voiceCommandTask?.cancel(); voiceCommandTask = nil
                // The inline composer retains partial text before releasing audio.
                if model.voiceMode == nil { model.speech.cancel() }
            }
            if new != .active && model.manualBusy { model.stop() }
        }
    }
    private func routeInlineVoice(_ mode: VoiceInputMode) {
        composing = false; setSidebar(false)
        navigate(mode == .question ? .assistant : .tasks)
        if mode == .supplement, let record = model.engine.currentRecord {
            screen = .conversation(record.id)
        }
        if sheet != nil { pendingSheet = nil; dismissCurrentSheet() }
    }
    private var voiceComposerText: Binding<String> {
        if model.voiceMode == .supplement, let id = model.engine.currentRecord?.id {
            return Binding(get: { amendmentDrafts[id] ?? "" }, set: { amendmentDrafts[id] = $0 })
        }
        return $model.goal
    }
    private func consumeModalRequests() {
        if model.showPrivacyConsent {
            model.showPrivacyConsent = false; composing = false; present(.consent)
        } else if model.showPreparation {
            model.showPreparation = false; composing = false; present(.preparation)
        } else if model.showPrivacyPolicy {
            model.showPrivacyPolicy = false; present(.policy)
        }
    }
    private func present(_ route: WorkspaceSheet) {
        composing = false
        setSidebar(false)
        if sheet == nil, !dismissingSheet { sheet = route }
        else if sheet?.id != route.id {
            pendingSheet = route; dismissingSheet = true; sheet = nil
        }
    }
    private func dismissCurrentSheet() {
        // A queued destination opens only after the current presentation has closed.
        dismissingSheet = true; sheet = nil
    }
    private var pageAnimation: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.28, bounce: 0) }
    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(x: navigationForward ? 18 : -18)),
            removal: .opacity.combined(with: .offset(x: navigationForward ? -10 : 10)))
    }
    private func navigate(_ destination: WorkspaceDestination, showing route: WorkspaceSheet? = nil) {
        setSidebar(false)
        if destination == .settings { present(.settings); return }
        guard destination != selectedDestination else { if let route { present(route) }; return }
        if selectedDestination == .workbench && model.workbenchHasDraft {
            pendingDestination = destination; pendingDestinationSheet = route
            composing = false; confirmingWorkbenchExit = true; return
        }
        completeNavigation(destination, showing: route)
    }
    private func completeNavigation(_ destination: WorkspaceDestination, showing route: WorkspaceSheet? = nil) {
        if destination.pausesTaskOnEntry && (model.engine.running || model.voicePending) { model.pauseTask() }
        navigationForward = destination != .tasks; selectedDestination = destination; composing = false
        if let route { present(route) }
    }
    private var isConversationMode: Bool { selectedDestination.isConversation }
    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                if isConversationMode { composing = false; setSidebar(true) } else { navigate(.tasks) }
            } label: {
                Image(systemName: isConversationMode ? "line.3.horizontal" : "chevron.left")
                    .font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44)
                    .agentGlass(in: Circle(), interactive: true)
            }.buttonStyle(AgentPressStyle()).tint(.primary)
                .accessibilityLabel(isConversationMode ? "Open tasks and tools sidebar" : "Back to task")
            if !isConversationMode { Text(pageTitle).font(.headline).lineLimit(1) }
            Spacer(minLength: 8)
            if isConversationMode && CallController.credentialsAvailable {
                CallBarButton(call: model.call, action: openCall)
            }
            if !isConversationMode {
                Button { navigate(.settings) } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                    .tint(.primary).buttonStyle(AgentPressStyle()).accessibilityLabel("Settings")
            }
        }
        .overlay {
            if isConversationMode { modeSwitcher }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
    private var modeSwitcher: some View {
        Button { composing = false; modeSwitcherOpen.toggle() } label: {
            HStack(spacing: 6) {
                Text(selectedDestination == .assistant ? "Ask Assistant" : "Control Phone").font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(modeSwitcherOpen ? 180 : 0))
            }
            .padding(.horizontal, 10).frame(height: 44)
            .frame(maxWidth: max(92, min(184, viewportWidth - 216)))
            .agentGlass(in: Capsule(), interactive: true)
        }
        .tint(.primary).buttonStyle(AgentPressStyle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: modeSwitcherOpen)
        .accessibilityLabel("Switch mode, current: " + (selectedDestination == .assistant ? "Ask Assistant" : "Control Phone"))
        .popover(isPresented: $modeSwitcherOpen, arrowEdge: .top) {
            VStack(spacing: 4) {
                modeOption(title: "Control Phone", detail: "Run tasks and control the phone", icon: "computermouse", destination: .tasks)
                modeOption(title: "Ask Assistant", detail: model.engine.running || model.voicePending ? "Pause task and start chat" : "Ask questions and chat", icon: "bubble.left.and.bubble.right", destination: .assistant)
            }
            .padding(10).frame(width: min(320, max(240, viewportWidth - 40)))
            .presentationCompactAdaptation(.popover)

        }
    }
    private func modeOption(title: String, detail: String, icon: String, destination: WorkspaceDestination) -> some View {
        Button {
            modeSwitcherOpen = false
            navigate(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 19)).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if selectedDestination == destination { Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)) }
            }
            .foregroundStyle(.primary).padding(14).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(selectedDestination == destination ? AgentPalette.ink.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(AgentPressStyle()).accessibilityLabel(title + ", " + detail)
            .accessibilityAddTraits(selectedDestination == destination ? .isSelected : [])
    }
    private var pageTitle: String { selectedDestination.title }
    private var taskPage: some View {
        VStack(spacing: 0) {
            if let active = model.engine.currentRecord, model.engine.hasCurrentTask, !isCurrentConversation {
                Button { openConversation(active) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: model.engine.running ? "circle.dotted" : "pause.circle")
                        Text(active.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(active.outcome.label).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption2)
                    }.font(.caption).frame(minHeight: 44).padding(.horizontal, 14)
                        .background(AgentPalette.inset, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(AgentPressStyle()).padding(.horizontal, 20).padding(.bottom, 8)
            }
            if let record = displayedRecord { conversation(record) }
            else { draftCanvas }
        }
        .opacity(appeared ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : 6)
        .safeAreaBar(edge: .bottom, spacing: 0) { composerArea }
    }
    private var draftCanvas: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 32)
                    VStack(spacing: 14) {
                        AgentOrb(size: 56)
                        Text("What should your phone do?").font(.title2.weight(.semibold))
                        Text("Describe a goal and the assistant will control your phone.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                    Spacer(minLength: 32)
                    if !composing {
                        HStack(spacing: 10) {
                            suggestion("Open chats", icon: "bubble.left", text: "Open WhatsApp and show my chats without sending anything")
                            suggestion("Check battery", icon: "battery.75percent", text: "Open Settings and check battery usage")
                        }.transition(.opacity).padding(.bottom, 12)
                    }
                }.padding(.horizontal, 20).frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
            }.scrollDismissesKeyboard(.interactively).animation(pageAnimation, value: composing)
        }
    }
    private func suggestion(_ title: String, icon: String, text: String) -> some View {
        Button { model.goal = text; composing = true } label: {
            Label(title, systemImage: icon).font(.subheadline).frame(maxWidth: .infinity, minHeight: AgentInputMetrics.height)
                .agentGlass(in: AgentInputMetrics.shape, interactive: true)
        }.tint(.primary).buttonStyle(AgentPressStyle()).disabled(model.voiceMode != nil || reviewVoicePhase != nil)
    }
    private func promptCard(title: String, subtitle: String, icon: String, goal: String) -> some View {
        Button {
            model.goal = goal
            composing = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(AgentPalette.ink.opacity(0.08), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.left")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AgentPalette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(AgentPalette.ink.opacity(0.08), lineWidth: 0.5)
            }
        }
        .buttonStyle(AgentPressStyle())
        .accessibilityHint("Fills the input box; the task starts only after you confirm")
    }
    private func conversation(_ record: PhoneTaskRecord) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    userMessage(record.goal)

                    operationAccordion(record)

                    ForEach(record.amendments ?? []) { addition in
                        userMessage(addition.text)
                    }

                    taskResponse(record)

                    Color.clear.frame(height: 1).id("conversationBottom")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 80
            } action: { _, nearBottom in followLatest = nearBottom }
            .onAppear { reader.scrollTo("conversationBottom", anchor: .bottom) }
            .onChange(of: record.logs.last?.id) { _, _ in
                if followLatest { reader.scrollTo("conversationBottom", anchor: .bottom) }
            }
            .onChange(of: record.amendments?.last?.id) { _, _ in
                if followLatest { reader.scrollTo("conversationBottom", anchor: .bottom) }
            }
        }.id(record.id)
    }

    private func userMessage(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 36)
            Text(text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(AgentPalette.userBubble, in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AgentPalette.ink.opacity(0.08), lineWidth: 0.5)
                }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func operationAccordion(_ record: PhoneTaskRecord) -> some View {
        let activities = record.logs.filter { $0.title != "Addition" }
        guard !activities.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(pageAnimation) { expandedSteps.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isCurrentConversation && model.engine.running ? "gearshape.2.fill" : "list.bullet.rectangle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isCurrentConversation && model.engine.running ? Color.green : AgentPalette.ink)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Steps")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("\(activities.count)")
                                    .font(.caption2.monospacedDigit().weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(AgentPalette.ink.opacity(0.08), in: Capsule())
                            }
                            if !expandedSteps, let last = activities.last {
                                Text(last.title + (last.detail.isEmpty ? "" : " · " + last.detail))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        if isCurrentConversation && model.engine.running {
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text("Running").font(.caption2.weight(.medium)).foregroundStyle(.green)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.green.opacity(0.12), in: Capsule())
                        } else if record.outcome == .completed {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                Text("Done").font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(AgentPalette.ink.opacity(0.06), in: Capsule())
                        }

                        Image(systemName: expandedSteps ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AgentPressStyle())

                if expandedSteps {
                    VStack(alignment: .leading, spacing: 0) {
                        Divider().overlay(AgentPalette.ink.opacity(0.08)).padding(.horizontal, 14)

                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(activities.enumerated()), id: \.element.id) { index, entry in
                                HStack(alignment: .top, spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(index == activities.count - 1 && isCurrentConversation && model.engine.running ? AgentPalette.ink : AgentPalette.ink.opacity(0.12))
                                            .frame(width: 22, height: 22)
                                        Text("\(entry.step > 0 ? entry.step : index + 1)")
                                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                                            .foregroundStyle(index == activities.count - 1 && isCurrentConversation && model.engine.running ? AgentPalette.onContrast : AgentPalette.ink.opacity(0.8))
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if !entry.detail.isEmpty {
                                            Text(entry.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(14)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(AgentPalette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(AgentPalette.ink.opacity(0.09), lineWidth: 0.5)
            }
        )
    }

    private func taskResponse(_ record: PhoneTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: record.outcome == .completed ? "checkmark.circle.fill" : (record.outcome == .failed ? "exclamationmark.circle.fill" : "sparkles"))
                    .foregroundStyle(record.outcome == .completed ? Color.green : (record.outcome == .failed ? Color.red : AgentPalette.ink))
                    .font(.system(size: 16))
                Text(isCurrentConversation && model.engine.releasing ? "Stopping actions" : record.outcome.label)
                    .font(.subheadline.weight(.semibold))
            }

            Text(isCurrentConversation ? (model.engine.executingAction?.reason ?? model.engine.state) : record.summary)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)

            HStack(spacing: 16) {
                Button {
                    let content = isCurrentConversation ? (model.engine.executingAction?.reason ?? model.engine.state) : record.summary
                    UIPasteboard.general.string = content
                    model.notice = "Result copied"
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .accessibilityLabel("Copy task result")

                if !(isCurrentConversation && model.engine.hasCurrentTask) {
                    Button { reuseTask(record) } label: {
                        Label("Use as New Task", systemImage: "arrow.up.left")
                    }
                    .accessibilityLabel("Use this task as a new task draft")
                }

                ShareLink(item: record.summary) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Share task result")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .buttonStyle(AgentPressStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.top, 4)
    }

    private var taskControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.engine.phase == .awaitingApproval, model.engine.pendingAction != nil {
                Button("Confirm this step") { model.engine.approve() }
                    .buttonStyle(AgentButtonStyle()).disabled(model.engine.releasing)
            }
            controlButtons
        }
    }
    private var controlButtons: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if model.engine.running {
                taskControl("Pause", icon: "pause.fill") { model.pauseTask() }
                taskControl("Take Over", icon: "hand.raised.fill") { model.pauseTask(handoff: true) }
            } else if model.engine.canResume {
                taskControl("Resume", icon: "play.fill") { model.resumeAgent() }
                taskControl("Add Info", icon: "text.bubble.fill") { composing = true }
            }
            taskControl("Stop", icon: "stop.fill", destructive: true) { model.stop() }
        }.disabled(model.engine.releasing || model.voiceMode != nil).padding(.top, 2)
    }
    private func taskControl(_ title: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline.weight(.medium))
                .foregroundStyle(destructive ? Color.red : AgentPalette.ink)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(destructive ? Color.red.opacity(0.12) : AgentPalette.ink.opacity(0.08), in: Capsule())
                .overlay { Capsule().stroke(destructive ? Color.red.opacity(0.3) : AgentPalette.ink.opacity(0.12), lineWidth: 0.5) }
        }.buttonStyle(AgentPressStyle())
    }
    private var composerArea: some View {
        VStack(spacing: 8) {
            if isCurrentConversation && model.engine.hasCurrentTask { taskControls }
            if !model.notice.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.caption2)
                    Text(model.notice).font(.caption).lineLimit(2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .accessibilityLabel(model.notice)
            }
            if isCurrentConversation, !model.engine.error.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
                    Text(model.engine.error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
            }
            if preparationExpanded { readiness.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)) }

            HStack(spacing: 8) {
                Button { withAnimation(pageAnimation) { preparationExpanded.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.preparationReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(model.preparationReady ? Color.green : Color.orange)
                        Text(model.preparationReady ? "Ready" : "Setup")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                        Image(systemName: preparationExpanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .agentGlass(in: Capsule(), interactive: true)
                }
                .buttonStyle(AgentPressStyle())
                .accessibilityLabel(preparationExpanded ? "Collapse setup" : model.preparationReady ? "Ready, view setup" : "Expand setup")

                if model.taskQueue.pendingCount > 0 {
                    Button { navigate(.queue) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet").font(.system(size: 10))
                            Text("Queue \(model.taskQueue.pendingCount)").font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .agentGlass(in: Capsule(), interactive: true)
                    }
                    .buttonStyle(AgentPressStyle())
                    .accessibilityLabel("Task queue, \(model.taskQueue.pendingCount) pending")
                }

                Spacer(minLength: 4)

                if composingSupplement || queueingDraft {
                    Text(composingSupplement ? (model.engine.hasCurrentTask ? "Add Instructions" : "Make New Task") : "Add to Queue")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)

            composer
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.voiceMode != nil)
        }
        .agentComposerLeadingGlyph(recording: reviewVoicePhase != nil || (model.voiceMode != nil && model.voiceMode != .question))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var composer: some View {
        if let phase = reviewVoicePhase {
            InlineVoiceBar(phase: phase, transcript: phase == .preparing ? "" : "Open WhatsApp and show my chats.",
                           status: "On-device speech recognition", error: reviewVoiceError, startedAt: Date().addingTimeInterval(-8),
                           onCancel: { reviewVoicePhase = nil }, onFinish: { reviewVoicePhase = nil }, onRetry: {})
        } else if let mode = model.voiceMode, mode != .question {
            let requestID = model.voiceRequestID
            InlineDictationComposer(speech: model.speech, draft: voiceComposerText,
                                    isVisible: sheet == nil && !showCalibration && !sidebarOpen && !modeSwitcherOpen,
                                    isCurrent: { model.voiceMode == mode && model.voiceRequestID == requestID }) { text in
                guard model.voiceMode == mode, model.voiceRequestID == requestID else { return }
                dictatedDraft = text; model.voiceMode = nil
            }.id(requestID).transition(.opacity)
        } else { textComposer.transition(.opacity) }
    }
    private var textComposer: some View {
        HStack(alignment: .center, spacing: 8) {
            Menu {
                Button { navigate(.screenShare) } label: { Label("Share Screen", systemImage: "rectangle.on.rectangle") }
                Button { navigate(.device) } label: { Label("Device & Calibration", systemImage: "computermouse") }
                Button { present(.plan) } label: { Label("Build Checklist", systemImage: "list.number") }.disabled(busy || composingSupplement)
                Button { model.pip.enabled ? model.pip.close() : model.pip.open() } label: { Label("Action Picture-in-Picture", systemImage: "pip.enter") }
            } label: {
                AgentComposerLeadingSlot()
            }
            .tint(.primary).accessibilityLabel("Add task tools")

            TextField(composingSupplement ? "Add instructions…" : "Tell me what you want to do…", text: composerText,
                      prompt: Text(composingSupplement ? "Add instructions…" : "Tell me what you want to do…").foregroundStyle(AgentPalette.placeholder), axis: .vertical)
                .lineLimit(1...(typeSize.isAccessibilitySize ? 3 : 5))
                .font(.body)
                .focused($composing)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .accessibilityLabel(composingSupplement ? "Add instructions to the current task" : "New task")

            if !model.taskPlan.isEmpty && !composingSupplement {
                Button { present(.plan) } label: {
                    Text("Checklist \(model.taskPlan.count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(AgentPalette.ink.opacity(0.12), in: Capsule())
                }
                .buttonStyle(AgentPressStyle())
            }

            if composerText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    composing = false
                    model.beginVoice(composingSupplement ? .supplement : .task)
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(AgentPalette.ink.opacity(0.08), in: Circle())
                }
                .buttonStyle(AgentPressStyle())
                .disabled(inputBlocked)
                .accessibilityLabel(composingSupplement ? "Add instructions by voice" : "Dictate task")
                .transition(.opacity)
            } else {
                Button { submitComposer() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 44, height: 44)
                        .background(AgentPalette.accent, in: Circle())
                }
                .buttonStyle(AgentPressStyle())
                .disabled(inputBlocked)
                .accessibilityLabel(composingSupplement ? (model.engine.hasCurrentTask ? "Submit instructions and pause; continue after confirming" : "Turn instructions into a new task draft") : (queueingDraft ? "Add to task queue" : "Start task"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: AgentInputMetrics.height)
        .agentGlass(in: AgentInputMetrics.shape)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: composerText.wrappedValue.isEmpty)
    }
    private func configureAutomaticPiP(_ enabled: Bool) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-review") { return }
        #endif
        model.pip.setAutomaticOnExit(enabled)
    }
    private func submitComposer() {
        guard !inputBlocked else { return }
        composing = false
        let draft = composerText.wrappedValue
        if dictatedDraft == draft, let command = VoiceCommand.parse(draft) {
            composerText.wrappedValue = ""; dictatedDraft = nil
            voiceCommandTask?.cancel()
            voiceCommandTask = Task {
                let result = await model.handleVoiceCommand(command)
                guard !Task.isCancelled else { return }
                model.notice = result; voiceCommandTask = nil
            }
            return
        }
        dictatedDraft = nil
        if composingSupplement, let record = displayedRecord {
            let text = amendmentDrafts[record.id] ?? ""
            if model.engine.hasCurrentTask {
                let previousCount = record.amendments?.count ?? 0
                model.supplementTask(text)
                if (model.engine.currentRecord?.amendments?.count ?? 0) > previousCount { amendmentDrafts[record.id] = nil }
            } else {
                model.goal = text; amendmentDrafts[record.id] = nil; screen = .draft
                model.notice = "Your instructions were kept as a new task. Confirm to start."
            }
        } else { model.startAgent() }
    }
    private var readiness: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.modelReady ? "Connect your phone" : "Set up your first task").font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                Button("View All") { present(.preparation) }.font(.caption).frame(minHeight: 44)
            }
            HStack(spacing: 10) {
                setupItem("Screen", active: model.capture.frame?.fullDisplay == true && model.capture.running, icon: "rectangle.on.rectangle") { navigate(.screenShare) }
                setupItem("Mouse", active: model.ble.ready, icon: "computermouse") { navigate(.device) }
                setupItem("Calibrate", active: calibrated, icon: "scope") { navigate(.device) }
            }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }.padding(.horizontal, 6).padding(.bottom, 4)
    }
    private func setupItem(_ title: String, active: Bool, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) { Image(systemName: active ? "checkmark.circle" : icon); Text(title) }
                .font(.caption).frame(maxWidth: .infinity, minHeight: 64)
                .agentGlass(in: RoundedRectangle(cornerRadius: 20), interactive: !busy)
        }.buttonStyle(AgentPressStyle()).disabled(busy).opacity(busy ? 0.4 : 1)
            .accessibilityLabel("\(title): \(active ? "Ready" : "Tap to set up")")
    }
    private var sidebarOverlay: some View {
        GeometryReader { geometry in
            if sidebarOpen {
                ZStack(alignment: .leading) {
                    Button { setSidebar(false) } label: { sidebarScrimColor.ignoresSafeArea() }
                    .buttonStyle(.plain).accessibilityLabel("Close sidebar")
                    sidebar.frame(width: min(geometry.size.width * 0.77, 360), height: geometry.size.height)
                        .background(AgentPalette.background.ignoresSafeArea(.container, edges: .vertical))
                        .transition(reduceMotion ? .opacity : .move(edge: .leading))
                        .offset(x: reduceMotion ? 0 : sidebarDrag)
                        .gesture(DragGesture(minimumDistance: 12)
                            .updating($sidebarDrag) { value, state, _ in
                                if abs(value.translation.width) > abs(value.translation.height) { state = min(0, value.translation.width) }
                            }.onEnded { value in
                                if value.predictedEndTranslation.width < -80 { setSidebar(false) }
                            })
                }.transition(.opacity)
            }
        }
    }
    private var sidebar: some View {
        SidebarView(
            selectedDestination: selectedDestination,
            screen: screen,
            displayedRecord: displayedRecord,
            searchText: $searchText,
            sidebarSearchExpanded: $sidebarSearchExpanded,
            onNavigate: { navigate($0) },
            onTaskDetail: { present(.task($0)) },
            onPreparation: { setSidebar(false); present(.preparation) },
            onOpenConversation: openConversation,
            onNewConversation: {
                if selectedDestination == .assistant {
                    setSidebar(false)
                    newAssistantRequest = UUID()
                } else {
                    requestNewTask()
                }
            }
        )
    }
    private func setSidebar(_ open: Bool) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: open ? 0.28 : 0.20, bounce: 0)) { sidebarOpen = open }
    }
    private func openConversation(_ record: PhoneTaskRecord) {
        screen = .conversation(record.id); expandedSteps = false; followLatest = true
        navigate(.tasks); composing = false
    }
    private func requestNewTask() {
        setSidebar(false)
        if screen == .draft && !model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { discardingDraft = true }
        else {
            if model.goal == displayedRecord?.goal { model.goal = ""; model.removeTaskPlan() }
            screen = .draft; model.notice = ""; navigate(.tasks); composing = true
        }
    }
    private func resetDraft() {
        model.removeTaskPlan(); model.goal = ""; model.notice = ""; screen = .draft; navigate(.tasks); composing = true
    }
    private func reuseTask(_ record: PhoneTaskRecord) {
        // Keep an existing unsent task intact; reuse opens only an editable draft.
        if !model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.goal != record.effectiveGoal {
            screen = .draft; model.notice = "There is an unsent task in the input box. Handle the draft first."
        } else { model.goal = record.effectiveGoal; screen = .draft }
        composing = true
    }
    private func openCall() {
        composing = false; setSidebar(false); modeSwitcherOpen = false
        if !model.call.isActive { model.startCall() }
        var transaction = Transaction(); transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) { showCall = true }
    }
    private func beginCalibration() {
        let next = CalibrationModel(executor: model.executor)
        model.calibrating = true
        model.cancelCalibration = { [weak next] in next?.cancel() }
        next.onSaved = { model.objectWillChange.send() }
        calibration = next; showCalibration = true
    }
}
