import SwiftUI

struct PreparationView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    let navigate: (WorkspaceDestination) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Prepare Your First Task").font(.title2.weight(.semibold))
                    Text("Connect a model and the accessory so the assistant can understand your screen.").font(.subheadline).foregroundStyle(.secondary)
                    step(1, "Choose a Model Service", detail: "Use your own API key or set up a trusted compatible endpoint.", done: model.modelReady) { navigate(.settings) }
                    step(2, "Connect AgentMouse", detail: "Your iPhone needs to recognize the accessory as an AssistiveTouch mouse.", done: model.ble.ready || model.settings.previewOnly) { navigate(.device) }
                    step(3, "Calibrate Pointer", detail: "The assistant can tap accurately only after this accessory passes calibration.", done: model.calibrationReady || model.settings.previewOnly) { navigate(.device) }
                    step(4, "Confirm AI Data Use", detail: "Recipient: \(PrivacyConsent.recipient(model.settings)). Tasks send screen images, task text, and action summaries.", done: model.consentReady) { model.requestConsent() }
                    step(5, "Start Full-Screen Sharing", detail: "Choose the entire screen in the system prompt; you can stop sharing at any time.", done: model.capture.running && model.capture.frame?.fullDisplay == true) { navigate(.screenShare) }
                    if model.preparationReady {
                        Label("All set. Go back to Tasks to start", systemImage: "checkmark.circle").font(.headline)
                    }
                    Text("Requires iOS 27. Running a task needs the accessory, calibration, and full-screen sharing. Preview mode only proposes the first action.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("Setup").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Back to Tasks") { navigate(.tasks) } } }
        }.tint(AgentPalette.accent).agentSheetStyle()
    }
    private func step(_ number: Int, _ title: String, detail: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(AgentPalette.surface).frame(width: 36, height: 36)
                    if done { Image(systemName: "checkmark") } else { Text("\(number)").font(.subheadline.weight(.semibold)) }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0); Image(systemName: "chevron.right").foregroundStyle(.secondary).padding(.top, 10)
            }.frame(maxWidth: .infinity, alignment: .leading).agentPanel()
        }.buttonStyle(AgentPressStyle()).accessibilityLabel("Step \(number), \(title), \(done ? "done" : "not ready")")
    }
}
