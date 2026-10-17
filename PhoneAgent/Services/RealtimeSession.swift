import Foundation
import Combine

@MainActor protocol RealtimeConnection: AnyObject {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}
@MainActor protocol RealtimeAudioSink: AnyObject {
    var inbox: RealtimePCMInbox { get }
    var playedMilliseconds: Int { get }
    var scheduledMilliseconds: Int { get }
    var hasPending: Bool { get }
    func start() throws
    func play(_ data: Data) throws
    func clearPlayback()
    func stop()
}
private final class RealtimeRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor final class RealtimeWebSocket: RealtimeConnection {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForResource = 330
        session = URLSession(configuration: config, delegate: RealtimeRedirectPolicy(), delegateQueue: nil)
        socket = session.webSocketTask(with: request); socket.maximumMessageSize = 1000000; socket.resume()
    }
    func send(_ data: Data) async throws { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
    func receive() async throws -> Data { switch try await socket.receive() { case .string(let value): return Data(value.utf8); case .data(let data): return data; @unknown default: throw AgentError.message("The realtime service returned an unknown message format") } }
    func close() { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
struct RealtimeTranscript: Identifiable { let id: String; var text: String }
@MainActor final class RealtimeSession: ObservableObject {
    enum Mode { case idle, preparing, connecting, live }
    @Published private(set) var mode = Mode.idle
    @Published private(set) var status = "Realtime voice is off"
    @Published private(set) var error = ""
    @Published private(set) var transcripts: [RealtimeTranscript] = []
    @Published private(set) var seconds = 0
    @Published private(set) var cameraShares = 0
    var busy: Bool { mode != .idle }
    var reserve: ((UUID) -> Bool)?
    var release: ((UUID) -> Void)?
    var prepareAudio: (() async throws -> Void)?
    var permission: () async -> Bool = { false }
    var authorized: () -> Bool = { false }
    var makeAudio: (() -> any RealtimeAudioSink)?
    var makeConnection: (URLRequest) -> any RealtimeConnection = { RealtimeWebSocket(request: $0) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var generation = UUID()
    private var lease: UUID?
    private var settings: RealtimeSettings?
    private var includeCamera = false
    private var socket: (any RealtimeConnection)?
    private var audio: (any RealtimeAudioSink)?
    private var setup: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var configured = false
    private var configSent = false
    private var responding = false
    private var interrupting = false
    private var item: (id: String, index: Int)?
    private var ignored: [String] = []
    private var deadline = 0.0
    func start(settings: RealtimeSettings, key: String, includeCamera: Bool) {
        guard !busy else { return }
        error = ""
        let request: URLRequest
        do { request = try settings.request(key: key) } catch { self.error = error.localizedDescription; return }
        guard authorized(), let makeAudio else { error = "Page authorization or audio isn't ready"; return }
        let token = UUID()
        guard reserve?(token) == true else { error = "End the current task, voice, recording, or playback before starting a realtime conversation"; return }
        generation = token; lease = token; self.settings = settings; self.includeCamera = includeCamera
        configured = false; configSent = false; responding = false; ignored = []; item = nil
        seconds = 0; cameraShares = 0; transcripts = []; mode = .preparing; status = "Preparing microphone permission"
        setup = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareAudio?(); try self.check(token)
                guard await self.permission() else { throw AgentError.message("Allow microphone access in Settings. No audio was sent.") }; try self.check(token)
                self.audio = makeAudio(); self.socket = self.makeConnection(request); self.mode = .connecting; self.status = "Waiting for the realtime service to confirm the format"
                self.deadline = self.now() + 20; self.watch(token); self.listen(token); self.setup = nil
            } catch is CancellationError { if self.generation == token { self.stop() } }
            catch { if self.generation == token { self.fail("Couldn't prepare the realtime conversation. Check permissions and the endpoint; no automatic retry.") } }
        }
    }
    private func check(_ token: UUID) throws { try Task.checkCancellation(); guard generation == token, authorized() else { throw CancellationError() } }
    private func listen(_ token: UUID) {
        receiver = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try self.check(token); guard let socket = self.socket, let settings = self.settings else { return }
                    let data = try await socket.receive(); try self.check(token)
                    try await self.handle(RealtimeProtocol.decode(data, settings: settings), token: token)
                }
            } catch is CancellationError { if self.generation == token { self.stop() } }
            catch { if self.generation == token { self.fail("Realtime connection or event handling failed. Check the realtime endpoint, model, voice, and quota; no automatic reconnect.") } }
        }
    }
    private func handle(_ event: RealtimeProtocol.Event, token: UUID) async throws {
        switch event {
        case .created:
            guard !configSent, !configured, let settings, let socket else { throw AgentError.message("Duplicate realtime session-created event") }
            configSent = true; try await socket.send(RealtimeProtocol.configuration(settings)); try check(token)
        case .configured:
            guard configSent, !configured, mode == .connecting, let audio else { throw AgentError.message("Realtime configuration was confirmed out of order") }
            try check(token); try audio.start(); configured = true; mode = .live; deadline = now() + 300; status = "Listening live"; stream(token)
        case .speechStarted:
            guard configured else { throw AgentError.message("The realtime service hasn't confirmed the format yet") }
            try await interrupt(cancelResponse: false, token: token); status = "Listening"
        case .speechStopped: if configured { status = "Understanding what you said" }
        case .responseStarted:
            guard configured else { throw AgentError.message("Realtime reply arrived before format confirmation") }; responding = true; status = "Assistant is answering"
        case .responseEnded: responding = false; if configured { status = "You can keep talking" }
        case .audio(let id, let index, let data):
            guard configured, let audio else { throw AgentError.message("Audio arrived before configuration was confirmed") }
            if ignored.contains(id) { return }
            if item?.id != id {
                guard !audio.hasPending else { throw AgentError.message("Realtime audio replies overlapped and were not mixed") }; audio.clearPlayback(); item = (id, index)
            }
            guard item?.index == index else { throw AgentError.message("Realtime audio segment index changed") }
            try audio.play(data)
        case .transcript(let id, let contentIndex, let text, let done):
            guard configured else { throw AgentError.message("Transcript arrived before configuration was confirmed") }; if ignored.contains(id) { return }
            if item == nil && responding { audio?.clearPlayback(); item = (id, contentIndex) }
            if let index = transcripts.firstIndex(where: { $0.id == id }) {
                let newText = done ? text : transcripts[index].text + text
                guard newText.count <= 12000 else { throw AgentError.message("Realtime transcript exceeded the limit") }; transcripts[index].text = newText
            } else { if transcripts.count == 40 { transcripts.removeFirst() }; transcripts.append(.init(id: id, text: text)) }
        case .failure: throw AgentError.message("The realtime service didn't finish this reply")
        case .ignored: break
        }
    }
    private func stream(_ token: UUID) {
        sender = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try self.check(token); guard let audio = self.audio, let socket = self.socket else { return }
                    if audio.inbox.failed { throw AgentError.message("Realtime upload is congested") }
                    if let data = audio.inbox.pop() { try await socket.send(RealtimeProtocol.append(data)); try self.check(token) }
                    else { try await Task.sleep(nanoseconds: 20000000) }
                }
            } catch is CancellationError { if self.generation == token { self.stop() } }
            catch { if self.generation == token { self.fail("Realtime audio upload was interrupted or backed up. The connection stopped; no automatic retry.") } }
        }
    }
    private func watch(_ token: UUID) {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 200000000) } catch { return }
                guard let self, self.generation == token else { return }
                guard self.authorized() else { self.stop(reason: "The page or settings changed; the realtime conversation ended"); return }
                if self.audio?.inbox.failed == true { self.fail("Outgoing audio backed up; the microphone and connection were stopped"); return }
                if self.now() >= self.deadline { self.stop(reason: self.configured ? "Reached the 5-minute session limit" : "Realtime configuration timed out; the microphone was not turned on"); return }
                if self.configured { self.seconds = max(0, min(300, 300 - Int(self.deadline - self.now()))) }
            }
        }
    }
    func interruptReply() {
        guard mode == .live, !interrupting else { return }; let token = generation; interrupting = true
        Task { defer { if generation == token { interrupting = false } }; do { try await interrupt(cancelResponse: true, token: token); try check(token); status = "Reply interrupted. You can keep talking." } catch { if generation == token { fail("Couldn't sync the reply interruption; the connection ended") } } }
    }
    private func interrupt(cancelResponse: Bool, token: UUID) async throws {
        try check(token); guard let socket, let audio else { return }
        let previous = item; let heard = audio.playedMilliseconds; let total = audio.scheduledMilliseconds
        audio.clearPlayback(); item = nil
        if let previous, responding || heard < total {
            if ignored.count == 50 { ignored.removeFirst() }; ignored.append(previous.id)
            if let index = transcripts.firstIndex(where: { $0.id == previous.id }) { transcripts[index].text = "(Reply interrupted; unplayed text is not kept)" }
        }
        if cancelResponse && responding { try await socket.send(RealtimeProtocol.json(["type": "response.cancel"])); try check(token) }
        if let previous, heard < total || responding { try await socket.send(RealtimeProtocol.truncate(item: previous.id, index: previous.index, milliseconds: heard)); try check(token) }
    }
    func share(jpeg: Data, capturedAt: Date) {
        guard mode == .live, includeCamera, cameraShares < 20 else { error = "Camera isn't authorized for this session, or the 20-frame limit was reached"; return }
        let token = generation
        let data: Data
        do { data = try RealtimeProtocol.image(jpeg, capturedAt: capturedAt, now: Date()) } catch { self.error = error.localizedDescription; return }
        cameraShares += 1 // Reserve synchronously so rapid taps cannot bypass the session limit.
        Task {
            do {
                try check(token); guard let socket else { return }
                try await socket.send(data); try check(token); status = "Frame sent. Go ahead and ask your question."
            } catch { if generation == token { fail("The camera frame couldn't be sent; the realtime connection stopped") } }
        }
    }
    func stop(reason: String = "Realtime conversation ended") {
        generation = UUID(); setup?.cancel(); receiver?.cancel(); sender?.cancel(); timer?.cancel(); setup = nil; receiver = nil; sender = nil; timer = nil
        socket?.close(); socket = nil; audio?.stop(); audio = nil; mode = .idle; configured = false; responding = false; interrupting = false; configSent = false; item = nil; ignored = []; status = reason
        if let lease { self.lease = nil; release?(lease) }
    }
    private func fail(_ message: String) { stop(reason: "Realtime conversation stopped"); error = message }
}
