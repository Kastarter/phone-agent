import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    private var busy: Bool { model.interactionBusy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AgentPageIntro(title: "Share Phone Screen", subtitle: "Let the assistant see your screen. You start it and can end it anytime.")
                HStack {
                    Circle().fill(model.capture.running ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                    Text(model.capture.state).font(.subheadline.weight(.medium))
                    Spacer()
                    if model.capture.running { Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(AgentPalette.accent) }
                }
                Group {
                    if let frame = model.capture.frame {
                        VStack(spacing: 12) {
                            Image(uiImage: frame.image).resizable().scaledToFit().frame(maxHeight: 390)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            HStack {
                                Text("\(frame.sourceWidth) × \(frame.sourceHeight)")
                                Spacer(); Text("\(model.capture.fps, specifier: "%.1f") FPS")
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(spacing: 18) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 27).stroke(AgentPalette.accent.opacity(0.20), lineWidth: 2).frame(width: 126, height: 220)
                                VStack(spacing: 14) {
                                    Image(systemName: "viewfinder").font(.system(size: 39, weight: .ultraLight)).foregroundStyle(AgentPalette.accent)
                                    Text("Waiting for screen").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 17)
                            Text("Share the full screen with the system picker").font(.subheadline.weight(.medium))
                            Text("The assistant can still see the screen after you switch to other apps.")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity)
                    }
                }.agentPanel()
                if model.capture.running {
                    Button("Stop Screen Sharing", role: .destructive) { model.stop(); model.capture.stop() }.buttonStyle(AgentButtonStyle(primary: false))
                } else {
                    Button { model.capture.start() } label: { Label("Share Full Screen", systemImage: "rectangle.on.rectangle") }
                        .buttonStyle(AgentButtonStyle()).disabled(model.capture.waitingForPicker || busy)
                }
                if !model.capture.error.isEmpty { AgentNotice(text: model.capture.error, error: true) }
                Text("Once a task starts, the screen is sent to your configured model. Stopping a task doesn't end sharing; protected content may appear blank.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 3)
            }.padding(20)
        }
    }
}
