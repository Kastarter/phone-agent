import Foundation
import AVFoundation
import LiveKit

@MainActor
final class CallController: ObservableObject {
    enum Phase: Equatable { case idle, connecting, listening, thinking, speaking, working(String), ended, failed(String) }
    struct Caption: Identifiable, Equatable { let id: UUID; let fromAgent: Bool; var text: String }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var captions: [Caption] = []
    @Published private(set) var muted = false
    @Published private(set) var startedAt: Date?

    var isActive: Bool {
        switch phase {
        case .connecting, .listening, .thinking, .speaking, .working: true
        default: false
        }
    }

    /// True when the build bundles a complete Resources/VoiceAgent.json; the call button hides otherwise.
    static var credentialsAvailable: Bool { hasConfig }
    private static let hasConfig = VoiceAgentConfig.load() != nil

    nonisolated private static let rpcMethod = "client_tool_call"
    nonisolated private static let transcriptionTopic = "lk.transcription"
    nonisolated private static let toolWaitLimit: Duration = .seconds(110)

    private var room: Room?
    private var events: CallRoomEvents?
    private var generation = UUID()
    private var localIdentity = ""
    private var runTask: (@MainActor (String) async -> String)?
    private var stopTask: (@MainActor () async -> String)?
    private var workingInstruction: String?
    private var work: Task<String, Never>?
    private var agentPresent = false
    private var agentState: String?
    private var agentSpeaking = false
    private var captionIDs: [String: UUID] = [:]
    private var savedAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private var pickupTimeout: Task<Void, Never>?

