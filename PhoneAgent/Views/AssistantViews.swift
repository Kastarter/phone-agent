import SwiftUI
import UIKit

enum DictationPhase { case preparing, listening, finalizing, idle }

// Shared by task and chat composers. Recording stays on the current canvas.
struct InlineVoiceBar: View {
    let phase: DictationPhase
    let transcript: String
    let status: String
    let error: String
    let startedAt: Date
    let onCancel: () -> Void
    let onFinish: () -> Void
    let onRetry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var working: Bool { phase == .preparing || phase == .finalizing }
    private var retry: Bool { phase == .idle && transcript.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !transcript.isEmpty {
                Text(transcript).font(.body).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .accessibilityLabel("Transcribing: " + transcript)
            }
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    AgentComposerLeadingSlot()
                }.buttonStyle(AgentPressStyle()).accessibilityLabel("Cancel dictation")
                VStack(alignment: .leading, spacing: 4) {
                    if phase == .listening {
                        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
                            let time = context.date.timeIntervalSince(startedAt)
                            HStack(spacing: 4) {
                                ForEach(0..<13, id: \.self) { index in
                                    Capsule().fill(AgentPalette.ink.opacity(0.86))
                                        .frame(width: 3, height: 22)
                                        .scaleEffect(x: 1, y: reduceMotion ? 0.5 : 0.2 + abs(sin(time * 3 + Double(index) * 0.8)) * 0.8)
                                }
                            }
                        }.accessibilityHidden(true)
                    } else {
                        HStack(spacing: 6) {
                            if working { ProgressView().controlSize(.mini) }
                            Text(phase == .finalizing ? "Transcribing…" : phase == .preparing ? "Preparing microphone…" : "Dictation stopped")
                                .font(.subheadline).lineLimit(1)
                        }
                    }
                    Text(error.isEmpty ? (phase == .listening ? "Listening" : status) : error)
                        .font(.caption2)
                        .foregroundStyle(error.isEmpty ? Color.secondary : Color.red)
                        .lineLimit(error.isEmpty ? 1 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if phase == .listening {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.accessibilityHidden(true)
                }
                Button(action: retry ? onRetry : onFinish) {
                    Image(systemName: retry ? "mic.fill" : "checkmark")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(AgentPalette.onContrast)
                        .frame(width: 44, height: 44).background(AgentPalette.ink, in: Circle())
                }.buttonStyle(AgentPressStyle()).disabled(working).opacity(working ? 0.4 : 1)
                    .accessibilityLabel(retry ? "Restart dictation" : "Finish dictation and insert text")
            }
            .foregroundStyle(.primary).padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minHeight: AgentInputMetrics.height)
            .agentGlass(in: AgentInputMetrics.shape)
        }
    }
}

