import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

private struct RealtimeApproval: Identifiable { let id = UUID(); let settings: RealtimeSettings; let camera: Bool }
struct RealtimeView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    private enum Field: Hashable { case provider, endpoint, model, voice, key }
    @FocusState private var focusedField: Field?
    @StateObject private var session = RealtimeSession()
    @StateObject private var camera = CameraService()
    @State private var settings = RealtimeStore.load()
    @State private var saved = RealtimeStore.load()
    @State private var key = ""
    @State private var savedKey = ""
    @State private var shareCamera = false
    @State private var approval: RealtimeApproval?
    @State private var error = ""
    @State private var message = ""
    @State private var showSettings = false
    @State private var document: ArtifactDocument?
    @State private var exporting = false
    private enum DiscardAction { case close, restart }
    @State private var discardAction = DiscardAction.close
    @State private var confirmingDiscard = false
    @State private var exportedReplies: [String] = []
    @State private var exportSnapshot: [String]?
    private var replySnapshot: [String] { session.transcripts.map { $0.id + "\u{0}" + $0.text } }
    private var configurationChanged: Bool { settings != saved || key != savedKey }
    private var repliesChanged: Bool { !session.transcripts.isEmpty && replySnapshot != exportedReplies }
    private var hasChanges: Bool { configurationChanged || repliesChanged }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 12) {
                        AgentOrb(size: 104, active: session.mode == .live, idleIcon: "waveform")
                        Text(session.status).font(.title2.weight(.semibold))
                        Text("Ask with your voice and interrupt replies anytime.") .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 18)
                    DisclosureGroup("Realtime Service Setup", isExpanded: $showSettings) {
                        VStack(alignment: .leading, spacing: 14) {
                            field("Provider Name") {
                                TextField("Enter the realtime provider", text: $settings.provider).agentField().accessibilityLabel("Realtime provider").focused($focusedField, equals: .provider)
                            }
                            field("WebSocket Endpoint") {
                                TextField("wss://…/v1/realtime", text: $settings.endpoint, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).agentField().accessibilityLabel("Realtime WebSocket URL").focused($focusedField, equals: .endpoint)
                            }
                            field("Realtime Model ID") {
                                TextField("Enter the provider's realtime model ID", text: $settings.model).textInputAutocapitalization(.never).autocorrectionDisabled().agentField().accessibilityLabel("Realtime model").focused($focusedField, equals: .model)
                            }
                            field("Voice Name") {
                                TextField("Enter a voice the provider supports", text: $settings.voice).textInputAutocapitalization(.never).autocorrectionDisabled().agentField().accessibilityLabel("Realtime voice").focused($focusedField, equals: .voice)
                            }
                            field("Separate API Key") {
                                SecureField("Paste realtime service API key", text: $key).textContentType(.oneTimeCode).textInputAutocapitalization(.never).autocorrectionDisabled().agentField().accessibilityLabel("Realtime service's own API key").focused($focusedField, equals: .key)
                            }
                            Button("Save Realtime Setup") { focusedField = nil; save() }.buttonStyle(AgentButtonStyle(primary: false))
                            Text("Don't include /chat/completions or query parameters; the app adds the model parameter itself. This key is separate from the text model and search keys and is bound to this realtime URL. Your task model is not changed. Enter model and voice names as listed in the service's docs.") .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }.disabled(session.busy)
                    Toggle("Allow Manual Camera Frames This Time", isOn: $shareCamera).disabled(session.busy)
                    Text("The camera never sends images automatically. Once connected, you choose and send the current frame, up to 20 frames. These are timestamped still images, not a video stream.") .font(.caption).foregroundStyle(.secondary)
                    if session.busy { Text("\(session.seconds) s / 5 min max · \(session.cameraShares)/20 frames shared").font(.caption).foregroundStyle(.secondary) }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if !session.error.isEmpty { AgentNotice(text: session.error, error: true) }
                    if !message.isEmpty { AgentNotice(text: message) }
                    if session.mode == .live && shareCamera {
                        if let frame = camera.frame { Image(uiImage: frame.image).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 18)) }
                        if camera.running {
                            Button("Add This Frame to Next Question") {
                                guard let frame = camera.sequence().last else { error = "Wait for a new camera frame"; return }; session.share(jpeg: frame.jpeg, capturedAt: frame.capturedAt)
                            }.buttonStyle(AgentButtonStyle(primary: false)).disabled(session.cameraShares >= 20)
                        } else { Button("Start Camera Preview") { camera.start(); camera.setSequenceEnabled(true) }.frame(minHeight: 44).disabled(camera.preparing) }
                        Button("Stop Camera Preview") { camera.stop() }.frame(minHeight: 44)
                        if !camera.error.isEmpty { AgentNotice(text: camera.error, error: true) }
                    }
                    ForEach(session.transcripts) { entry in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Assistant Reply Text").font(.caption).foregroundStyle(.secondary)
                            Text(entry.text).textSelection(.enabled)
                        }.agentPanel()
                    }
                    if !session.transcripts.isEmpty {
                        Button("Export Replies as TXT") {
                            let text = "Realtime service: \(saved.provider)\n\(saved.endpoint)\nModel: \(saved.model)\nReply text from the service; may include parts that were not played. This is not a verified transcript of the recording. Raw audio and camera images are not saved.\n\n" + session.transcripts.map(\.text).joined(separator: "\n\n")
                            focusedField = nil; exportSnapshot = replySnapshot
                            document = ArtifactDocument(data: Data(text.utf8)); exporting = true
                        }.disabled(session.busy).frame(minHeight: 44)
                    }
                    AgentHelp(title: "How It Runs and Your Data", text: "Runs only in the foreground and ends when you leave the page, go to the background, a system interruption occurs, the setup changes, or the connection backs up. It doesn't reconnect automatically. Audio and camera frames are never written to disk; reply text stays in this page's memory and is saved only if you export it. The service may charge for and retain audio and images, so check its policies. This mode doesn't perform phone actions and has no global wake word.")
                }.padding(20)
            }.safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if !session.busy {
                        Button("Review and Start Realtime Chat") {
                            focusedField = nil; requestStart()
                        }.buttonStyle(AgentButtonStyle()).disabled(!canStart)
                        if !canStart { Text("Enter and save a valid realtime setup and separate API key to start.") .font(.caption).foregroundStyle(.secondary) }
                    } else {
                        HStack(spacing: 12) {
                            Button("End Chat") { session.stop(); camera.stop() }.buttonStyle(AgentButtonStyle())
                            Button("Interrupt") { session.interruptReply() }.buttonStyle(AgentButtonStyle(primary: false)).disabled(session.mode != .live)
                        }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12).background(AgentPalette.background)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("Realtime Voice").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { requestClose() } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide Keyboard") { focusedField = nil } }
            }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .interactiveDismissDisabled(hasChanges || session.busy || exporting)
            .alert(discardAction == .close ? "Discard unsaved realtime setup or replies?" : "Start a new realtime chat?", isPresented: $confirmingDiscard) {
                Button("Stay on This Page", role: .cancel) { }
                Button(discardAction == .close ? "Discard and Exit" : "Replace Previous Replies", role: .destructive) {
                    if discardAction == .close { close() } else { prepareApproval() }
                }
            } message: {
                Text(discardAction == .close ? "Unsaved setup, key drafts, and unexported replies will be lost. Any realtime chat in progress has already stopped; you can stay to save the setup or export replies." : "Starting will replace the previous replies with the new session. Cancel to export them first.")
            }
            .onAppear {
                saved = RealtimeStore.load(); settings = saved; savedKey = RealtimeStore.key(for: saved); key = savedKey
                session.reserve = model.reserveRecordingAudio; session.release = model.releaseRecordingAudio
                session.prepareAudio = { try await model.pip.suspendForVoice() }
                session.permission = { await AVAudioApplication.requestRecordPermission() }
                session.authorized = { phase == .active && settings == saved && saved == RealtimeStore.load() && key == savedKey && !savedKey.isEmpty }
                session.makeAudio = { RealtimeAudio() }
            }
            .onChange(of: phase) { _, value in if value == .background || (value != .active && session.mode == .live) { approval = nil; session.stop(); camera.stop() } }
            .onChange(of: session.mode) { _, value in if value == .idle { camera.stop() } }
            .onChange(of: settings) { _, _ in approval = nil; if session.busy { session.stop(); camera.stop() } }
            .onChange(of: key) { _, _ in approval = nil; if session.busy { session.stop(); camera.stop() } }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in if session.busy { session.stop(reason: "System audio was interrupted; chat ended"); camera.stop() } }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in session.stop(); camera.stop() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
                if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, reason != AVAudioSession.RouteChangeReason.categoryChange.rawValue, session.mode == .live { session.stop(reason: "Audio route changed; chat ended"); camera.stop() }
            }
            .onDisappear { session.stop(); camera.stop(); approval = nil; document = nil; exportSnapshot = nil }
            .sheet(item: $approval) { value in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Confirm Sending Live Audio").font(.title.bold())
                            Text("Recipient: \(value.settings.provider)\n\(value.settings.endpoint)\nModel: \(value.settings.model) · Voice: \(value.settings.voice)").font(.footnote).textSelection(.enabled)
                            Text("Once started, raw microphone audio is streamed continuously to this realtime endpoint, and the service replies with audio. Up to 5 minutes; this is not on-device transcription. Nearby voices may be captured too, so choose a suitable place. Each session may be billed.")
                            Text(value.camera ? "This session also allows manually sharing up to 20 new camera frames with timestamps. You must start the preview, and you tap to send each frame. Nothing is sent automatically and no raw video stream is uploaded." : "No camera images will be sent this session.")
                            Text("The separate realtime key goes only to this endpoint; no text model or search keys, screenshots, tasks, chat history, or local memory are sent. Audio and images aren't saved on this device, but the service's retention, forwarding, and deletion depend on its policies. Ending the session can't recall data already sent.") .font(.footnote).foregroundStyle(.secondary)
                            Button("Agree and Start Session") {
                                guard settings == value.settings, saved == value.settings, shareCamera == value.camera, key == savedKey, phase == .active else { error = "Setup or page changed; please review again"; approval = nil; return }
                                approval = nil; session.start(settings: value.settings, key: savedKey, includeCamera: value.camera)
                                if session.busy { exportedReplies = [] }
                            }.buttonStyle(AgentButtonStyle())
                        }.padding(20)
                    }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { approval = nil } } }
                }.tint(AgentPalette.accent).agentSheetStyle()
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: "Realtime Replies.txt") { result in
                switch result {
                case .success:
                    if let exportSnapshot { exportedReplies = exportSnapshot }
                    error = ""; message = "Replies exported; save the setup separately"
                case .failure(let e): error = e.localizedDescription
                }
                document = nil; exportSnapshot = nil
            }
    }
    private func requestClose() {
        focusedField = nil; approval = nil; if session.busy { session.stop() }; camera.stop()
        guard !exporting else { return }
        if hasChanges { discardAction = .close; confirmingDiscard = true } else { close() }
    }
    private func close() {
        session.stop(); camera.stop(); approval = nil; document = nil; exportSnapshot = nil; dismiss()
    }
    private func requestStart() {
        guard canStart else { error = "Save the realtime setup and separate key first"; return }
        if repliesChanged { discardAction = .restart; confirmingDiscard = true } else { prepareApproval() }
    }
    private func prepareApproval() {
        guard !session.busy, canStart, phase == .active else { error = "Setup or page changed; please review again"; return }
        do { _ = try settings.request(key: key); error = ""; approval = .init(settings: settings, camera: shareCamera) } catch { self.error = error.localizedDescription }
    }
    private var canStart: Bool { settings == saved && key == savedKey && !key.isEmpty && (try? settings.request(key: key)) != nil }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); content() }
    }
    private func save() {
        do { try RealtimeStore.save(settings, key: key); saved = settings; savedKey = key; error = ""; message = key.isEmpty ? "Realtime key cleared" : "Realtime setup saved; not connected yet" } catch { self.error = error.localizedDescription }
    }
}
