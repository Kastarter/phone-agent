import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

private enum RecordingNavigation { case close, choose(UUID), library, startRecording, importAudio }

struct RecordingsView: View {
    @ObservedObject var store: RecordingStore
    let onUseText: (RecordingTextSeed) -> Void
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audio = RecordingAudioController()
    @State private var newTitle = "New Recording"
    @State private var confirmRecord = false
    @State private var selected: UUID?
    @State private var speakerRecord: LocalRecording?
    @State private var editedTitle = ""
    @State private var text = ""
    @State private var error = ""
    @State private var message = ""
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var deleteTarget: RecordingProblem?
    @State private var confirmDelete = false
    @State private var confirmTranscribe = false
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    @State private var exportName = "Recording Text.txt"
    @State private var exportType = UTType.plainText
    @State private var importing = false
    @State private var confirmingDiscard = false
    @State private var pendingNavigation: RecordingNavigation?
    @State private var workLabel = "Processing on device"
    @FocusState private var focusedField: String?
    private var recordHasChanges: Bool { record.map { editedTitle != $0.title || text != $0.transcript } ?? false }
    private var hasChanges: Bool { newTitle != "New Recording" || recordHasChanges }
    private var record: LocalRecording? { store.records.first { $0.id == selected } }
    private var busy: Bool { audio.busy || work != nil || exporting }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    recordingNotices
                    if let record {
                        Button { requestNavigation(.library) } label: { Label("All Recordings", systemImage: "chevron.left") }.frame(minHeight: 44)
                        detail(record)
                    } else {
                        recordingControls
                        Text("\(store.records.count)  recordings · \(ByteCountFormatter.string(fromByteCount: Int64(store.audioBytes), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        if store.records.isEmpty {
                            AgentEmptyState(title: "No recordings yet", detail: "Start recording or import existing audio.", icon: "waveform")
                        } else { savedRecordings }
                    }
                    unfinishedRecordings
                    AgentHelp(title: "Storage and Use", text: "Audio and text are stored in a system-protected folder on this device, excluded from iCloud backup. Deleting removes both audio and text, but not copies you exported or memories you saved. On-device transcription doesn't separate speakers; use the separate speaker segmentation option and verify returned labels by listening.")
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("Recordings").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { requestNavigation(.close) } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide Keyboard") { focusedField = nil } }
                }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .interactiveDismissDisabled(hasChanges || busy)
            .alert("Discard unsaved recording changes?", isPresented: $confirmingDiscard) {
                Button("Keep Editing", role: .cancel) { pendingNavigation = nil }
                Button("Discard Changes", role: .destructive) {
                    let action = pendingNavigation; pendingNavigation = nil
                    if let record { choose(record) }
                    if let action { navigate(action) }
                }
            } message: { Text("Unsaved title and text will be lost. Saved recordings stay unchanged.") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): importAudio(url)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .confirmationDialog("Save the original audio for this recording?", isPresented: $confirmRecord, titleVisibility: .visible) {
                Button("Agree and Start Recording") { cancelWork(); selected = nil; audio.record(title: newTitle, store: store); newTitle = "New Recording" }
            } message: { Text("Title: \(newTitle)\nMicrophone audio will be saved on this iPhone for playback and on-device transcription, and won't be uploaded to the model. Tell participants first and get any required consent. This confirmation applies only to this recording.") }
            .confirmationDialog("Delete audio and transcript?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let target = deleteTarget else { return }
                    do { try store.remove(target.id, pending: target.pending); if selected == target.id { selected = nil; text = "" }; message = "On-device audio and transcript deleted" }
                    catch { self.error = error.localizedDescription }; deleteTarget = nil
                }
            } message: { Text("Copies exported elsewhere and saved memories won't be deleted.") }
            .confirmationDialog("Transcribing again replaces the current text draft. Continue?", isPresented: $confirmTranscribe, titleVisibility: .visible) {
                Button("Transcribe Again") { if let record { transcribe(record) } }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { result in
                if case .failure(let e) = result { error = e.localizedDescription }; document = nil
            }
            .sheet(item: $speakerRecord) { value in SpeakerView(record: value, store: store) { seed in onUseText(seed); dismiss() } }
            .onAppear {
                store.reload()
                audio.reserve = { model.reserveRecordingAudio($0) }; audio.release = { model.releaseRecordingAudio($0) }
                audio.prepareAudio = { try await model.pip.suspendForVoice() }
            }
            .onChange(of: phase) { _, value in
                if value == .background || (value == .inactive && audio.mode != .preparing) { cancelWork(); audio.stop(interrupted: true); confirmRecord = false }
            }
            .onDisappear { cancelWork(); audio.stop(interrupted: true) }
    }
    @ViewBuilder private var recordingControls: some View {
                    AgentPageIntro(title: "Record Audio", subtitle: "Save and transcribe on device, then review the text.", icon: "waveform")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("New recording title").font(.caption).foregroundStyle(.secondary)
                        TextField("Title for this recording", text: $newTitle).agentField().accessibilityLabel("New recording title").focused($focusedField, equals: "newTitle").disabled(busy)
                    }
                    HStack(spacing: 12) {
                    Button("Start Recording") { requestNavigation(.startRecording) }.buttonStyle(AgentButtonStyle()).disabled(busy || !store.error.isEmpty || newTitle.count > 80 || newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Import Audio File") { requestNavigation(.importAudio) }.buttonStyle(AgentButtonStyle(primary: false)).disabled(busy || !store.error.isEmpty)
                    }
                    AgentHelp(title: "Import and Recording Limits", text: "Imported files are converted to an on-device M4A copy; the source file is unchanged. Nothing is played, transcribed, or uploaded automatically. Input and copy are each limited to 30 MB / 10 minutes.")
                    if work != nil { ProgressView(workLabel); Button("Cancel") { cancelWork() }.frame(minHeight: 44) }
                    if audio.busy {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(audio.state).font(.headline)
                            HStack {
                                Text(time(audio.seconds)).font(.system(.title, design: .monospaced).bold())
                                Spacer()
                                if audio.mode == .recording || audio.mode == .paused {
                                    HStack(alignment: .center, spacing: 5) { ForEach(0..<5) { n in Capsule().fill(AgentPalette.ink).frame(width: 5, height: max(5, audio.level * Double(12 + n * 6))) } }.frame(height: 40).animation(.linear(duration: 0.1), value: audio.level)
                                }
                            }
                            if audio.mode == .recording || audio.mode == .paused { Button(audio.mode == .paused ? "Resume" : "Pause") { audio.pauseOrResume() }.frame(minHeight: 44) }
                            Button(audio.mode == .playing ? "Stop Playback" : "Stop and Save") { audio.stop() }.buttonStyle(AgentButtonStyle(primary: false))
                        }.agentPanel()
                    }
    }
    @ViewBuilder private var recordingNotices: some View {
                    if !audio.state.isEmpty && !audio.busy { AgentNotice(text: audio.state) }
                    if !audio.error.isEmpty { AgentNotice(text: audio.error, error: true) }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if !message.isEmpty { AgentNotice(text: message) }
                    if !store.error.isEmpty { AgentNotice(text: store.error, error: true); Button("Reload Recordings") { store.reload() }.disabled(busy) }
                    if store.trashCount > 0 {
                        Button("Clear \(store.trashCount) Pending Audio") { do { try store.clearTrash(); message = "Pending files cleared" } catch { self.error = "Cleanup failed. Check file permissions or storage, then retry" } }.disabled(busy).frame(minHeight: 44)
                    }
    }
    @ViewBuilder private var savedRecordings: some View {
                    ForEach(store.records) { r in
                        Button { if selected != r.id { requestNavigation(.choose(r.id)) } } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(r.title).font(.headline)
                                Text("\(r.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(time(r.duration))\(r.interrupted ? " · Interrupted" : "")").font(.caption).foregroundStyle(.secondary)
                                Text(r.transcript.isEmpty ? "Not transcribed yet" : String(r.transcript.prefix(80))).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(selected == r.id ? AgentPalette.inset : .clear, in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain).disabled(busy)
                    }
    }
    @ViewBuilder private var unfinishedRecordings: some View {
                    if !store.pending.isEmpty { Text("Unfinished Recordings").font(.headline); Text("Original files kept after a recording or save was interrupted. Readable audio can be recovered; files that can't be recovered can still be exported or deleted.") .font(.caption).foregroundStyle(.secondary) }
                    ForEach(store.pending) { p in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(p.title).font(.headline)
                            Button("Check and Recover Audio") { recover(p.id) }.disabled(busy).frame(minHeight: 44)
                            Button("Export Audio") { exportAudio(p.id, pending: true, title: p.title) }.disabled(busy).frame(minHeight: 44)
                            Button("Delete Unfinished Recording", role: .destructive) { deleteTarget = .init(id: p.id, pending: true); confirmDelete = true }.disabled(busy).frame(minHeight: 44)
                        }.agentPanel()
                    }
                    ForEach(store.problems) { problem in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Can't read transcript · \(problem.id.uuidString.prefix(8))")
                            Button("Export Readable Audio") { exportAudio(problem.id, pending: problem.pending, title: "Recording to Review") }.disabled(busy).frame(minHeight: 44)
                            Button("Delete Damaged Record", role: .destructive) { deleteTarget = problem; confirmDelete = true }.disabled(busy).frame(minHeight: 44)
                        }.agentPanel()
                    }
    }
    private func time(_ seconds: Double) -> String { let n = max(0, Int(seconds.isFinite ? seconds : 0)); return String(format: "%02d:%02d", n / 60, n % 60) }
    private func choose(_ r: LocalRecording) { selected = r.id; text = r.transcript; editedTitle = r.title; error = ""; message = "" }
    private func detail(_ r: LocalRecording) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Recording").font(.title3.bold())
            VStack(alignment: .leading, spacing: 8) {
                Text("Recording title").font(.caption).foregroundStyle(.secondary)
                TextField("Enter a title", text: $editedTitle).agentField().accessibilityLabel("Recording title").focused($focusedField, equals: "title").disabled(busy)
            }
            Button("Save Title") { do { try store.rename(r.id, title: editedTitle); editedTitle = record?.title ?? editedTitle; focusedField = nil; message = "Title saved" } catch { self.error = error.localizedDescription } }.disabled(busy).frame(minHeight: 44)
            Button("Play Recording") { model.speech.cancel(); audio.play(r, store: store) }.disabled(busy).frame(minHeight: 44)
            Button("Transcribe on Device") { focusedField = nil; if !text.isEmpty { confirmTranscribe = true } else { transcribe(r) } }.disabled(busy).frame(minHeight: 44)
            Button("Speaker Segmentation") { speakerRecord = r }.disabled(busy).frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 8) {
                Text("Review transcript").font(.caption).foregroundStyle(.secondary)
                TextField("Enter or correct text", text: $text, axis: .vertical).lineLimit(6...18).agentField().accessibilityLabel("Review transcript").focused($focusedField, equals: "text").disabled(busy)
            }
            Text("\(text.count)/12000 chars · \(r.textOrigin == .localRecognition ? "Last saved: on-device transcript" : r.textOrigin == .edited ? "Last saved: manual edit" : "No text saved yet")").font(.caption).foregroundStyle(.secondary)
            Button("Save Reviewed Text") { do { try store.saveText(r.id, text: text, origin: .edited); focusedField = nil; message = "Text saved" } catch { self.error = error.localizedDescription } }.disabled(busy || text.count > 12000).frame(minHeight: 44)
            Button("Use Text for Notes") {
                onUseText(.init(title: editedTitle, text: text, source: "On-device recording text · \(r.title) · \(r.createdAt.formatted())")); audio.stop(); dismiss()
            }.buttonStyle(AgentButtonStyle(primary: false)).disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 12000 || editedTitle.isEmpty || editedTitle.count > 80)
            Text("This only places the text in the workspace. Audio isn't uploaded and the model isn't called automatically. Unsaved edits aren't written to the library.") .font(.caption).foregroundStyle(.secondary)
            Button("Export Audio") { exportAudio(r.id, title: r.title) }.disabled(busy).frame(minHeight: 44)
            Button("Export Text") {
                document = ArtifactDocument(data: Data((editedTitle + "\n\n" + text).utf8)); exportType = .plainText; exportName = ArtifactFiles.filename(editedTitle) + ".txt"; exporting = true
            }.disabled(busy || text.count > 12000 || editedTitle.count > 80).frame(minHeight: 44)
            Button("Delete Recording", role: .destructive) { deleteTarget = .init(id: r.id, pending: false); confirmDelete = true }.disabled(busy).frame(minHeight: 44)
        }.agentPanel()
    }
    private func requestNavigation(_ action: RecordingNavigation) {
        focusedField = nil
        let needsConfirmation: Bool
        if case .close = action { needsConfirmation = hasChanges } else { needsConfirmation = recordHasChanges }
        if needsConfirmation { pendingNavigation = action; confirmingDiscard = true } else { navigate(action) }
    }
    private func navigate(_ action: RecordingNavigation) {
        switch action {
        case .close: cancelWork(); audio.stop(interrupted: true); dismiss()
        case .library: selected = nil; text = ""; editedTitle = ""
        case .choose(let id): if let value = store.records.first(where: { $0.id == id }) { choose(value) }
        case .startRecording: confirmRecord = true
        case .importAudio: importing = true
        }
    }
    private func importAudio(_ url: URL) {
        cancelWork(); focusedField = nil; let token = UUID(); generation = token
        let title = String(url.deletingPathExtension().lastPathComponent.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        error = ""; message = ""; workLabel = "Converting on-device audio copy"
        work = Task {
            defer { if generation == token { work = nil } }
            do {
                let result = try await RecordingImport.convert(url)
                try Task.checkCancellation()
                guard generation == token, phase == .active else { return }
                let value = try store.importAudio(result.data, title: title.isEmpty ? "Imported Audio" : title, duration: result.duration)
                choose(value); message = "Saved M4A audio copy; not played, transcribed, or uploaded"
            } catch { if generation == token && !Task.isCancelled { self.error = "Audio not imported: " + error.localizedDescription } }
        }
    }
    private func cancelWork() { generation = UUID(); work?.cancel(); work = nil }
    private func transcribe(_ r: LocalRecording) {
        guard phase == .active else { return }; cancelWork(); let token = UUID(); generation = token; error = ""; focusedField = nil; workLabel = "Transcribing on device"
        work = Task {
            defer { if generation == token { work = nil } }
            do {
                let result = try await LocalFileRecognition.audioText(store.audioURL(r.id)); try Task.checkCancellation()
                guard generation == token, phase == .active, selected == r.id, store.records.contains(where: { $0.id == r.id }) else { return }
                try store.saveText(r.id, text: result, origin: .localRecognition); text = result; message = "On-device transcript saved. Please review; speakers were not identified"
            } catch { if generation == token && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func recover(_ id: UUID) {
        do {
            let file = try AVAudioFile(forReading: store.audioURL(id, pending: true))
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let record = try store.finalize(id, duration: duration, interrupted: true); choose(record); message = "Recovered the readable audio. The end may be missing; listen to verify"
        } catch { self.error = "Couldn't recover this audio. The original file is kept; you can export or delete it" }
    }
    private func exportAudio(_ id: UUID, pending: Bool = false, title: String) {
        do {
            let url = try store.audioURL(id, pending: pending); cancelWork(); let token = UUID(); generation = token; focusedField = nil; workLabel = "Preparing audio export"
            let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); let value = try Data(contentsOf: url); try Task.checkCancellation(); return value }
            work = Task {
                defer { if generation == token { work = nil } }
                do {
                    let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard generation == token, phase == .active else { return }; document = ArtifactDocument(data: value); exportType = .mpeg4Audio; exportName = ArtifactFiles.filename(title) + ".m4a"; exporting = true
                } catch { if generation == token && !Task.isCancelled { self.error = "Couldn't export audio; the original record was not deleted" } }
            }
        } catch { self.error = "No valid audio file to export" }
    }
}

// A user-selected file is snapshotted before conversion. Only the closed M4A
// output is committed to the library; every temporary file is removed on exit.
private enum RecordingImport {
    struct Result { let data: Data; let duration: Double }
    static func convert(_ url: URL) async throws -> Result {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("PhoneAgentAudio-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        var protectedFolder = folder; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try protectedFolder.setResourceValues(flags)
        let source = folder.appendingPathComponent("source").appendingPathExtension(url.pathExtension)
        let reader = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= LocalRecording.maxAudioBytes else { throw AgentError.message("Choose a valid audio file up to 30 MB") }
            let data = try Data(contentsOf: url); try Task.checkCancellation()
            guard data.count == size else { throw AgentError.message("The audio changed while being read; choose it again") }
            try data.write(to: source, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, duration <= LocalRecording.maxDuration, !audioTracks.isEmpty, videoTracks.isEmpty else { throw AgentError.message("Must be an audio-only file up to 10 minutes; nothing was truncated or imported") }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw AgentError.message("The system can't convert this type of audio") }
        let output = folder.appendingPathComponent("converted.m4a")
        exporter.metadata = []
        try await exporter.export(to: output, as: .m4a)
        try Task.checkCancellation()
        let values = try output.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= LocalRecording.maxAudioBytes else { throw AgentError.message("Converted audio exceeds 30 MB; not saved") }
        let file = try AVAudioFile(forReading: output)
        let actual = Double(file.length) / file.processingFormat.sampleRate
        guard actual.isFinite, actual > 0, actual <= LocalRecording.maxDuration, abs(actual - duration) <= 0.15 else { throw AgentError.message("Converted duration doesn't match; not saved") }
        let data = try Data(contentsOf: output); try Task.checkCancellation()
        guard data.count == size else { throw AgentError.message("Converted file changed; not saved") }
        return Result(data: data, duration: actual)
    }
}