@MainActor
struct InlineDictationComposer: View {
    @ObservedObject var speech: VoiceController
    @Binding var draft: String
    let isCurrent: () -> Bool
    let isVisible: Bool
    let onEnd: (String?) -> Void
    @Environment(\.scenePhase) private var appPhase
    @State private var originalDraft: String
    @State private var awaitingStart = true
    @State private var hasBeenVisible = false
    @State private var startedAt = Date()
    @State private var resolved = false
    @State private var active = true
    @State private var finishTask: Task<Void, Never>?
    init(speech: VoiceController, draft: Binding<String>, isVisible: Bool, isCurrent: @escaping () -> Bool, onEnd: @escaping (String?) -> Void) {
        _speech = ObservedObject(wrappedValue: speech); _draft = draft
        _originalDraft = State(initialValue: draft.wrappedValue)
        self.isVisible = isVisible; self.isCurrent = isCurrent; self.onEnd = onEnd
    }
    private var phase: DictationPhase {
        if awaitingStart { return .preparing }
        if speech.preparing { return .preparing }
        if speech.finalizing { return .finalizing }
        if speech.listening { return .listening }
        return .idle
    }
    var body: some View {
        InlineVoiceBar(phase: phase, transcript: awaitingStart ? "" : speech.transcript, status: awaitingStart ? "On-device speech recognition" : speech.status,
                       error: awaitingStart ? "" : speech.error, startedAt: startedAt,
                       onCancel: cancel, onFinish: finish, onRetry: retry)
            .task(id: isVisible && appPhase == .active) {
                guard isVisible, appPhase == .active, awaitingStart else { return }
                hasBeenVisible = true
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-review") { return }
                #endif
                // Siri can still own the audio route when it hands the task to the app.
                let deadline = Date().addingTimeInterval(6)
                while UIApplication.shared.applicationState != .active && Date() < deadline {
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard !Task.isCancelled, active, isCurrent(), UIApplication.shared.applicationState == .active else { return }
                guard isVisible else { retainPartialAndClose(); return }
                awaitingStart = false; startedAt = Date(); speech.start()
            }
            .onChange(of: speech.listening) { _, listening in if listening { startedAt = Date() } }
            .onChange(of: isVisible) { _, visible in if !visible && hasBeenVisible { retainPartialAndClose() } }
            .onChange(of: appPhase) { _, phase in if phase == .background { retainPartialAndClose() } }
            .onDisappear {
                active = false; finishTask?.cancel(); finishTask = nil
                guard isCurrent() else { return }
                if !resolved { retainPartialAndClose() }
                speech.onSilence = nil; speech.cancel()
            }
    }
    private func retry() {
        guard active, !resolved, isCurrent(), isVisible else { return }
        startedAt = Date(); speech.start()
    }
    private func cancel() {
        guard isCurrent() else { return }
        resolved = true; finishTask?.cancel(); finishTask = nil
        speech.onSilence = nil; speech.cancel(); onEnd(nil)
    }
    private func finish() {
        guard finishTask == nil, !awaitingStart, !speech.preparing, !speech.finalizing, isCurrent() else { return }
        finishTask = Task {
            await speech.finish()
            guard !Task.isCancelled, active, isCurrent() else { return }
            let value = Self.appending(speech.transcript, to: originalDraft)
            resolved = true; draft = value; finishTask = nil
            speech.onSilence = nil; speech.cancel(); onEnd(value)
        }
    }
    private func retainPartialAndClose() {
        guard !resolved, isCurrent() else { return }
        resolved = true; finishTask?.cancel(); finishTask = nil
        let value = awaitingStart ? originalDraft : Self.appending(speech.transcript, to: originalDraft)
        draft = value; speech.onSilence = nil; speech.cancel(); onEnd(value)
    }
    static func appending(_ transcript: String, to draft: String) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return draft }
        return draft.isEmpty ? text : draft + (draft.last?.isWhitespace == true ? "" : "\n") + text
    }
}

