import SwiftUI
import AppIntents

@main
struct PhoneAgentApp: App {
    @StateObject private var viewModel = PhoneAgentViewModel.shared

    init() {
        PhoneAgentShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(viewModel)
                .agentTheme()
                .onOpenURL { viewModel.handleDeviceRunURL($0) }
        }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if let reviewPage {
            PhoneAgentReviewPage(name: reviewPage)
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }

    #if DEBUG
    private var reviewPage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--ui-page"),
              arguments.indices.contains(flag + 1) else {
            return nil
        }
        return arguments[flag + 1]
    }
    #endif
}