    func start(runTask: @escaping @MainActor (String) async -> String, stopTask: @escaping @MainActor () async -> String) async {
        guard !isActive else { return }
        let gen = UUID()
        generation = gen
        self.runTask = runTask
        self.stopTask = stopTask
        captions = []; captionIDs = [:]; muted = false; startedAt = nil
        agentPresent = false; agentState = nil; agentSpeaking = false; workingInstruction = nil
        phase = .connecting

        guard let config = VoiceAgentConfig.load() else { return fail("Voice calling isn't set up on this build.", gen) }
        guard await AVAudioApplication.requestRecordPermission() else { return fail("Microphone access is off. Turn it on in Settings.", gen) }
        guard generation == gen else { return }

        let identity = "phone-" + UUID().uuidString.prefix(8).lowercased()
        let roomName = "call-" + UUID().uuidString.lowercased()
        localIdentity = identity
        let minted: MintedToken
        do {
            minted = try await Self.mintToken(config: config, identity: identity, roomName: roomName)
        } catch {
            return fail(Self.friendly(error), gen)
        }
        guard generation == gen else { return }

        let events = CallRoomEvents { [weak self] event in
            Task { @MainActor in self?.handle(event, gen) }
        }
        let room = Room(delegate: events)
        self.room = room
        self.events = events
        saveAudioSession()
        AudioManager.shared.isSpeakerOutputPreferred = true

        do {
            try await room.registerRpcMethod(Self.rpcMethod) { [weak self] data in
                guard let self else { return Self.errorJSON("Call ended.") }
                return await self.handleToolCall(data.payload, gen)
            }
            try await room.registerTextStreamHandler(for: Self.transcriptionTopic) { [weak self] reader, sender in
                let segment = reader.info.attributes["lk.segment_id"] ?? reader.info.id
                let key = sender.stringValue + "|" + segment
                var text = ""
                for try await chunk in reader {
                    text += chunk
                    let current = text
                    await self?.upsertCaption(key: key, sender: sender.stringValue, text: current, gen)
                }
            }
            try await room.connect(url: Self.websocketURL(minted.url), token: minted.token)
            guard generation == gen else { await room.disconnect(); return }
            _ = try await room.localParticipant.setMicrophone(enabled: true)
            guard generation == gen else { await room.disconnect(); return }
        } catch {
            return fail(Self.friendly(error), gen)
        }

        startedAt = Date()
        if let agent = room.remoteParticipants.values.first(where: { $0.isAgent }) ?? room.remoteParticipants.values.first {
            agentPresent = true
            agentState = agent.attributes["lk.agent.state"]
        }
        refreshPhase()
        pickupTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, !Task.isCancelled, self.generation == gen, !self.agentPresent else { return }
            self.fail("The voice agent didn't pick up. Try again.", gen)
        }
    }

    func end() async {
        guard room != nil || isActive else { return }
        await teardown()
        phase = .ended
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.generation == gen, self.phase == .ended else { return }
            self.phase = .idle
        }
    }

    func toggleMute() async {
        guard let room, isActive else { return }
        do {
            _ = try await room.localParticipant.setMicrophone(enabled: muted)
            muted.toggle()
        } catch {}
    }

    // MARK: - Tools

    private func handleToolCall(_ payload: String, _ gen: UUID) async -> String {
        guard generation == gen else { return Self.errorJSON("Call ended.") }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = object["tool"] as? String else { return Self.errorJSON("Malformed tool call.") }
        let arguments = object["arguments"] as? [String: Any] ?? [:]
        switch tool {
        case "stop_phone_task":
            guard let stopTask else { return Self.errorJSON("Not available.") }
            return Self.responseJSON(await stopTask())
        case "control_phone":
            let instruction = (arguments["instruction"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return Self.errorJSON("Missing instruction.") }
            guard let runTask else { return Self.errorJSON("Not available.") }
            // A newer request replaces the one in flight (runTask stops the old task); the old call returns once it ends.
            if let previous = self.work { previous.cancel(); _ = await previous.value }
            guard generation == gen else { return Self.errorJSON("Call ended.") }
            workingInstruction = instruction
            refreshPhase()
            let work = Task { @MainActor in await runTask(instruction) }
            self.work = work
            Task { [weak self] in
                _ = await work.value
                guard let self, self.generation == gen, self.work == work else { return }
                self.workingInstruction = nil; self.work = nil
                self.refreshPhase()
            }
            let result: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask { await work.value }
                group.addTask { try? await Task.sleep(for: Self.toolWaitLimit); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            return Self.responseJSON(result ?? "Still working on it; I'll keep going.")
        default:
            return Self.errorJSON("Unknown tool \(tool).")
        }
    }

    // MARK: - Room events

    fileprivate enum Event: Sendable {
        case agentJoined(String?), agentState(String?), agentLeft, speaking(Bool), disconnected(String?)
    }

    private func handle(_ event: Event, _ gen: UUID) {
        guard generation == gen, room != nil else { return }
        switch event {
        case .agentJoined(let state):
            agentPresent = true
            pickupTimeout?.cancel()
            if let state { agentState = state }
        case .agentState(let state):
            agentPresent = true
            agentState = state
        case .speaking(let speaking):
            agentSpeaking = speaking
        case .agentLeft:
            Task { await end() }
            return
        case .disconnected(let message):
            Task { [weak self] in
                guard let self else { return }
                await self.teardown()
                self.phase = message == nil ? .ended : .failed("The call dropped. Check your connection.")
            }
            return
        }
        refreshPhase()
    }

    private func refreshPhase() {
        guard room != nil, startedAt != nil else { return }
        guard agentPresent else { phase = .connecting; return }
        let state = agentState ?? (agentSpeaking ? "speaking" : "listening")
        if let workingInstruction, state != "speaking" { phase = .working(workingInstruction); return }
        switch state {
        case "speaking": phase = .speaking
        case "thinking": phase = .thinking
        default: phase = .listening
        }
    }

    private func upsertCaption(key: String, sender: String, text: String, _ gen: UUID) {
        guard generation == gen else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let id = captionIDs[key], let index = captions.firstIndex(where: { $0.id == id }) {
            if captions[index].text != trimmed { captions[index].text = trimmed }
            return
        }
        let caption = Caption(id: UUID(), fromAgent: sender != localIdentity, text: trimmed)
        captionIDs[key] = caption.id
        captions.append(caption)
        if captions.count > 20 {
            captions.removeFirst(captions.count - 20)
            let alive = Set(captions.map(\.id))
            captionIDs = captionIDs.filter { alive.contains($0.value) }
        }
    }

    // MARK: - Teardown

    private func fail(_ message: String, _ gen: UUID) {
        guard generation == gen else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.teardown()
            self.phase = .failed(message)
        }
    }

    private func teardown() async {
        generation = UUID()
        pickupTimeout?.cancel(); pickupTimeout = nil
        let room = self.room
        self.room = nil
        events = nil
        runTask = nil; stopTask = nil; work = nil
        workingInstruction = nil; agentPresent = false; agentState = nil; agentSpeaking = false
        muted = false; startedAt = nil
        if let room {
            await room.unregisterRpcMethod(Self.rpcMethod)
            await room.unregisterTextStreamHandler(for: Self.transcriptionTopic)
            await room.disconnect()
        }
        restoreAudioSession()
    }

    private func saveAudioSession() {
        let session = AVAudioSession.sharedInstance()
        savedAudio = (session.category, session.mode, session.categoryOptions)
    }

    private func restoreAudioSession() {
        guard let saved = savedAudio else { return }
        savedAudio = nil
        try? AVAudioSession.sharedInstance().setCategory(saved.0, mode: saved.1, options: saved.2)
    }

    // MARK: - Token

    /// The voice agent this build calls, from the git-ignored Resources/VoiceAgent.json (see VoiceAgent.example.json).
    /// The token service gets `POST tokenURL` with `Authorization: Bearer apiKey:apiSecret` and the JSON body
    /// {identity, roomName, agentName, roomMetadata}, and answers {token, url}: a LiveKit access token for that room
    /// and the LiveKit server URL. roomMetadata carries the client tools below plus the file's extra fields.
    struct VoiceAgentConfig {
        let tokenURL: URL
        let agentName: String
        let apiKey: String
        let apiSecret: String
        let roomMetadata: [String: Any]

        static func load(bundle: Bundle = .main) -> VoiceAgentConfig? {
            guard let url = bundle.url(forResource: "VoiceAgent", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return parse(data)
        }

        /// Nil unless every required field is present and the token URL is HTTPS.
        static func parse(_ data: Data) -> VoiceAgentConfig? {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            func text(_ key: String) -> String? {
                guard let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                return value
            }
            guard let link = text("tokenURL"), let tokenURL = URL(string: link), tokenURL.scheme == "https", tokenURL.host != nil,
                  let agentName = text("agentName"), let apiKey = text("apiKey"), let apiSecret = text("apiSecret") else { return nil }
            return VoiceAgentConfig(tokenURL: tokenURL, agentName: agentName, apiKey: apiKey, apiSecret: apiSecret,
                                    roomMetadata: object["roomMetadata"] as? [String: Any] ?? [:])
        }
    }

    struct MintedToken: Decodable { let token: String; let url: String }

    enum CallError: LocalizedError {
        case rejected, service(Int), badResponse
        var errorDescription: String? {
            switch self {
            case .rejected: "Voice service rejected the key."
            case .service(let code): "Voice service error (\(code)). Try again."
            case .badResponse: "Voice service sent an unexpected reply."
            }
        }
    }

    /// How the voice agent relays requests: the user's own words, never invented names, and no message sent
    /// before the user confirms. The phone agent sees the screen and remembers earlier requests of the call.
    nonisolated static let controlPhoneDescription = """
Operate the user's iPhone like a person: open apps, tap, type, scroll, read the screen, message people. Call it \
right away for every phone request; each call replaces anything still running (never call stop_phone_task first). \
The phone agent sees the screen and remembers the earlier requests of this call, so pass the user's words \
VERBATIM, in the user's language and script: never translate, paraphrase or transliterate. After them, add in \
[brackets] only referents you resolved from this conversation, e.g. [the person whose chat is open]. Never \
invent or guess a name: if the user did not say one, refer to people on screen as "the open chat". A message is \
typed first and the phone asks before sending: ask the user "Shall I send it?" and only on yes call again with \
"send it [the user confirmed sending]". \
Tell the user only what the tool result says happened.
"""
    nonisolated static let instructionDescription = """
The user's request word for word in their language and script, then any resolved referents in [brackets]. \
Examples: اكتب له مرحبا [the person whose chat is open] | send it [the user confirmed sending] | \
Open WhatsApp and type "Hi" to مهند
"""

    /// The room metadata: the config's extra fields, then the client tools the agent calls over LiveKit RPC
    /// ("client_tool_call" with {tool, arguments}, answered with {response}).
    nonisolated static func roomMetadata(_ config: VoiceAgentConfig, identity: String) -> [String: Any] {
        config.roomMetadata.merging([
            "client_tools": [
                "participant_identity": identity,
                "tools": [
                    [
                        "name": "control_phone",
                        "description": Self.controlPhoneDescription,
                        "parameters": ["type": "object", "properties": ["instruction": ["type": "string", "description": Self.instructionDescription]], "required": ["instruction"]],
                    ],
                    [
                        "name": "stop_phone_task",
                        "description": "Stop whatever the phone is doing right now. Only when the user explicitly asks to stop or cancel; a new control_phone call already replaces the previous task.",
                        "parameters": ["type": "object", "properties": [String: Any]()],
                    ],
                ],
            ],
        ]) { _, ours in ours }
    }

    nonisolated static func mintToken(config: VoiceAgentConfig, identity: String, roomName: String) async throws -> MintedToken {
        let body: [String: Any] = ["identity": identity, "roomName": roomName, "agentName": config.agentName,
                                   "roomMetadata": roomMetadata(config, identity: identity)]
        var request = URLRequest(url: config.tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey):\(config.apiSecret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw CallError.rejected }
        guard (200..<300).contains(status) else { throw CallError.service(status) }
        guard let minted = try? JSONDecoder().decode(MintedToken.self, from: data), !minted.token.isEmpty else { throw CallError.badResponse }
        return minted
    }

    nonisolated static func websocketURL(_ url: String) -> String {
        if url.hasPrefix("https://") { return "wss://" + url.dropFirst(8) }
        if url.hasPrefix("http://") { return "ws://" + url.dropFirst(7) }
        return url
    }

    private static func friendly(_ error: Error) -> String {
        if let error = error as? CallError { return error.localizedDescription }
        if error is URLError { return "Can't reach the voice service. Check your connection." }
        if let error = error as? LiveKitError {
            switch error.type {
            case .network, .timedOut: return "Can't reach the voice service. Check your connection."
            case .validation: return "Voice service rejected the call."
            default: break
            }
        }
        return "Couldn't start the call. Try again."
    }

    nonisolated private static func responseJSON(_ text: String) -> String { json(["response": text]) }
    nonisolated private static func errorJSON(_ message: String) -> String { json(["ok": false, "error": message]) }
    nonisolated private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class CallRoomEvents: NSObject, RoomDelegate, @unchecked Sendable {
    private let emit: @Sendable (CallController.Event) -> Void
    init(emit: @escaping @Sendable (CallController.Event) -> Void) { self.emit = emit }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        emit(.agentJoined(participant.attributes["lk.agent.state"]))
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        if participant.isAgent || room.remoteParticipants.values.allSatisfy({ $0.identity == participant.identity }) { emit(.agentLeft) }
    }

    func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        guard participant is RemoteParticipant, let state = participant.attributes["lk.agent.state"] else { return }
        emit(.agentState(state))
    }

    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        emit(.speaking(participants.contains { $0 is RemoteParticipant }))
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        emit(.disconnected(error.map { $0.message ?? "\($0.type)" }))
    }
}