struct AssistantView: View {
    let newConversationRequest: UUID
    let reviewDictation: DictationPhase?
    let allowsDictation: Bool
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    let onModelSetup: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followingConversation = true
    @State private var lastSpokenMessage: UUID?
    @State private var useCamera = false
    @State private var memoryEditor: MemoryEditorSeed?
    @State private var continuous = false
    @State private var dictating = false
    @State private var dictationID = UUID()
    @State private var videoMode = false
    @State private var observationFocus = ""
    @State private var observationInterval: Double = 15
    @State private var speakObservations = false
    @State private var videoQuestionTask: Task<Void, Never>?
    @State private var videoQuestionID = UUID()
    @State private var clear = false
    @State private var realtime = false
    @State private var webSearch = false
    @State private var transcriptTask: Task<Void, Never>?
    @FocusState private var composing: Bool
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if useCamera {
                        if let frame = model.camera.frame { Image(uiImage: frame.image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 18)) }
                        else if model.camera.preparing { ProgressView("Preparing camera") }
                        Toggle("Continuous Video Watch", isOn: $videoMode).tint(AgentPalette.accent)
                        if videoMode { videoObservationPanel }
                        else { Text("Sends one camera frame when you ask. No audio or video stream is uploaded; the camera turns off when you leave this page.") .font(.caption).foregroundStyle(.secondary) }
                        if !model.camera.error.isEmpty { AgentNotice(text: model.camera.error, error: true) }
                    }
                    if let frame = model.conversation.selectedFrame, !useCamera {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(uiImage: frame.image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            HStack {
                                Text("Selected frame · \(frame.capturedAt.formatted(date: .omitted, time: .standard))").font(.caption)
                                Button("Save Memory") { memoryEditor = MemoryEditorSeed(value: AssistantMemory(title: "Screen Memory", text: "", kind: .screen, source: "Full-screen share · " + frame.capturedAt.formatted()), image: frame.image) }.font(.caption).frame(minHeight: 44)
                                Spacer(); Button("Remove") { model.conversation.selectFrame(nil) }.font(.caption).frame(minHeight: 44)
                            }.foregroundStyle(.secondary)
                            Text("This frame is attached when you send a question. Select again after switching pages.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.agentPanel()
                    }
                    if model.conversation.messages.isEmpty {
                        VStack(spacing: 16) {
                            AgentOrb(size: 72)
                            Text("What would you like to ask?").font(.title2.weight(.bold))
                            Text("Ask the assistant, or attach a screen frame or camera view.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 80)
                    }
                    ForEach(model.conversation.messages) { message in
                        HStack(alignment: .top) {
                            if message.role == "user" { Spacer(minLength: 36) }
                            VStack(alignment: .leading, spacing: 10) {
                                if message.role != "user" {
                                    HStack(spacing: 6) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 13))
                                            .foregroundStyle(AgentPalette.ink)
                                        Text("Assistant")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(message.text).font(.body).lineSpacing(4).textSelection(.enabled)
                                if let frames = message.cameraFrames {
                                    Text("Camera sequence · \(frames) frames · \(Int((message.cameraDuration ?? 0).rounded())) s")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if message.role == "assistant" {
                                    HStack(spacing: 16) {
                                        Button { model.speech.speak(message.text) } label: { Label("Read Aloud", systemImage: "speaker.wave.2") }
                                        Button {
                                            UIPasteboard.general.string = message.text
                                            model.notice = "Answer copied"
                                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                                        Button { memoryEditor = MemoryEditorSeed(value: AssistantMemory(title: String(message.text.prefix(30)), text: message.text, source: "Chat answer · " + message.createdAt.formatted())) } label: { Label("Save as Memory", systemImage: "bookmark") }
                                        ShareLink(item: message.text) { Label("Share", systemImage: "square.and.arrow.up") }
                                    }.font(.caption).foregroundStyle(.secondary).labelStyle(.iconOnly).frame(minHeight: 44).buttonStyle(AgentPressStyle())
                                }
                            }
                            .padding(message.role == "user" ? 14 : 16)
                            .background(message.role == "user" ? AgentPalette.userBubble : Color.clear, in: RoundedRectangle(cornerRadius: 20))

                            if message.role != "user" { Spacer(minLength: 0) }
                        }.frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading).id(message.id)
                    }
                    if model.conversation.loading { HStack { ProgressView(); Text("Thinking…").foregroundStyle(.secondary); Spacer(); Button("Cancel") { stopVoice(); model.liveCamera.stop(); model.conversation.cancel() } }.font(.subheadline) }
                    if !model.conversation.error.isEmpty { AgentNotice(text: model.conversation.error, error: true) }
                    if !model.notice.isEmpty { AgentNotice(text: model.notice) }
                    if model.speech.usingAudio && !dictating { Text(model.speech.status).font(.footnote).foregroundStyle(.secondary) }
                    if !model.speech.error.isEmpty && !dictating { AgentNotice(text: model.speech.error, error: true) }
                    if continuous { Text("Tap the mic to start. After you pause, the text is sent automatically; it listens again once the reply finishes. Stops when you leave this page or the app.")
                        .font(.caption).foregroundStyle(.secondary) }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 80
                } action: { _, nearBottom in followingConversation = nearBottom }
                .onChange(of: model.conversation.messages.count) { _, _ in
                    if followingConversation { reader.scrollTo("bottom", anchor: .bottom) }
                }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if continuous {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "waveform")
                            Text("Continuous Voice")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }.padding(.horizontal, 10)
                }

                if let phase = reviewDictation {
                    InlineVoiceBar(phase: phase, transcript: phase == .preparing ? "" : "Summarize this screen for me.",
                                   status: "On-device speech recognition", error: "", startedAt: Date().addingTimeInterval(-8),
                                   onCancel: {}, onFinish: {}, onRetry: {})
                } else if dictating {
                    let token = dictationID
                    InlineDictationComposer(speech: model.speech, draft: $model.conversation.draft,
                                            isVisible: allowsDictation && !clear && !realtime && !webSearch && memoryEditor == nil,
                                            isCurrent: { dictating && dictationID == token }) { _ in
                        guard dictationID == token else { return }
                        dictating = false
                        if model.voiceMode == .question { model.voiceMode = nil }
                    }.id(token).transition(.opacity)
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        Menu {
                            Button { selectScreen() } label: { Label("Attach Shared Screen", systemImage: "viewfinder") }
                            Toggle(isOn: $useCamera) { Label("Camera Chat", systemImage: "camera") }
                            Toggle(isOn: $continuous) { Label("Continuous Voice Chat", systemImage: "waveform") }
                            Divider()
                            Button {
                                composing = false; stopVoice(); stopVideo(); model.camera.stop(); useCamera = false; continuous = false
                                model.conversation.cancel(); webSearch = true
                            } label: { Label("Web Search", systemImage: "globe") }
                            Button {
                                composing = false; stopVoice(); stopVideo(); model.camera.stop(); useCamera = false; continuous = false
                                model.conversation.cancel(); realtime = true
                            } label: { Label("Realtime Voice and Camera", systemImage: "waveform") }
                            Divider()
                            Button(role: .destructive) { clear = true } label: { Label("Clear Chat", systemImage: "trash") }
                                .disabled(model.conversation.messages.isEmpty)
                        } label: {
                            AgentComposerLeadingSlot()
                        }
                        .tint(.primary).accessibilityLabel("Chat tools")

                        TextField("Ask a question…", text: $model.conversation.draft, prompt: Text("Ask a question…").foregroundStyle(AgentPalette.placeholder), axis: .vertical)
                            .lineLimit(1...5)
                            .font(.body)
                            .focused($composing)
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .disabled(model.conversation.loading || videoQuestionTask != nil || model.speech.preparing || model.speech.finalizing || model.speech.listening)
                            .accessibilityLabel("Ask the assistant")

                        if model.conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.conversation.loading && videoQuestionTask == nil {
                            Button {
                                if model.speech.usingAudio { stopVoice() } else { startListening() }
                            } label: {
                                Image(systemName: model.speech.listening ? "waveform" : "mic.fill")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundStyle(.primary)
                                    .frame(width: 44, height: 44)
                                    .background(AgentPalette.ink.opacity(0.08), in: Circle())
                            }
                            .buttonStyle(AgentPressStyle())
                            .accessibilityLabel(model.speech.usingAudio ? "End voice" : "Ask by voice")
                            .transition(.opacity)
                        } else {
                            Button {
                                if model.conversation.loading || videoQuestionTask != nil { stopVoice(); stopVideo(); model.conversation.cancel() }
                                else { send() }
                            } label: {
                                Image(systemName: model.conversation.loading || videoQuestionTask != nil ? "stop.fill" : "arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Color.white)
                                    .frame(width: 44, height: 44)
                                    .background(AgentPalette.accent, in: Circle())
                            }
                            .buttonStyle(AgentPressStyle())
                            .accessibilityLabel(model.conversation.loading || videoQuestionTask != nil ? "Stop generating" : "Send question")
                            .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: AgentInputMetrics.height)
                    .agentGlass(in: AgentInputMetrics.shape)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.conversation.draft.isEmpty)
                }
            }
            .agentComposerLeadingGlyph(recording: reviewDictation != nil || dictating)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: dictating)
        }
        .sheet(item: $memoryEditor) { MemoryEditor(seed: $0) }
        .sheet(isPresented: $realtime) { RealtimeView() }
        .sheet(isPresented: $webSearch) { WebSearchView() }
        .confirmationDialog("Clear this chat?", isPresented: $clear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { resetConversation() }
        }
        .onChange(of: newConversationRequest) { _, _ in requestNewConversation() }
        .onAppear { if model.voiceMode == .question { startListening() } }
        .onChange(of: model.voiceMode) { _, mode in if mode == .question { startListening() } }
        .onChange(of: model.conversation.messages.last?.id) { _, _ in
            guard let last = model.conversation.messages.last, last.role == "assistant", !model.conversation.loading, lastSpokenMessage != last.id, model.voiceMode == nil else { return }
            lastSpokenMessage = last.id
            if continuous || model.settings.spokenFeedback == true {
                model.speech.speak(last.text) { if continuous && phase == .active { startListening() } }
            }
        }
        .onChange(of: useCamera) { _, enabled in
            stopVideo(); model.conversation.cancel(); model.conversation.selectFrame(nil)
            if enabled { model.camera.start(); model.camera.setSequenceEnabled(videoMode) } else { videoMode = false; model.camera.stop() }
        }
        .onChange(of: videoMode) { _, enabled in stopVideo(); model.conversation.cancel(); model.conversation.selectFrame(nil); model.camera.setSequenceEnabled(enabled && useCamera) }
        .onChange(of: model.camera.running) { _, running in if !running { stopVideo() } }
        .onChange(of: model.conversation.loading) { _, loading in
            if !loading, model.liveCamera.running, model.liveCamera.suspended {
                if model.conversation.error.isEmpty && phase == .active && videoMode && useCamera { startVideo() }
                else { model.liveCamera.stop() }
            }
        }
        .onChange(of: model.liveCamera.results.last?.id) { _, _ in
            if speakObservations, phase == .active, !model.speech.usingAudio, !model.conversation.loading, let result = model.liveCamera.results.last { model.speech.speak(result.text) }
        }
        .onChange(of: continuous) { _, enabled in if !enabled { stopVoice() } }
        .onChange(of: phase) { _, value in if value == .background { continuous = false; useCamera = false; stopVideo(); model.camera.stop(); model.conversation.cancel(); model.conversation.selectFrame(nil); stopVoice() } }
        .onDisappear { continuous = false; useCamera = false; stopVideo(); model.camera.stop(); stopVoice(); model.conversation.cancel(); model.conversation.selectFrame(nil) }
    }
    private var videoObservationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("What to watch for, e.g. how this object changes", text: $observationFocus, axis: .vertical).lineLimit(1...3).agentField()
                .accessibilityLabel("Continuous watch focus").disabled(model.liveCamera.running)
            Picker("Watch interval", selection: $observationInterval) { Text("15 s").tag(15.0); Text("30 s").tag(30.0); Text("60 s").tag(60.0) }
                .pickerStyle(.segmented).disabled(model.liveCamera.running)
            Text("When on, it periodically sends up to 8 sampled frames from the last 12 seconds to analyze changes. Questions take priority, then watching resumes. Auto-watch runs up to 10 minutes or 40 rounds; multiple frames increase model usage, and fast changes may be missed.")
                .font(.caption).foregroundStyle(.secondary)
            Button { if model.liveCamera.running { stopVideo() } else { startVideo() } } label: {
                Label(model.liveCamera.running ? "Stop Watching" : "Start Watching", systemImage: model.liveCamera.running ? "stop.fill" : "video.fill")
            }.buttonStyle(AgentButtonStyle(primary: !model.liveCamera.running)).disabled(!model.liveCamera.running && (model.conversation.loading || videoQuestionTask != nil))
            Text(model.liveCamera.state).font(.footnote).foregroundStyle(.secondary)
            if model.liveCamera.loading { ProgressView("Analyzing changes") }
            if !model.liveCamera.error.isEmpty { AgentNotice(text: model.liveCamera.error, error: true) }
            if let result = model.liveCamera.results.last {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Latest watch · \(result.through.formatted(date: .omitted, time: .standard)) · \(result.frames) frames").font(.caption).foregroundStyle(.secondary)
                    Text(result.text).textSelection(.enabled)
                    Button("Save Watch Memory") { memoryEditor = MemoryEditorSeed(value: AssistantMemory(title: String(result.text.prefix(30)), text: result.text, source: "Camera sampled watch · " + result.through.formatted())) }.font(.caption).frame(minHeight: 44)
                }.agentPanel()
            }
            Toggle("Read results aloud when idle", isOn: $speakObservations).tint(AgentPalette.accent)
            Text("Requires a model API that supports multiple images. Voice questions use on-device transcription and send no audio. In this mode, say “pause”, “stop”, or “continue” to control watching. Turning the mode off clears the sampled frames.") .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func requestNewConversation() {
        let conversation = model.conversation
        let hasContent = dictating || !conversation.messages.isEmpty || !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || conversation.selectedFrame != nil || useCamera || model.liveCamera.running
        if hasContent { clear = true }
        else { resetConversation(); composing = true }
    }
    private func resetConversation() {
        stopVoice(); stopVideo(); model.liveCamera.stop(clearResults: true); model.camera.stop()
        useCamera = false; continuous = false
        model.conversation.clear()
    }
    private func startVideo() {
        guard model.modelReady else { model.notice = "Connect a model service that supports multiple images first"; onModelSetup(); return }
        guard model.consentReady else { model.requestConsent(); return }
        guard videoMode, useCamera, phase == .active else { return }
        model.liveCamera.start(settings: model.settings, apiKey: SettingsStore.apiKey(for: model.settings.endpoint), focus: observationFocus,
                               interval: observationInterval, camera: model.camera, currentConfiguration: { [weak model] in model?.settings ?? AgentSettings() })
    }
    private func stopVideo() { videoQuestionID = UUID(); videoQuestionTask?.cancel(); videoQuestionTask = nil; model.liveCamera.stop() }
    private func selectScreen() {
        guard model.capture.running else { model.notice = "Turn on full-screen sharing first, switch to the page you want to ask about, then come back"; return }
        guard let frame = model.capture.lastBackgroundFrame ?? model.capture.frame, frame.fullDisplay else { model.notice = "No full-screen frame available"; return }
        model.conversation.selectFrame(frame); model.notice = ""
    }
    private func startListening() {
        guard !dictating, model.recordingAudioOwner == nil, !model.conversation.loading, videoQuestionTask == nil else { return }
        composing = false; model.speech.cancel()
        model.speech.onSilence = continuous ? { finishAndSend() } : nil
        dictationID = UUID(); dictating = true
    }
    private func stopVoice() {
        if dictating && (model.speech.listening || model.speech.finalizing) {
            model.conversation.draft = InlineDictationComposer.appending(model.speech.transcript, to: model.conversation.draft)
        }
        dictationID = UUID(); dictating = false
        transcriptTask?.cancel(); transcriptTask = nil; model.speech.onSilence = nil; model.speech.cancel()
        if model.voiceMode == .question { model.voiceMode = nil }
    }
    private func finishAndSend() {
        guard transcriptTask == nil else { return }
        transcriptTask = Task {
            await model.speech.finish()
            guard !Task.isCancelled, phase == .active else { transcriptTask = nil; return }
            model.conversation.draft = model.speech.transcript
            dictationID = UUID(); dictating = false
            if model.voiceMode == .question { model.voiceMode = nil }
            transcriptTask = nil; send()
        }
    }
    private func send() {
        composing = false
        if model.speech.listening { finishAndSend(); return }
        let value = model.conversation.draft
        if let command = VoiceCommand.parse(value) {
            stopVoice(); model.conversation.draft = ""
            if videoMode && useCamera {
                if [.pause, .stop, .handoff].contains(command) { stopVideo(); model.notice = "Continuous watch stopped"; if command == .stop { useCamera = false; model.camera.stop() }; return }
                if command == .resume { startVideo(); return }
            }
            Task { model.notice = await model.handleVoiceCommand(command) }
            return
        }
        guard model.modelReady else { stopVoice(); model.notice = "Connect a model service first"; onModelSetup(); return }
        guard model.consentReady else { stopVoice(); model.requestConsent(); return }
        if useCamera {
            if videoMode {
                guard videoQuestionTask == nil else { return }
                let token = UUID(); videoQuestionID = token
                let configuration = model.settings
                videoQuestionTask = Task {
                    defer { if videoQuestionID == token { videoQuestionTask = nil } }
                    await model.liveCamera.suspendForQuestion()
                    guard !Task.isCancelled, videoQuestionID == token, phase == .active, videoMode, useCamera,
                          model.camera.running else { return }
                    guard model.conversation.draft == value else { model.notice = "The question changed; send it again"; model.liveCamera.stop(); return }
                    guard model.settings.endpoint == configuration.endpoint, model.settings.model == configuration.model,
                          PrivacyConsent.recipient(model.settings) == PrivacyConsent.recipient(configuration),
                          PrivacyConsent.allowed(model.settings) else { model.notice = "The model or permission changed; ask again"; model.liveCamera.stop(); return }
                    let frames = model.camera.sequence()
                    do { _ = try CameraObservationWindow.content(question: value, frames: frames, now: ProcessInfo.processInfo.systemUptime) }
                    catch { model.notice = error.localizedDescription; model.liveCamera.stop(); return }
                    model.conversation.selectSequence(frames)
                    if !model.conversation.send(settings: configuration, apiKey: SettingsStore.apiKey(for: configuration.endpoint), memories: model.memories,
                                                observationContext: model.liveCamera.results.last?.text ?? "") { model.liveCamera.stop() }
                }
                return
            }
            guard let frame = model.camera.frame, Date().timeIntervalSince(frame.capturedAt) < 2 else { model.notice = "No new camera frame. Check permissions or turn off camera mode and retry"; return }
            model.conversation.selectFrame(frame)
        }
        model.conversation.send(settings: model.settings, apiKey: SettingsStore.apiKey(for: model.settings.endpoint), memories: model.memories)
    }
}
