import Foundation
import AVFoundation

@MainActor final class RealtimeAudio: RealtimeAudioSink {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var active = false
    private var tapped = false
    private var scheduled = 0
    private var pending = 0
    private var playbackGeneration = UUID()
    let inbox = RealtimePCMInbox()
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP]); try session.setActive(true); active = true
        do {
            let engine = AVAudioEngine(); self.engine = engine
            try engine.inputNode.setVoiceProcessingEnabled(true)
            let format = engine.inputNode.outputFormat(forBus: 0)
            let converter = try RealtimePCMConverter(input: format)
            let inbox = self.inbox
            try engine.inputNode.installAudioTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                do { inbox.append(try converter.convert(AVAudioPCMBuffer(copying: buffer))) } catch { inbox.append(Data()) }
            }
            tapped = true
            let player = AVAudioPlayerNode(); self.player = player; engine.attach(player)
            let playback = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
            try engine.connectNode(player, to: engine.mainMixerNode, format: playback)
            engine.prepare(); try engine.start()
        } catch { stop(); throw error }
    }
    func play(_ data: Data) throws {
        let buffer = try RealtimePCMConverter.playback(data)
        guard let player, let engine, engine.isRunning, pending + Int(buffer.frameLength) <= 240000 else { throw AgentError.message("Realtime audio playback backed up or stopped; connection closed") }
        pending += Int(buffer.frameLength); scheduled += Int(buffer.frameLength)
        let token = playbackGeneration; let frames = Int(buffer.frameLength)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in guard let self, self.playbackGeneration == token else { return }; self.pending = max(0, self.pending - frames) }
        }
        if !player.isPlaying { try player.playAudio() }
    }
    var playedMilliseconds: Int {
        guard let player, let time = player.lastRenderTime, let position = player.playerTime(forNodeTime: time), position.sampleRate > 0 else { return 0 }
        let latency = AVAudioSession.sharedInstance().outputLatency + AVAudioSession.sharedInstance().ioBufferDuration
        return min(scheduled * 1000 / 24000, max(0, Int((Double(position.sampleTime) / position.sampleRate - latency) * 1000)))
    }
    var scheduledMilliseconds: Int { scheduled * 1000 / 24000 }
    var hasPending: Bool { pending > 0 }
    func clearPlayback() { playbackGeneration = UUID(); player?.stop(); scheduled = 0; pending = 0 }
    func stop() {
        inbox.close(); playbackGeneration = UUID(); player?.stop(); player = nil
        if let engine { if tapped { engine.inputNode.removeTap(onBus: 0) }; engine.stop() }; tapped = false; engine = nil; scheduled = 0; pending = 0
        if active { active = false; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
