import SwiftUI
import AppIntents

private enum SettingsPage: String, Hashable {
    case model = "Model Connection", behavior = "Execution Preferences", floating = "Action Overlay"
    case siri = "Siri & Shortcuts", privacy = "Privacy & Data", about = "How It Works"
    case search = "Web Search"
}

struct SettingsView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(AgentTheme.storageKey) private var appearance = AgentTheme.system.rawValue
    var reviewPage: String? = nil
    @State private var path: [SettingsPage] = []
    let onBack: () -> Void
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var checking = false
    @State private var providerSelection = "custom"
    @State private var advancedConnection = false
    @State private var clearHistory = false
    @State private var revoke = false
    @State private var connectionMessage = ""
    @State private var connectionFailed = false
    private var locked: Bool { model.engine.running || model.engine.releasing || model.voicePending }
    private var modelSummary: String {
        model.modelReady ? "\(PrivacyConsent.recipient(model.settings)) · \(model.settings.model)" : "Connect your AI service"
    }
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                GlassEffectContainer(spacing: 8) {
                    VStack(alignment: .leading, spacing: 26) {
                        settingsGroup("Connection") {
                            route(.model, subtitle: modelSummary, icon: "sparkles")
                            groupDivider
                            route(.search, subtitle: "Service, key, and sources", icon: "globe")
                        }
                        settingsGroup("Assistant") {
                            route(.behavior, subtitle: "Pacing and confirmations", icon: "slider.horizontal.3")
                            groupDivider
                            route(.floating, subtitle: model.settings.autoPiPOnExit == true ? "Opens automatically when you leave" : "See task status in other apps", icon: "pip")
                            groupDivider
                            route(.siri, subtitle: "Voice and Shortcuts", icon: "waveform")
                        }
                        settingsGroup("Display") {
                            HStack(spacing: 8) {
                                AgentSettingsRow(title: "Appearance", subtitle: "", icon: "circle.lefthalf.filled")
                                Picker("Appearance", selection: $appearance) {
                                    ForEach(AgentTheme.allCases) { theme in Text(theme.title).tag(theme.rawValue) }
                                }
                                .labelsHidden().pickerStyle(.menu).tint(.primary)
                                .accessibilityLabel("Appearance")
                            }
                            .frame(minHeight: 72)
                        }
                        settingsGroup("About") {
                            route(.privacy, subtitle: model.consentReady ? "Current service authorized" : "Manage consent and local records", icon: "hand.raised")
                            groupDivider
                            route(.about, subtitle: "Capabilities and requirements", icon: "questionmark.circle")
                        }
                        Label("API keys are stored in this device's Keychain", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                            .padding(.horizontal, 16)
                    }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 28)
                }
            }.background(AgentPalette.background)
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: onBack) { Image(systemName: "xmark").frame(width: 32, height: 32) }.tint(.primary).accessibilityLabel("Close Settings")
                    }
                }
            .navigationDestination(for: SettingsPage.self) { page in
                detail(page)
                    .navigationTitle(page.rawValue).navigationBarTitleDisplayMode(.inline)
            }
        }
        .tint(AgentPalette.accent)
        .confirmationDialog("Delete all tasks and action records?", isPresented: $clearHistory, titleVisibility: .visible) {
            Button("Delete All History", role: .destructive) { model.clearHistory() }
        }
        .confirmationDialog("Revoking stops tasks and screen sharing.", isPresented: $revoke, titleVisibility: .visible) {
            Button("Revoke AI Data Consent", role: .destructive) { model.revokeConsent() }
        }
        .onAppear {
            apiKey = SettingsStore.apiKey(); providerSelection = inferredService
            #if DEBUG
            if let reviewPage, path.isEmpty {
                let pages: [String: SettingsPage] = ["model": .model, "behavior": .behavior, "floating": .floating, "siri": .siri, "privacy": .privacy, "about": .about, "search": .search]
                if let page = pages[reviewPage] { path = [page] }
            }
            #endif
        }
        .onChange(of: model.settings.endpoint) { _, _ in
            apiKey = SettingsStore.apiKey(for: model.settings.endpoint)
            connectionMessage = ""
        }
    }
    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                .padding(.horizontal, 16).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .agentGlass(in: AgentInputMetrics.shape)
        }
    }
    private var groupDivider: some View { Divider().padding(.leading, 38) }
    private func route(_ page: SettingsPage, subtitle: String, icon: String) -> some View {
        NavigationLink(value: page) {
            HStack(spacing: 8) {
                AgentSettingsRow(title: page.rawValue, subtitle: page == .model || page == .floating ? subtitle : "", icon: icon)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }.frame(minHeight: 72).contentShape(Rectangle())
        }.buttonStyle(AgentPressStyle())
    }
    private func detail(_ page: SettingsPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch page {
                case .model: connection.disabled(locked || checking)
                case .search: WebSearchSettingsView(embedded: true)
                case .behavior: preferences.disabled(locked)
                case .floating: floatingWindow
                case .siri: siri
                case .privacy: privacy
                case .about: about
                }
                if locked && [.model, .behavior].contains(page) {
                    AgentNotice(text: "You can change these settings after the task ends or is paused.")
                }
            }.padding(20)
        }.background(AgentPalette.background).scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .onDisappear { showKey = false }
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Phone tasks, screen reading, and camera chat need a vision-capable model on an OpenAI-compatible endpoint. Bedrock works for chat, notes, and search answers.")
                .font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
            AgentCard {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Provider").font(.subheadline.weight(.medium))
                        Spacer()
                        Picker("Provider", selection: Binding(get: { providerSelection }, set: { chooseService($0) })) {
                            Text("OpenRouter").tag("openrouter")
                            Text("AWS Bedrock").tag("bedrock")
                            Text("OpenAI").tag("openai")
                            Text("Custom Endpoint").tag("custom")
                        }.labelsHidden().pickerStyle(.menu)
                    }
                    if providerSelection == "custom" {
                        field("Provider Name") {
                            TextField("e.g. My Provider", text: Binding(get: { model.settings.providerName ?? "" }, set: { model.settings.providerName = $0 }), prompt: Text("e.g. My Provider").foregroundStyle(AgentPalette.placeholder))
                                .agentField().accessibilityLabel("Provider Name")
                        }
                    }
                    field("Endpoint URL") {
                        TextField("https://example.com/v1/chat/completions", text: $model.settings.endpoint, prompt: Text("https://example.com/v1/chat/completions").foregroundStyle(AgentPalette.placeholder), axis: .vertical)
                            .lineLimit(1...3).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .agentField().accessibilityLabel("Model endpoint URL")
                    }
                    if providerSelection == "openrouter" {
                        field("Model") {
                            Picker("Model", selection: $model.settings.model) {
                                Text("GPT-6 Luna (most accurate)").tag("openai/gpt-6-luna")
                                Text("GLM-5.3 Flash (fastest)").tag("z-ai/glm-5.3-flash")
                                Text("Gemini 3.8 Flash").tag("google/gemini-3.8-flash")
                                if !["openai/gpt-6-luna", "z-ai/glm-5.3-flash", "google/gemini-3.8-flash"].contains(model.settings.model) { Text("Custom: \(model.settings.model)").tag(model.settings.model) }
                            }.pickerStyle(.menu).accessibilityLabel("OpenRouter model")
                        }
                    }
                    if providerSelection == "bedrock" {
                        field("Bedrock Model") {
                            Picker("Bedrock Model", selection: $model.settings.model) {
                                ForEach(BedrockClient.models, id: \.id) { Text($0.label).tag($0.id) }
                                if !BedrockClient.models.contains(where: { $0.id == model.settings.model }) { Text("Custom: \(model.settings.model)").tag(model.settings.model) }
                            }.pickerStyle(.menu).accessibilityLabel("Bedrock Model")
                        }
                    }
                    field("Model ID") {
                        TextField("Enter the provider's model ID", text: $model.settings.model, prompt: Text("Enter the provider's model ID").foregroundStyle(AgentPalette.placeholder))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .agentField().accessibilityLabel("Model ID")
                    }
                    field(providerSelection == "bedrock" ? "AWS Credentials" : "API Key") {
                        HStack(spacing: 8) {
                            let keyHint = providerSelection == "bedrock" ? "Paste credentials JSON" : "Paste API Key"
                            Group {
                                if showKey { TextField(keyHint, text: $apiKey, prompt: Text(keyHint).foregroundStyle(AgentPalette.placeholder)) }
                                else { SecureField(keyHint, text: $apiKey, prompt: Text(keyHint).foregroundStyle(AgentPalette.placeholder)) }
                            }.textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("API Key")
                            Button { showKey.toggle() } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye").frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel(showKey ? "Hide API Key" : "Show API Key")
                        }.agentField()
                    }
                    Text(providerSelection == "bedrock"
                         ? "On the Mac, run scripts/bedrock-credentials.sh. It copies 12-hour AWS credentials to the clipboard; paste them here with Universal Clipboard, then Save. Run it again when they expire."
                         : "The model endpoint must be a valid HTTPS URL. Enter the full Chat Completions URL.")
                        .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                }.font(.subheadline)
            }
            GlassEffectContainer(spacing: 12) {
                let actionLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                actionLayout {
                    Button("Save") { model.saveKey(apiKey); connectionFailed = false; connectionMessage = model.notice }
                        .buttonStyle(AgentButtonStyle())
                    Button(checking ? "Connecting…" : "Test Connection") { checkConnection() }
                        .buttonStyle(AgentButtonStyle(primary: false))
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if !connectionMessage.isEmpty { AgentNotice(text: connectionMessage, error: connectionFailed) }
            AgentCard {
                DisclosureGroup("Compatibility & Response Length", isExpanded: $advancedConnection) {
                    VStack(alignment: .leading, spacing: 20) {
                        Toggle("JSON Mode", isOn: $model.settings.jsonMode).tint(AgentPalette.accent).padding(.trailing, 6)
                        Toggle("Use Legacy Token Parameter", isOn: $model.settings.legacyTokenLimit).tint(AgentPalette.accent).padding(.trailing, 6)
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Max Response Length").font(.subheadline.weight(.medium))
                            Stepper(value: Binding(get: { model.settings.responseTokenLimit }, set: { model.settings.maxResponseTokens = $0 }), in: 1024...16384, step: 1024) {
                                Text("\(model.settings.responseTokenLimit) tokens").monospacedDigit()
                            }
                        }
                        Text("The defaults work for most endpoints. Turn off JSON Mode if your provider doesn't support it. The length limit applies to chat, notes, and search answers.")
                            .font(.caption).foregroundStyle(AgentPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }.font(.subheadline).padding(.top, 20)
                }.font(.subheadline.weight(.medium))
            }
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentCard {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Task Execution").font(.headline)
                    Toggle(isOn: $model.settings.confirmEachStep) {
                        preferenceLabel("Confirm Each Step", value: "Review each action before it runs")
                    }.tint(AgentPalette.accent)
                    Divider()
                    Toggle(isOn: $model.settings.previewOnly) {
                        preferenceLabel("Plan Only", value: "Observe once and suggest the next step")
                    }.tint(AgentPalette.accent)
                }
            }
            AgentCard {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Pacing").font(.headline)
                    Stepper(value: $model.settings.maxSteps, in: 1...100) { preferenceLabel("Max Actions", value: "\(model.settings.maxSteps) steps") }
                    Divider()
                    Stepper(value: $model.settings.startDelay, in: 0...10, step: 1) { preferenceLabel("Start Delay", value: "\(Int(model.settings.startDelay)) s · if the app can't leave by itself") }
                }
            }
            AgentCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Image Quality").font(.headline)
                    Picker("Upload Image Quality", selection: $model.settings.imageMaxSide) {
                        Text("Standard").tag(960); Text("Sharp").tag(1280); Text("Fine").tag(1920)
                    }.pickerStyle(.segmented)
                    Text("Finer images help read small text but increase upload size and model usage.")
                        .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                }
            }
            DisclosureGroup("Status Display") {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("Show Task Status in Live Activity", isOn: Binding(get: { model.settings.liveTaskStatus == true }, set: { model.settings.liveTaskStatus = $0 })).tint(AgentPalette.accent)
                    Text("Shows steps and status on the Lock Screen and supported Dynamic Island, where you can pause or stop the current task; the system may ask you to authenticate first. Return to the app to resume or add instructions. If status hasn't updated for 60 seconds, you'll be asked to check. Does not add background run time.") .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                    if !model.taskActivity.error.isEmpty { AgentNotice(text: model.taskActivity.error) }
                }.padding(.top, 16)
            }.font(.subheadline).agentPanel()

        }
    }
    private var floatingWindow: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "pip").font(.system(size: 44, weight: .light))
                .frame(maxWidth: .infinity).padding(.vertical, 24).accessibilityHidden(true)
            AgentCard {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("Open Automatically When Leaving the App", isOn: Binding(get: { model.settings.autoPiPOnExit ?? false }, set: { model.settings.autoPiPOnExit = $0 }))
                        .tint(AgentPalette.accent)
                    Text("When you switch apps or go to the Home Screen, the overlay shows the current action and task progress.")
                        .font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                }
            }
            Text("Allow automatic start in iOS Settings > General > Picture in Picture. If you close it manually, it will be ready again the next time you return to the app and leave. Not available if the app is force-quit.")
                .font(.footnote).foregroundStyle(AgentPalette.secondaryText)
        }
    }
    private var siri: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentPageIntro(title: "One Phrase to Get Started", subtitle: "Hey Siri, tell Phone Agent to get to work.", icon: "waveform")
            ShortcutsLink().shortcutsLinkStyle(.automaticOutline)
                .frame(minHeight: AgentInputMetrics.height)
            AgentHelp(title: "Set a Phrase for Frequent Tasks", text: "Add \"Run Phone Task\", fill in a fixed request, and name it with a phrase you like. You can also ask Siri to run the currently saved task, or say \"Stop Phone Agent's task\".")
            AgentHelp(title: "Speak Any Task", text: "Add \"Dictate Text\", then \"Run Phone Task\"; set its Task parameter to the dictated text and name the shortcut with a phrase you like. Say \"Hey Siri\" plus the phrase, then speak your task. It starts only once the screen, accessory, and calibration are ready; otherwise start full-screen sharing first. Voice requests wait up to 90 seconds.")
            AgentHelp(title: "Pause, Take Over, or Add Instructions", text: "You can say: pause Phone Agent's task, take over Phone Agent's task, add to Phone Agent's task, or resume Phone Agent's task. Adding instructions pauses first, then dictates; the task waits for you to resume, and resuming re-observes the screen. Phone Agent can't listen for a wake word while you're in other apps, so use a Siri phrase; while dictating in the app, you can say control words directly.")
            AgentHelp(title: "Manage the Queue by Voice", text: "Shortcut actions include \"Add Phone Task to Queue\", \"Run Phone Task First\", and \"Run Phone Task Queue\". A priority task pauses the current one only after it receives its input; to pause before dictating, add \"Pause Phone Task\" first.")
            DisclosureGroup("Set Your Own Wake Phrase") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("In Settings > Accessibility > Vocal Shortcuts, choose \"Tell the Assistant\" or the matching Siri request, enter \"Hey Assistant\", and follow the prompts to train it.")
                    Text("You can also set separate phrases for pause, take over, add, and resume. Wait for the wake response before speaking; these require an unlocked device and may open Phone Agent.")
                    Link("View Apple's Setup Guide", destination: URL(string: "https://support.apple.com/en-us/guide/iphone/iph7f242ea2c/ios")!).frame(minHeight: 44)
                }.font(.footnote).foregroundStyle(AgentPalette.secondaryText).padding(.top, 12)
            }.font(.subheadline).agentPanel()
            Toggle("Read Replies and Results Aloud", isOn: Binding(get: { model.settings.spokenFeedback ?? false }, set: { model.settings.spokenFeedback = $0 }))
                .tint(AgentPalette.accent).agentPanel()
            Text("Speech is recognized in English on device; if unavailable, type or use Shortcuts dictation. In-app continuous conversation ends when you leave the page or the app goes to the background.") .font(.caption).foregroundStyle(AgentPalette.secondaryText)
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentCard {
                VStack(alignment: .leading, spacing: 16) {
                    Label(model.consentReady ? "Current service authorized" : "Not authorized", systemImage: "hand.raised")
                        .font(.headline)
                    Text(PrivacyConsent.recipient(model.settings)).font(.title3.weight(.medium))
                    Text("The AI receives the screens, tasks, questions, transcripts, or file text you agree to send, plus related records. Memory is sent only when its switch is on.")
                        .font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                    Button("View Data Use Details") { model.showPrivacyPolicy = true }.frame(minHeight: 44)
                    if model.consentReady {
                        Button("Revoke AI Data Consent", role: .destructive) { revoke = true }.foregroundStyle(.red).frame(minHeight: 44)
                    } else if model.modelReady {
                        Button("Confirm AI Data Use") { model.requestConsent() }.buttonStyle(AgentButtonStyle())
                    } else {
                        NavigationLink(value: SettingsPage.model) { Text("Connect a Model Service First") }.buttonStyle(AgentButtonStyle())
                    }
                }
            }
            AgentCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Local Records").font(.headline)
                    Text("\(model.history.records.count) tasks saved").font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                    Button("Clear Task History", role: .destructive) { clearHistory = true }
                        .foregroundStyle(.red).frame(minHeight: 44).disabled(model.history.records.isEmpty || model.engine.running || model.engine.releasing || !model.taskQueue.items.isEmpty)
                    Text("Deleting local records doesn't delete data the provider has already received.")
                        .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                }
            }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentCard {
                VStack(alignment: .leading, spacing: 20) {
                    preferenceLabel("Screens You Share", value: "Observes the current page through system full-screen sharing. Protected content may not be captured.")
                    Divider()
                    preferenceLabel("Your Accessory", value: "AgentMouse sends Bluetooth mouse and keyboard input. Complex pages and very small targets can still affect accuracy.")
                    Divider()
                    preferenceLabel("Looks After Every Batch", value: "Sends up to six actions per look, checks the screen after them, and stops to ask when sign-in, permissions, or manual handling is needed.")
                }
            }
            Text("Requires iOS 27 and a compatible accessory. Typing uses the keyboard layouts Keyboard Check learned; run it again after adding a keyboard.")
                .font(.footnote).foregroundStyle(AgentPalette.secondaryText)
        }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(AgentPalette.secondaryText)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func preferenceLabel(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            Text(value).font(.caption).foregroundStyle(AgentPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var inferredService: String {
        let host = URLComponents(string: model.settings.endpoint)?.host ?? ""
        if host.hasPrefix("bedrock-runtime.") && host.hasSuffix(".amazonaws.com") { return "bedrock" }
        if host == "openrouter.ai" { return "openrouter" }
        if host == "api.openai.com" { return "openai" }
        return "custom"
    }
    private func chooseService(_ value: String) {
        guard value != providerSelection else { return }
        providerSelection = value; advancedConnection = false; connectionMessage = ""
        switch value {
        case "openrouter":
            model.settings.endpoint = "https://openrouter.ai/api/v1/chat/completions"
            model.settings.model = "openai/gpt-6-luna"; model.settings.providerName = nil
            model.settings.jsonMode = true; model.settings.legacyTokenLimit = false
        case "bedrock":
            model.settings.endpoint = BedrockClient.endpoint()
            model.settings.model = BedrockClient.models[0].id; model.settings.providerName = nil
            model.settings.jsonMode = true; model.settings.legacyTokenLimit = false
        case "openai":
            model.settings.endpoint = "https://api.openai.com/v1/chat/completions"
            model.settings.model = "gpt-6-luna"; model.settings.providerName = nil
            model.settings.jsonMode = true; model.settings.legacyTokenLimit = false
        default:
            model.settings.endpoint = ""; model.settings.model = ""; model.settings.providerName = nil
        }
        apiKey = ""; model.saveKey("")
    }
    private func checkConnection() {
        checking = true; connectionMessage = ""
        Task {
            defer { checking = false }
            do {
                try await VisionClient(settings: model.settings, apiKey: apiKey).checkConnection()
                connectionFailed = false; connectionMessage = "Connected. Vision and action support will be confirmed during a real task."
            } catch { connectionFailed = true; connectionMessage = error.localizedDescription }
        }
    }
}
