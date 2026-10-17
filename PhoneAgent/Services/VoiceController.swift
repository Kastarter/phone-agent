import Foundation
import Combine
import AVFoundation
import Speech
import UIKit

// The tap owns the converter and copies each buffer before handing it to Speech.
private final class SpeechAudioBridge: @unchecked Sendable {
    let format: AVAudioFormat
    let converter: AVAudioConverter?
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    init(input: AVAudioFormat, output: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        format = output; converter = input == output ? nil : AVAudioConverter(from: input, to: output)
        self.continuation = continuation
    }
    func append(_ source: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate)) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        if let converter {
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return source
            }
            guard error == nil, status != .error, output.frameLength > 0 else { return }
        } else {
            output.frameLength = source.frameLength
            let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
            let to = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
            for index in 0..<min(from.count, to.count) {
                guard let src = from[index].mData, let dst = to[index].mData else { continue }
                memcpy(dst, src, Int(from[index].mDataByteSize))
            }
        }
        continuation.yield(AnalyzerInput(buffer: output))
    }
}

@MainActor
final class VoiceController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var transcript = ""
    @Published private(set) var listening = false
    @Published private(set) var preparing = false
    @Published private(set) var finalizing = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var status = "Tap the mic to start"
    @Published private(set) var error = ""
    var prepareAudio: (() async throws -> Void)?
    var onSilence: (() -> Void)?
    var usingAudio: Bool { preparing || listening || finalizing || isSpeaking }
    private var generation = UUID()
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var lastTextAt = Date()
    private var transcriptLimit = 4000
    private var engine: AVAudioEngine?
    private var installedTap = false
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?
    private var legacyFinal = false
    private var finalizedText = ""
    private var finalEnd: Double = -1
    private var audioActive = false
    private let speaker = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var speechCompletion: (() -> Void)?
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init(); speaker.delegate = self
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.audioActive, self.usingAudio else { return }
                self.cancel(); self.status = "Voice was interrupted by the system; recognized text kept"
            }
        }
    }
    deinit { if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) } }

    func start(maxDuration: Double = 60) {
        guard !preparing, !listening, !finalizing else { return }
        cancel(); transcript = ""; finalizedText = ""; finalEnd = -1; error = ""
        transcriptLimit = maxDuration > 60 ? 12000 : 4000
        preparing = true; status = "Preparing on-device speech recognition"
        let token = generation
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let microphone = await AVAudioApplication.requestRecordPermission()
                try self.check(token)
                guard microphone else { throw AgentError.message("Allow Phone Agent to use the microphone in Settings") }
                try await self.prepareAudio?(); try self.check(token)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true); self.audioActive = true
                let engine = AVAudioEngine(); self.engine = engine
                let input = engine.inputNode.outputFormat(forBus: 0)
                guard input.sampleRate > 0, input.channelCount > 0 else { throw AgentError.message("No microphone input available") }
                if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
                    try self.check(token)
                    do { try await self.startAnalyzer(engine: engine, input: input, locale: locale, token: token) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        // A device or model asset may be unavailable. Fall back only
                        // to on-device recognition; never silently upload audio.
                        await self.analyzer?.cancelAndFinishNow(); self.analyzer = nil
                        self.resultsTask?.cancel(); self.resultsTask = nil
                        self.continuation?.finish(); self.continuation = nil
                        try self.check(token)
                        try await self.startLegacy(engine: engine, input: input, token: token)
                    }
                } else { try await self.startLegacy(engine: engine, input: input, token: token) }
                try self.check(token)
                engine.prepare(); try engine.start()
                self.preparing = false; self.listening = true; self.lastTextAt = Date()
                self.timeoutTask = Task { [weak self] in
                    do { let limit = self?.analyzer == nil ? min(60, maxDuration) : min(600, maxDuration)
                    try await Task.sleep(nanoseconds: UInt64(max(1, limit) * 1_000_000_000)) } catch { return }
                    guard let self, token == self.generation else { return }
                    await self.finish(); self.status = "Dictation ended; you can edit the text before submitting"
                }
                self.silenceTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                        guard let self, token == self.generation, self.listening else { return }
                        if self.onSilence != nil, !self.transcript.isEmpty, Date().timeIntervalSince(self.lastTextAt) > 1.8 {
                            self.onSilence?(); return
                        }
                    }
                }
            } catch is CancellationError {
                // The newer generation owns the microphone and visible state.
            } catch {
                guard token == self.generation else { return }
                self.cancel(); self.error = error.localizedDescription; self.status = "Can't start voice input; you can type instead"
            }
        }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }
    private func startAnalyzer(engine: AVAudioEngine, input: AVAudioFormat, locale: Locale, token: UUID) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status = "Downloading English speech assets; audio is still processed on device"
            try await installation.downloadAndInstall(); try check(token)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber]); self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: input) else {
            throw AgentError.message("On-device speech model has no usable audio format")
        }
        try check(token); try await analyzer.prepareToAnalyze(in: format); try check(token)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        let bridge = SpeechAudioBridge(input: input, output: format, continuation: continuation)
        guard input == format || bridge.converter != nil else { throw AgentError.message("Can't convert microphone audio format") }
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, token == self.generation, !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                        if end > self.finalEnd { self.finalizedText += text; self.finalEnd = end }
                        self.setTranscript(self.finalizedText)
                    } else { self.setTranscript(self.finalizedText + text) }
                }
            } catch {
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.cancel(); self.error = "Speech recognition was interrupted; check the text and try again"
            }
        }
        try await analyzer.start(inputSequence: stream); try check(token)
        try engine.inputNode.installAudioTap(onBus: 0, bufferSize: 1024, format: input) { buffer, _ in bridge.append(AVAudioPCMBuffer(copying: buffer)) }
        installedTap = true; status = "Listening · on-device recognition"
    }
    private func startLegacy(engine: AVAudioEngine, input: AVAudioFormat, token: UUID) async throws {
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try check(token)
        guard permission == .authorized else { throw AgentError.message("Allow speech recognition in Settings") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw AgentError.message("On-device English recognition isn't available on this device; use Shortcuts dictation or type instead")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        request.contextualStrings = ["take over", "pause", "add", "resume", "stop", "Phone Agent"]
        legacyRequest = request; legacyFinal = false
        legacyTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, token == self.generation else { return }
                if let result { self.setTranscript(result.bestTranscription.formattedString); self.legacyFinal = result.isFinal }
                if error != nil {
                    self.legacyFinal = true
                    if self.listening { self.cancel(); self.error = "Speech recognition was interrupted; recognized text kept" }
                }
            }
        }
        try engine.inputNode.installAudioTap(onBus: 0, bufferSize: 1024, format: input) { buffer, _ in request.append(AVAudioPCMBuffer(copying: buffer)) }
        installedTap = true; status = "Listening · on-device dictation"
    }
    private func setTranscript(_ text: String) {
        let exceeded = text.count > transcriptLimit
        let text = String(text.prefix(transcriptLimit))
        if transcript != text { transcript = text; lastTextAt = Date() }
        if exceeded { cancel(); error = "Reached the \(transcriptLimit)-character transcript limit; transcription stopped. Save and continue in parts" }
    }
    private func stopMicrophone() {
        engine?.stop()
        if installedTap { engine?.inputNode.removeTap(onBus: 0); installedTap = false }
        engine = nil
        timeoutTask?.cancel(); timeoutTask = nil; silenceTask?.cancel(); silenceTask = nil
    }
    func finish() async {
        guard listening, !finalizing else { return }
        let token = generation
        listening = false; finalizing = true; status = "Finalizing recognized text"
        stopMicrophone(); continuation?.finish(); continuation = nil; legacyRequest?.endAudio()
        if let analyzer {
            let timeout = Task {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                await analyzer.cancelAndFinishNow()
            }
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            timeout.cancel()
            await resultsTask?.value
        } else {
            let deadline = Date().addingTimeInterval(2)
            while !legacyFinal && Date() < deadline && token == generation {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { break }
            }
        }
        guard token == generation else { return }
        legacyTask?.cancel(); legacyTask = nil; legacyRequest = nil
        analyzer = nil; resultsTask = nil; setupTask = nil
        finalizing = false; status = "Recognition done; you can edit before submitting"; releaseAudio()
    }
    func cancel() {
        generation = UUID(); setupTask?.cancel(); setupTask = nil
        stopMicrophone(); continuation?.finish(); continuation = nil
        resultsTask?.cancel(); resultsTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }; analyzer = nil
        legacyTask?.cancel(); legacyTask = nil; legacyRequest = nil
        preparing = false; listening = false; finalizing = false
        speechCompletion = nil; utterance = nil; speaker.stopSpeaking(at: .immediate); isSpeaking = false
        releaseAudio()
    }
    func speak(_ text: String, completion: (() -> Void)? = nil) {
        guard UIApplication.shared.applicationState == .active, !text.isEmpty else { completion?(); return }
        cancel(); error = ""; let token = generation
        preparing = true
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareAudio?(); try self.check(token)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true); self.audioActive = true
                let utterance = AVSpeechUtterance(string: String(text.prefix(4000)))
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                self.utterance = utterance; self.speechCompletion = completion
                self.preparing = false; self.isSpeaking = true; self.status = "Assistant is speaking"
                self.speaker.speak(utterance)
            } catch {
                guard token == self.generation else { return }
                self.cancel(); self.error = "Can't speak the reply; please read it on screen"; completion?()
            }
        }
    }
    private func releaseAudio() {
        guard audioActive else { return }; audioActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.utterance === utterance else { return }
            self.utterance = nil; self.isSpeaking = false; self.releaseAudio()
            let completion = self.speechCompletion; self.speechCompletion = nil; completion?()
        }
    }
}
