import Foundation
import AVFoundation

final class RealtimePCMInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    private var bytes = 0
    private var open = true
    private var issue = false
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; guard open else { return }; guard !data.isEmpty, data.count % 2 == 0, data.count <= 48000, bytes + data.count <= 96000 else { issue = true; open = false; packets = []; bytes = 0; return }; packets.append(data); bytes += data.count }
    func pop() -> Data? { lock.lock(); defer { lock.unlock() }; guard open, !packets.isEmpty else { return nil }; let data = packets.removeFirst(); bytes -= data.count; return data }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return issue }
    func close() { lock.lock(); defer { lock.unlock() }; open = false; packets = []; bytes = 0 }
}
// AVAudioConverter is only accessed by its capture tap. This helper also accepts synthetic buffers.
final class RealtimePCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    let output: AVAudioFormat
    init(input: AVAudioFormat) throws {
        guard input.sampleRate.isFinite, (8000...192000).contains(input.sampleRate), (1...8).contains(input.channelCount),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { throw AgentError.message("Can't convert microphone input to 24 kHz mono PCM") }
        self.output = output; self.converter = converter; self.inputFormat = input
    }
    func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        guard input.format == inputFormat, input.frameLength > 0, input.frameLength <= 8192 else { throw AgentError.message("Microphone buffer out of range") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24000 / input.format.sampleRate) + 32)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { throw AgentError.message("Can't prepare realtime audio buffer") }
        var used = false; var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, outputStatus in
            if used { outputStatus.pointee = .noDataNow; return nil }; used = true; outputStatus.pointee = .haveData; return input
        }
        guard error == nil, status != .error, let samples = buffer.int16ChannelData, buffer.frameLength > 0 else { throw AgentError.message("Realtime audio conversion failed") }
        return Data(bytes: samples[0], count: Int(buffer.frameLength) * 2)
    }
    static func playback(_ data: Data) throws -> AVAudioPCMBuffer {
        guard !data.isEmpty, data.count % 2 == 0, data.count <= 240000,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)), let samples = buffer.floatChannelData else { throw AgentError.message("Invalid realtime playback PCM") }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { bytes in
            for index in 0..<Int(buffer.frameLength) { let sample = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)); samples[0][index] = Float(sample) / 32768 }
        }
        return buffer
    }
}
