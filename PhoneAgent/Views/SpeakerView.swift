import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

private struct SpeakerApproval: Identifiable {
    let id: UUID
    let record: LocalRecording
    let settings: SpeakerSettings
    let key: String
    let audio: Data
}
struct SpeakerView: View {
    let record: LocalRecording
    @ObservedObject var store: RecordingStore
    let onUseText: (RecordingTextSeed) -> Void
    @EnvironmentObject private var model: PhoneAgentViewModel
    @StateObject private var audition = RecordingAudioController()
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var settings = SpeakerSettings()
    @State private var saved = SpeakerSettings()
    @State private var key = ""
    @State private var savedKey = ""
    @State private var draft: SpeakerDocument?
    @State private var approval: SpeakerApproval?
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var error = ""
    @State private var message = ""
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    @State private var exportType = UTType.plainText
    @State private var exportName = "speaker-segments.txt"
    @State private var savedDraft: SpeakerDocument?
    @State private var confirmingDiscard = false
    @State private var pendingSeed: RecordingTextSeed?
    @FocusState private var focusedField: String?
    private var hasChanges: Bool { settings != saved || key != savedKey || draft != savedDraft }
    private var busy: Bool { work != nil || exporting || audition.busy }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    AgentPageIntro(title: "Review Speakers", subtitle: record.title, icon: "person.2.wave.2")
                    Text("Speaker A / B are labels the service assigns within this recording; they don't prove anyone's identity. This recording's audio must be uploaded; the on-device transcript and original recording are kept. Nothing is sent until you confirm each time.") .foregroundStyle(.secondary)
                    DisclosureGroup("Separate Audio Service Setup") {
                        VStack(spacing: 14) {
                            labeledField("Diarization provider", text: $settings.provider, placeholder: "Provider name", id: "provider")
                            labeledField("Transcription endpoint", text: $settings.endpoint, placeholder: "https://…/v1/audio/transcriptions", id: "endpoint", keyboard: .URL, lines: 1...3)
                            labeledField("Diarization model", text: $settings.model, placeholder: "A model that supports diarized_json", id: "model")
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Audio service key").font(.caption).foregroundStyle(.secondary)
                                SecureField("Enter the audio API key", text: $key).textContentType(.oneTimeCode).textInputAutocapitalization(.never).autocorrectionDisabled().agentField().accessibilityLabel("Audio service key").focused($focusedField, equals: "key")
                            }
                            Button("Save Audio Setup") { saveConfiguration() }.buttonStyle(AgentButtonStyle(primary: false))
                            Text("Not a Chat or realtime voice endpoint; task, realtime voice, and search keys are never used here. The service must support audio upload and diarized_json. No speaker reference samples are uploaded.") .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }.disabled(busy)
                    if audition.busy { Text(audition.state).font(.headline); Text("Playback position: " + SpeakerDocument.time(audition.seconds)).font(.caption.monospacedDigit()); Button("Stop Playback") { audition.stop() }.frame(minHeight: 44) }
                    if !audition.error.isEmpty { AgentNotice(text: audition.error, error: true) }
                    if work != nil { ProgressView("Processing the selected recording"); Button("Cancel") { cancel() }.frame(minHeight: 44) }
                    else { Button(draft == nil ? "Review & Analyze Recording" : "Review & Reanalyze") { prepare() }.buttonStyle(AgentButtonStyle()).disabled(exporting || audition.busy) }
                    AgentHelp(title: "Processing limits", text: "One recording up to 25 MB / 10 minutes. A single request is made, with no automatic splitting or retries. Canceling or going to the background stops receiving results but cannot recall audio already sent.")
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if !message.isEmpty { AgentNotice(text: message) }
                    if let draft {
                        Text("Review Labels & Segments").font(.title3.bold())
                        Text("\(draft.speakers.count) service speakers · \(draft.segments.count) segments\nPlayback starts at the segment and stops near its end (polled about every 0.1 s); the audio is not modified. Labels and transcripts may be wrong. Renaming is only a manual note; verify attribution, timing, and text in the notes by listening. Unsaved changes stay on this page only.") .font(.caption).foregroundStyle(.secondary)
                        ForEach(draft.speakers.indices, id: \.self) { index in
                            labeledField("Manual label for speaker \(index + 1)", text: speakerBinding(index), placeholder: "Manual label", id: "speaker-\(index)").disabled(busy)
                        }
                        ForEach(Array(draft.segments.enumerated()), id: \.element.id) { item in
                            segmentRow(item.offset, snapshot: draft)
                        }
                        DisclosureGroup("Service's Original Combined Text") { Text(draft.serviceText).font(.footnote).textSelection(.enabled); Text("The original combined text does not update with your segment edits.") .font(.caption).foregroundStyle(.secondary) }
                        Button("Save Reviewed Segments") {
                            do { try store.saveSpeakerDocument(draft); savedDraft = draft; focusedField = nil; message = "Segments saved. The on-device transcript was not replaced"; error = "" } catch { self.error = error.localizedDescription }
                        }.buttonStyle(AgentButtonStyle()).disabled(busy)
                        Button("Use Segment Text for Notes") {
                            do {
                                let text = try draft.referenceText()
                                guard text.count <= 12000 else { throw AgentError.message("Labeled notes material exceeds 12,000 characters. Remove some segments and try again; the full segments can still be exported") }
                                requestClose(seed: .init(title: record.title, text: text, source: "Speaker segment text (labels aren't identities; review needed) · " + record.title))
                            } catch { self.error = error.localizedDescription }
                        }.buttonStyle(AgentButtonStyle(primary: false)).disabled(busy)
                        Text("Only the current segment text goes to the workbench. The notes model is not called here and the audio is not uploaded again.") .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Export TXT") { export(draft, json: false) }.frame(minHeight: 44)
                            Spacer()
                            Button("Export Segments JSON") { export(draft, json: true) }.frame(minHeight: 44)
                        }.disabled(busy)
                        Button("Delete Segments on Device", role: .destructive) { confirmDelete = true }.disabled(busy).frame(minHeight: 44)
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("Speaker Segments").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { requestClose() } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide Keyboard") { focusedField = nil } }
                }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .interactiveDismissDisabled(hasChanges || busy)
            .alert("Discard unsaved audio setup or segments?", isPresented: $confirmingDiscard) {
                Button("Keep Editing", role: .cancel) { pendingSeed = nil }
                Button("Discard Changes", role: .destructive) { close() }
            } message: { Text("Unsaved setup, key, and segment changes will be lost. Saved recordings and segments are unchanged.") }
            .onAppear {
                audition.reserve = model.reserveRecordingAudio; audition.release = model.releaseRecordingAudio; audition.prepareAudio = { try await model.pip.suspendForVoice() }
                saved = SpeakerStore.load(); settings = saved; savedKey = SpeakerStore.key(for: saved); key = savedKey
                do { draft = try store.speakerDocument(record.id); savedDraft = draft } catch { self.error = error.localizedDescription }
            }
            .onChange(of: phase) { _, value in if value != .active { cancel(); audition.stop() } }
            .onChange(of: settings) { _, _ in cancel() }
            .onChange(of: key) { _, _ in cancel() }
            .onDisappear { cancel(); audition.stop(); document = nil }
            .sheet(item: $approval, onDismiss: { approval = nil }) { value in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Confirm Audio Upload").font(.title.bold())
                            Text("Recording: \(value.record.title)\nDuration: \(SpeakerDocument.time(value.record.duration))\nSize: \(ByteCountFormatter.string(fromByteCount: Int64(value.audio.count), countStyle: .file))\nRecipient: \(value.settings.provider)\n\(value.settings.endpoint)\nModel: \(value.settings.model)").font(.footnote).textSelection(.enabled)
                            Text("This sends the entire selected recording and the separate auth key. The service may charge for, store, or forward the audio; review its policy and confirm participants have consented. The app does not add speaker reference samples, name fields, tasks, screens, history, or other recordings, but all voices and information in the selected recording are sent.")
                            Text("Review results on this page first; they never overwrite the on-device transcript automatically. Speaker labels, attribution, and transcripts may be wrong; saving, exporting, and notes are separate choices. Canceling cannot recall audio already sent. A successful reanalysis replaces the previous draft on this page; if it fails, the previous draft is kept.") .font(.footnote).foregroundStyle(.secondary)
                            Button("Agree & Send Once") { start(value) }.buttonStyle(AgentButtonStyle())
                        }.padding(20)
                    }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } } }
                }.tint(AgentPalette.accent).agentSheetStyle()
            }
            .confirmationDialog("Delete segments on device?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Segments", role: .destructive) { do { try store.removeSpeakerDocument(record.id); draft = nil; savedDraft = nil; message = "Segments deleted. The audio and on-device transcript are kept" } catch { self.error = error.localizedDescription } }
            } message: { Text("This does not delete the audio, the on-device transcript, exported copies, or data the service already received.") }
            .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { result in if case .failure(let e) = result { error = e.localizedDescription }; document = nil }
    }
    private func requestClose(seed: RecordingTextSeed? = nil) {
        focusedField = nil; pendingSeed = seed
        if hasChanges { confirmingDiscard = true } else { close() }
    }
    private func close() {
        cancel(); audition.stop()
        if let seed = pendingSeed { onUseText(seed); pendingSeed = nil }
        dismiss()
    }
    private func labeledField(_ label: String, text: Binding<String>, placeholder: String, id: String, keyboard: UIKeyboardType = .default, lines: ClosedRange<Int> = 1...1) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical).lineLimit(lines).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(keyboard).agentField().accessibilityLabel(label).focused($focusedField, equals: id)
        }
    }
    private func speakerBinding(_ index: Int) -> Binding<String> {
        .init(get: { draft?.speakers.indices.contains(index) == true ? draft!.speakers[index] : "" }, set: { value in guard draft?.speakers.indices.contains(index) == true else { return }; draft!.speakers[index] = value; draft!.edited = true })
    }
    private func segmentBinding<T>(_ index: Int, id: UUID, _ path: WritableKeyPath<SpeakerSegment, T>, fallback: T) -> Binding<T> {
        .init(get: { draft?.segments.indices.contains(index) == true && draft!.segments[index].id == id ? draft!.segments[index][keyPath: path] : fallback }, set: { value in guard draft?.segments.indices.contains(index) == true, draft!.segments[index].id == id else { return }; draft!.segments[index][keyPath: path] = value; draft!.edited = true })
    }
    private func segmentRow(_ index: Int, snapshot: SpeakerDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Segment \(index + 1) · \(SpeakerDocument.time(snapshot.segments[index].start))–\(SpeakerDocument.time(snapshot.segments[index].end))").font(.caption).foregroundStyle(.secondary)
            Button("Play This Segment") { model.speech.cancel(); audition.play(record, store: store, start: snapshot.segments[index].start, end: snapshot.segments[index].end) }.frame(minHeight: 44)
            Picker("Speaker", selection: segmentBinding(index, id: snapshot.segments[index].id, \.speaker, fallback: 0)) { ForEach(snapshot.speakers.indices, id: \.self) { Text(snapshot.speakers[$0]).tag($0) } }.pickerStyle(.menu)
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start (s)").font(.caption).foregroundStyle(.secondary)
                    TextField("Start (s)", value: segmentBinding(index, id: snapshot.segments[index].id, \.start, fallback: 0), format: .number).keyboardType(.decimalPad).agentField().accessibilityLabel("Segment \(index + 1) start seconds").focused($focusedField, equals: "start-\(index)")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("End (s)").font(.caption).foregroundStyle(.secondary)
                    TextField("End (s)", value: segmentBinding(index, id: snapshot.segments[index].id, \.end, fallback: 0), format: .number).keyboardType(.decimalPad).agentField().accessibilityLabel("Segment \(index + 1) end seconds").focused($focusedField, equals: "end-\(index)")
                }
            }
            labeledField("Segment \(index + 1) text", text: segmentBinding(index, id: snapshot.segments[index].id, \.text, fallback: ""), placeholder: "Review this segment's text", id: "text-\(index)", lines: 2...8)
            Button("Remove Segment", role: .destructive) { guard draft?.segments.indices.contains(index) == true, draft!.segments[index].id == snapshot.segments[index].id else { return }; draft!.segments.remove(at: index); draft!.edited = true }.frame(minHeight: 44)
        }.agentPanel().disabled(busy)
    }
    private func saveConfiguration() {
        focusedField = nil
        do { try SpeakerStore.save(settings, key: key); saved = settings; savedKey = key; error = ""; message = key.isEmpty ? "Audio key cleared" : "Audio setup saved. No request was made" } catch { self.error = error.localizedDescription }
    }
    private func check(_ token: UUID, settings expected: SpeakerSettings, key expectedKey: String) throws {
        try Task.checkCancellation()
        guard generation == token, phase == .active, settings == expected, saved == expected, key == expectedKey, savedKey == expectedKey, saved == SpeakerStore.load(),
              store.error.isEmpty, store.records.first(where: { $0.id == record.id }) == record else { throw CancellationError() }
    }
    private func cancel() { generation = UUID(); work?.cancel(); work = nil; approval = nil }
    private func prepare() {
        focusedField = nil
        guard !busy, phase == .active, settings == saved, key == savedKey, SpeakerSettings.validKey(key) else { error = "Save a valid audio service setup and key first"; return }
        cancel(); let token = UUID(); generation = token; let expected = settings; let expectedKey = key; error = ""; message = ""
        work = Task {
            defer { if generation == token { work = nil } }
            do {
                _ = try expected.validate(); try check(token, settings: expected, key: expectedKey)
                let url = try store.audioURL(record.id); let duration = record.duration
                let reader = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= SpeakerDocument.maxFileBytes else { throw AgentError.message("The selected recording is over 25 MB or invalid. Not uploaded") }
                    let file = try AVAudioFile(forReading: url); let actual = Double(file.length) / file.processingFormat.sampleRate
                    guard actual.isFinite, abs(actual - duration) <= 0.15 else { throw AgentError.message("Recording duration doesn't match its record. Not uploaded") }
                    let data = try Data(contentsOf: url); try Task.checkCancellation()
                    guard data.count == size else { throw AgentError.message("The audio changed while being read. Review it again") }; return data
                }
                let data = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
                try check(token, settings: expected, key: expectedKey)
                approval = .init(id: token, record: record, settings: expected, key: expectedKey, audio: data)
            } catch { if generation == token && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func start(_ value: SpeakerApproval) {
        guard approval?.id == value.id, !busy else { return }
        do { try check(value.id, settings: value.settings, key: value.key) } catch { cancel(); return }
        approval = nil
        work = Task {
            defer { if generation == value.id { work = nil } }
            do {
                try check(value.id, settings: value.settings, key: value.key)
                guard SpeakerDocument.digest(try Data(contentsOf: store.audioURL(record.id))) == SpeakerDocument.digest(value.audio) else { throw AgentError.message("The recording changed after you confirmed. Processing stopped") }
                let result = try await SpeakerClient(settings: value.settings, key: value.key).analyze(audio: value.audio, recordingID: record.id, duration: record.duration)
                try check(value.id, settings: value.settings, key: value.key)
                guard SpeakerDocument.digest(try Data(contentsOf: store.audioURL(record.id))) == result.audioSHA256 else { throw AgentError.message("The recording changed before the response arrived. The draft was not replaced") }
                draft = result; message = "Segments returned. Listen and review; not saved yet"; error = ""
            } catch { if generation == value.id && !Task.isCancelled { self.error = "Segmentation didn't finish; the previous draft was kept. " + error.localizedDescription } }
        }
    }
    private func export(_ value: SpeakerDocument, json: Bool) {
        do { try value.validate(); document = ArtifactDocument(data: json ? try JSONEncoder().encode(value) : Data(try value.exportText().utf8)); exportType = json ? .json : .plainText; exportName = ArtifactFiles.filename(record.title) + (json ? "-segments.json" : "-segments.txt"); exporting = true } catch { self.error = error.localizedDescription }
    }
}
