import SwiftUI

// Top-bar entry point; observes the call so the glyph reflects an active call while minimized.
struct CallBarButton: View {
    @ObservedObject var call: CallController
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: call.isActive ? "phone.fill" : "phone")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(call.isActive ? AgentPalette.positive : Color.primary)
                .frame(width: 44, height: 44)
                .agentGlass(in: Circle(), interactive: true)
                .contentTransition(.symbolEffect(.replace))
        }.buttonStyle(AgentPressStyle()).tint(.primary)
            .accessibilityLabel(call.isActive ? "Return to call" : "Call the agent")
    }
}

struct CallView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @ObservedObject var call: CallController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var recentCaptions: [CallController.Caption] { Array(call.captions.suffix(3)) }
    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                CallOrb(phase: call.phase, active: call.isActive).frame(width: 200, height: 200)
                VStack(spacing: 6) {
                    status
                    if call.isActive, let startedAt = call.startedAt {
                        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                            .font(.subheadline.monospacedDigit()).foregroundStyle(AgentPalette.secondaryText)
                    }
                }.padding(.horizontal, 24)
            }
            Spacer(minLength: 24)
            captions
            controls
        }
        .background(AgentBackdrop())
        .tint(AgentPalette.accent)
        .onChange(of: call.phase) { _, phase in
            guard phase == .ended else { return }
            Task {
                try? await Task.sleep(for: .seconds(1))
                if call.phase == .ended { dismiss() }
            }
        }
    }
    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44)
                    .agentGlass(in: Circle(), interactive: true)
            }.buttonStyle(AgentPressStyle()).tint(.primary)
                .accessibilityLabel("Minimize call").accessibilityHint("The call keeps running while you watch the agent work")
            Spacer(minLength: 8)
        }
        .overlay { Text("Voice Agent").font(.headline).lineLimit(1) }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
    @ViewBuilder private var status: some View {
        switch call.phase {
        case .working(let instruction):
            Text("Working: " + instruction).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.tail)
        case .failed(let message):
            Text(message).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center).lineLimit(3)
        default:
            Text(statusTitle).font(.title3.weight(.semibold)).lineLimit(1)
        }
    }
    private var statusTitle: String {
        switch call.phase {
        case .idle: "Ready"
        case .connecting: "Connecting…"
        case .listening: "Listening"
        case .thinking: "Thinking…"
        case .speaking: "Speaking"
        case .working: "Working"
        case .ended: "Call ended"
        case .failed: "Call failed"
        }
    }
    private var captions: some View {
        VStack(spacing: 10) {
            ForEach(recentCaptions) { caption in
                Text(caption.text)
                    .font(.subheadline).lineSpacing(3).lineLimit(3)
                    .foregroundStyle(caption.fromAgent ? AgentPalette.secondaryText : AgentPalette.placeholder)
                    .multilineTextAlignment(caption.fromAgent ? .leading : .trailing)
                    .frame(maxWidth: .infinity, alignment: caption.fromAgent ? .leading : .trailing)
                    .padding(caption.fromAgent ? .trailing : .leading, 36)
                    .transition(.opacity)
                    .accessibilityLabel((caption.fromAgent ? "Agent: " : "You: ") + caption.text)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .bottom)
        .padding(.horizontal, 24).padding(.bottom, 24)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: recentCaptions)
    }
    private var controls: some View {
        GlassEffectContainer(spacing: 24) {
            HStack(alignment: .top, spacing: 44) {
                control(call.muted ? "Unmute" : "Mute") {
                    Button { Task { await call.toggleMute() } } label: {
                        Image(systemName: call.muted ? "mic.slash.fill" : "mic.fill").contentTransition(.symbolEffect(.replace))
                    }.buttonStyle(AgentCircleButtonStyle()).disabled(!call.isActive)
                        .accessibilityLabel(call.muted ? "Unmute microphone" : "Mute microphone")
                }
                control(call.isActive ? "End" : "Close") {
                    Button(role: .destructive) {
                        if call.isActive { model.endCall() }
                        dismiss()
                    } label: {
                        Image(systemName: "phone.down.fill").font(.system(size: 23, weight: .regular))
                            .foregroundStyle(Color.white).frame(width: 62, height: 62)
                            .background(Color.red, in: Circle())
                    }.buttonStyle(AgentPressStyle())
                        .accessibilityLabel(call.isActive ? "End call" : "Close call")
                }
            }
        }
        .padding(.bottom, 28)
    }
    private func control<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            content()
            Text(title).font(.caption).foregroundStyle(AgentPalette.secondaryText).accessibilityHidden(true)
        }
    }
}

// Concentric halos breathe with the call: slow while listening, quicker while speaking.
private struct CallOrb: View {
    let phase: CallController.Phase
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var icon: String {
        switch phase {
        case .idle, .connecting: "phone.connection"
        case .listening: "mic"
        case .thinking: "ellipsis"
        case .speaking: "waveform"
        case .working: "computermouse"
        case .ended: "phone.down"
        case .failed: "exclamationmark"
        }
    }
    private var tint: Color {
        switch phase {
        case .listening, .speaking, .working: AgentPalette.accent
        case .failed: .red
        default: AgentPalette.ink
        }
    }
    private var tempo: (speed: Double, depth: Double) {
        switch phase {
        case .speaking: (4.2, 1)
        case .working: (2.6, 0.8)
        case .thinking: (2.2, 0.6)
        case .listening: (1.4, 0.7)
        case .connecting: (1.8, 0.4)
        default: (1, 0)
        }
    }
    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !active)) { context in
            let wave = reduceMotion || !active ? 0 : (sin(context.date.timeIntervalSinceReferenceDate * tempo.speed) + 1) / 2 * tempo.depth
            ZStack {
                Circle().fill(tint.opacity(0.08)).scaleEffect(0.86 + 0.14 * wave)
                Circle().fill(tint.opacity(0.12)).scaleEffect(0.72 + 0.08 * wave)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(tint)
                    .frame(width: 104, height: 104)
                    .agentGlass(in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.variableColor, isActive: phase == .speaking && !reduceMotion)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: phase)
        .accessibilityHidden(true)
    }
}
