import Foundation
import Combine
import AVFoundation
import CoreImage
import UIKit

// Configuration, capture and shutdown all run on the same serial queue.
private final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "phoneagent.camera")
    private let context = CIContext()
    private var lastFrame = 0.0
    let onFrame: @Sendable (ScreenFrame, CameraObservationFrame) -> Void
    let onError: @Sendable (String) -> Void
    init(onFrame: @escaping @Sendable (ScreenFrame, CameraObservationFrame) -> Void, onError: @escaping @Sendable (String) -> Void) { self.onFrame = onFrame; self.onError = onError }
    func start() {
        queue.async { [self] in
            do {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw AgentError.message("No camera available on this device") }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                session.beginConfiguration(); session.sessionPreset = .hd1280x720
                guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); throw AgentError.message("Camera can't start capturing") }
                session.addInput(input); session.addOutput(output)
                if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                session.commitConfiguration(); session.startRunning()
            } catch { onError(error.localizedDescription) }
        }
    }
    func stop() { queue.async { [self] in session.stopRunning(); if let output = session.outputs.first as? AVCaptureVideoDataOutput { output.setSampleBufferDelegate(nil, queue: nil) } } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame > 0.5, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }; lastFrame = now
        let ci = CIImage(cvPixelBuffer: pixel)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return }
        let image = UIImage(cgImage: cg)
        guard let jpeg = image.jpegData(compressionQuality: 0.75) else { return }
        let date = Date()
        let scale = min(1, 640 / max(ci.extent.width, ci.extent.height))
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let sample = context.createCGImage(small, from: small.extent), let smallJPEG = UIImage(cgImage: sample).jpegData(compressionQuality: 0.6) else { return }
        onFrame(ScreenFrame(image: image, jpeg: jpeg, capturedAt: date, sourceWidth: cg.width, sourceHeight: cg.height, fullDisplay: false),
                CameraObservationFrame(jpeg: smallJPEG, capturedAt: date, capturedUptime: now, width: sample.width, height: sample.height))
    }
}

@MainActor
final class CameraService: ObservableObject {
    @Published private(set) var frame: ScreenFrame?
    @Published private(set) var running = false
    @Published private(set) var preparing = false
    @Published private(set) var error = ""
    private var generation = UUID()
    private var capture: CameraCapture?
    private var permission: Task<Void, Never>?
    private var sequenceEnabled = false
    private var window = CameraObservationWindow()
    func setSequenceEnabled(_ enabled: Bool) { sequenceEnabled = enabled; if !enabled { window.clear() } }
    func sequence() -> [CameraObservationFrame] { window.selected(now: ProcessInfo.processInfo.systemUptime) }
    func start() {
        guard !running, !preparing else { return }
        stop(); let token = generation; preparing = true; error = ""
        permission = Task { [weak self] in
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard let self, token == self.generation, !Task.isCancelled else { return }
            guard allowed else { self.preparing = false; self.error = "Allow camera access in Settings"; return }
            let capture = CameraCapture(onFrame: { [weak self] frame, sample in
                Task { @MainActor in
                    guard let self, token == self.generation else { return }; self.frame = frame; self.running = true; self.preparing = false
                    if self.sequenceEnabled { self.window.append(sample, now: ProcessInfo.processInfo.systemUptime) }
                }
            }, onError: { [weak self] error in
                Task { @MainActor in guard let self, token == self.generation else { return }; self.stop(); self.error = error }
            })
            self.capture = capture; capture.start()
        }
    }
    func stop() { generation = UUID(); permission?.cancel(); permission = nil; capture?.stop(); capture = nil; frame = nil; running = false; preparing = false; window.clear(); sequenceEnabled = false }
}
