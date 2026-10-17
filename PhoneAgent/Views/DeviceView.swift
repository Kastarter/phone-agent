import SwiftUI

struct DeviceView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    let onCalibration: () -> Void
    private var busy: Bool { model.interactionBusy }
    @State private var keyboardCheck = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AgentPageIntro(title: "Connect AgentMouse", subtitle: "The accessory handles taps and typing. Calibrate, then start controlling.")
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 15) {
                        Image(systemName: "computermouse.fill").font(.system(size: 32)).foregroundStyle(AgentPalette.accent)
                            .frame(width: 68, height: 68).background(AgentPalette.accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 22))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AgentMouse").font(.title3.weight(.semibold))
                            Text(model.ble.state).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.ble.ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    if model.ble.connected {
                        if model.ble.ready {
                            Text(model.ble.bufferedMotionReady ? "Mouse movement ready" : "Update the accessory firmware")
                                .font(.caption).foregroundStyle(.secondary)
                            Label(model.ble.keyboardReady ? "Bluetooth keyboard ready" :
                                (model.ble.status?.keyboardSupported == true ? "Waiting for the system to connect the keyboard" : "Accessory doesn't support keyboard yet"),
                                systemImage: "keyboard").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Label(model.ble.ready ? "Mouse ready" : "Connecting", systemImage: "circle.fill").font(.caption)
                            Spacer()
                            Button("Refresh") { model.ble.refresh() }
                            Button("Disconnect", role: .destructive) { model.stop(); Task { await model.ble.release(); model.ble.disconnect() } }
                        }.font(.caption)
                    } else {
                        Button(model.ble.scanning ? "Stop Searching" : "Connect AgentMouse") {
                            if model.ble.scanning { model.ble.stopScan() } else { model.ble.scan() }
                        }.buttonStyle(AgentButtonStyle()).disabled(busy)
                        ForEach(model.ble.devices) { device in
                            Button { model.ble.connect(device) } label: {
                                HStack { Label(device.name, systemImage: "dot.radiowaves.left.and.right"); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                                    .font(.subheadline).frame(minHeight: 48)
                            }.disabled(busy)
                        }
                    }
                    if !model.ble.error.isEmpty { AgentNotice(text: model.ble.error, error: true) }
                }.padding(20).background(AgentPalette.inset, in: RoundedRectangle(cornerRadius: 18))
                if !model.ble.ready {
                    DisclosureGroup("Connection Help") { VStack(alignment: .leading, spacing: 14) {
                        AgentSectionTitle(title: "First Connection", subtitle: "System pairing and app connection are two steps; you usually only do this once.")
                        connectionStep(1, "Pair in iOS", "Settings → Accessibility → Touch → AssistiveTouch → Devices → Bluetooth Devices, then select AgentMouse. Tap “Pair” when asked.")
                        connectionStep(2, "Return to Phone Agent", "After pairing, come back here and tap “Connect AgentMouse”. Start calibration once you see “Mouse ready”.")
                        connectionStep(3, "Connection Timeout", "Make sure the accessory is charged and iPhone Bluetooth is on. Right after pairing, you can turn AssistiveTouch off and on, then retry here.")
                        Link("View Apple's pointer device guide", destination: URL(string: "https://support.apple.com/en-us/111775")!)
                            .font(.footnote.weight(.medium))
                    }.padding(.top, 12) }.agentPanel()
                }
                VStack(alignment: .leading, spacing: 15) {
                    AgentSectionTitle(title: "Make Every Tap Accurate", subtitle: "Calibrate on first use or after changing pointer speed.")
                    if let c = model.executor.calibration {
                        HStack {
                            Label(model.calibrationReady ? "Accessory calibrated" : "Accessory needs calibration", systemImage: "scope").foregroundStyle(AgentPalette.accent)
                        }.font(.footnote)
                        if model.calibrationReady { Text("Max error \(c.validationError, specifier: "%.1f") pt").font(.caption).foregroundStyle(.secondary) }
                    }
                    Button(model.calibrationReady ? "Recalibrate" : "Start Calibration") { onCalibration() }.buttonStyle(AgentButtonStyle(primary: false)).disabled(!model.ble.ready || busy || model.executor.calibrationInProgress)
                    Button("Check Keyboard") { keyboardCheck = true }.buttonStyle(AgentButtonStyle(primary: false))
                        .disabled(!model.ble.keyboardReady || busy || model.executor.calibrationInProgress)
                    DisclosureGroup("Before Calibrating") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Stay in portrait and don't touch the screen during the \(CalibrationSolver.probeSteps)-step calibration.")
                            Text("Each move returns to the top-left corner, then moves diagonally. Turn off “Snap to Item” and keep pointer speed fixed.")
                            if let c = model.executor.calibration, model.calibrationReady, let rms = c.validationRMS, let drift = c.returnDrift {
                                Text("Last calibration: RMS \(rms, specifier: "%.1f") pt · round-trip drift \(drift, specifier: "%.1f") pt")
                            }
                        }.font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                    }.font(.subheadline)
                }.padding(20).background(AgentPalette.inset, in: RoundedRectangle(cornerRadius: 18))
                if !model.notice.isEmpty { AgentNotice(text: model.notice) }

            }.padding(20)
        }.fullScreenCover(isPresented: $keyboardCheck) { KeyboardCheckView(model: .init(executor: model.executor)) }
    }
    private func connectionStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 24, height: 24).background(AgentPalette.surface, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
