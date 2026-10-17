import SwiftUI
import UniformTypeIdentifiers

struct WebSearchSettingsView: View {
    var embedded = false
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @FocusState private var keyFocused: Bool
    @State private var savedConfig = WebSearchStore.load()
    @State private var savedKey = ""
    @State private var confirmingDiscard = false
    @State private var pendingProvider: WebSearchProvider?
    private var hasChanges: Bool { config != savedConfig || key != savedKey }
    @State private var config = WebSearchStore.load()
    @State private var key = ""
    @State private var message = ""
    @State private var failed = false
    var body: some View {
        Group {
            if embedded { content } else { ScrollView { content } }
        }.onAppear { savedConfig = config; savedKey = WebSearchStore.key(config.provider); key = savedKey }
            .onChange(of: config.provider) { _, value in savedKey = WebSearchStore.key(value); key = savedKey; message = "" }
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled(hasChanges)
            .navigationBarBackButtonHidden(embedded && hasChanges)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Dismiss Keyboard") { keyFocused = false } }
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { requestClose() } }
                } else if hasChanges {
                    ToolbarItem(placement: .topBarLeading) { Button { requestClose() } label: { Image(systemName:"chevron.left") }.accessibilityLabel("Back to Settings") }
                }
            }
            .alert("Discard unsaved search settings?", isPresented: $confirmingDiscard) {
                Button("Keep Editing", role: .cancel) { pendingProvider = nil }
                Button("Discard Changes", role: .destructive) {
                    if let provider = pendingProvider { pendingProvider = nil; config.provider = provider }
                    else { finishClose() }
                }
            } message: {
                Text(pendingProvider == nil ? "The current changes haven't been saved. Keep editing to save them; leaving discards the changes on this page." : "This service's key has been changed but not saved. Switching services discards this entry; the other settings are kept.")
            }
    }
    private var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                AgentPageIntro(title: "Connect a Search Service", subtitle: "Use a dedicated search key to find sourced information.", icon: "globe")
                AgentCard {
                    VStack(alignment: .leading, spacing: 18) {
                        LabeledContent("Search Service") { Picker("", selection: Binding(get: { config.provider }, set: { selectProvider($0) })) { ForEach(WebSearchProvider.allCases) { Text($0.title).tag($0) } }.labelsHidden() }
                        LabeledContent("Default Time Range") { Picker("", selection: $config.freshness) { ForEach(WebSearchFreshness.allCases) { Text($0.title).tag($0) } }.labelsHidden() }
                        Text(config.provider.endpoint.absoluteString).font(.caption).textSelection(.enabled).foregroundStyle(AgentPalette.secondaryText)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Search Service API Key").font(.caption).foregroundStyle(AgentPalette.secondaryText)
                            SecureField("Enter this service's key", text: $key, prompt: Text("Enter this service's key").foregroundStyle(AgentPalette.placeholder)).textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never).agentField()
                                .accessibilityLabel("Search Service API Key").focused($keyFocused)
                        }
                    }
                }
                Button("Save Search Settings") {
                    do { try WebSearchStore.saveKey(key, for: config.provider); WebSearchStore.save(config); savedConfig = config; savedKey = key; keyFocused = false; failed = false; message = key.isEmpty ? "Settings saved; this service's search key was cleared" : "Search settings saved" }
                    catch { failed = true; message = error.localizedDescription }
                }.buttonStyle(AgentButtonStyle())
                if !message.isEmpty { AgentNotice(text: message, error: failed) }
                Link("View the service's official docs", destination: config.provider.documentation).frame(minHeight: 44)
                AgentHelp(title: "Data and Quota", text: "Model planning sends this question, the default time condition, and the current time; it does not search automatically. A search sends the query terms, time filter, and auth key; it does not send the screen, voice, conversation history, or on-device memory. When you tap to answer from sources, the question, the confirmed plan and completed count, and the displayed search excerpts or the body passages you select are sent to the currently authorized model. Each search consumes quota separately, so check your account quota and the service's policy.")
                AgentHelp(title: "Settings and Time Conditions", text: "Clearing the key and saving disables the current search service; switching services does not reuse another service's key. Saving settings does not start a request automatically. The time filter is handled by the service, which can't guarantee every result has a reliable publish date.")
            }.padding(embedded ? 0 : 24)
    }
    private func selectProvider(_ provider: WebSearchProvider) {
        guard provider != config.provider else { return }
        keyFocused = false
        if key != savedKey { pendingProvider = provider; confirmingDiscard = true }
        else { config.provider = provider }
    }
    private func requestClose() {
        keyFocused = false; pendingProvider = nil
        if hasChanges { confirmingDiscard = true } else { finishClose() }
    }
    private func finishClose() { if let onClose { onClose() } else { dismiss() } }
}

private struct SearchApproval: Identifiable {
    enum Kind { case search, plan, research, answer }
    let id = UUID()
    let kind: Kind
    let query: String
    let config: WebSearchSettings
    let batch: WebSearchBatch?
    let modelFingerprint: String
    var plan: WebSearchPlan? = nil
}
private struct PageReadTarget: Identifiable {
    let id = UUID()
    let batchID: UUID
    let source: WebSearchSource
}

struct WebSearchView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var config = WebSearchStore.load()
    @State private var query = ""
    @State private var batch: WebSearchBatch?
    @State private var answer: WebSearchAnswer?
    @State private var plan: WebSearchPlan?
    @State private var planQuestion = ""
    @State private var error = ""
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var state = ""
    @FocusState private var focusedField: String?
    @State private var showInvestigation = false
    @State private var showSettings = false
    @State private var approval: SearchApproval?
    @State private var pageTarget: PageReadTarget?
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    private var fingerprint: String { model.settings.endpoint + "|" + model.settings.model + "|" + PrivacyConsent.recipient(model.settings) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AgentPageIntro(title: "What do you want to know?", subtitle: "Search, verify the sources, then put the answer together.", icon: "magnifyingglass")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Search question or keywords").font(.caption).foregroundStyle(.secondary)
                        TextField("For example: today's tech news", text: $query, axis: .vertical).lineLimit(1...5).agentField().disabled(work != nil).focused($focusedField, equals: "query").accessibilityLabel("Search question or keywords")
                    }
                    LabeledContent("Time Range") { Picker("", selection: $config.freshness) { ForEach(WebSearchFreshness.allCases) { Text($0.title).tag($0) } }.labelsHidden().disabled(work != nil) }
                    Text("Current search service: \(config.provider.title)").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                    Button("Review Query Terms") { prepareSearch() }.buttonStyle(AgentButtonStyle()).disabled(work != nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Let AI Plan the Search") { preparePlan() }.buttonStyle(AgentButtonStyle(primary: false)).disabled(work != nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Button { cancel(); approval = nil; showInvestigation = true } label: { Label("Multi-Round Research", systemImage: "sparkle.magnifyingglass") }.frame(minHeight: 44).disabled(work != nil)
                    if let plan {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Search Plan Draft").font(.title3.bold())
                            ForEach(plan.queries.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Item \(index + 1) · \(plan.queries[index].reason)").font(.footnote).foregroundStyle(.secondary)
                                    Text("Query terms").font(.caption).foregroundStyle(.secondary)
                                    TextField("Query terms", text: planQuery(index), axis: .vertical).lineLimit(1...4).agentField().accessibilityLabel("Item \(index + 1) query terms").focused($focusedField, equals: "plan.\(index)")
                                    Picker("Item \(index + 1) time range", selection: planFreshness(index)) { ForEach(WebSearchFreshness.allCases) { Text($0.title).tag($0) } }
                                    if plan.queries.count > 1 { Button("Remove This Item", role: .destructive) { if self.plan?.queries.indices.contains(index) == true { self.plan?.queries.remove(at: index) } }.frame(minHeight: 44) }
                                }
                            }
                            if !plan.note.isEmpty { Text(plan.note).font(.footnote).textSelection(.enabled) }
                            Text("You can edit the keywords and time range. Once confirmed, this searches \(plan.queries.count) times in order, each consuming search quota; it won't add searches or call the model to answer on its own.") .font(.caption).foregroundStyle(.secondary)
                            Button("Review Plan and Search") { prepareResearch() }.buttonStyle(AgentButtonStyle(primary: false))
                        }.agentPanel().disabled(work != nil)
                    }
                    if work != nil { HStack { ProgressView(); Text(state); Spacer(); Button("Cancel") { cancel() } } }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if let batch {
                        Text("Search: \(batch.query)").font(.headline).textSelection(.enabled)
                        Text("\(batch.provider.title) · \(batch.retrievedAt.formatted(date: .abbreviated, time: .standard)) · \(batch.freshnessSummary)").font(.caption).foregroundStyle(.secondary)
                        if let applied = batch.plan {
                            Text("Plan completed \(batch.completedQueries ?? 0)/\(applied.queries.count) items\((batch.completedQueries ?? 0) < applied.queries.count ? " · only partial returned sources; not all searches finished" : "")").font(.footnote).foregroundStyle(.secondary)
                        }
                        if batch.sources.isEmpty { Text("No web excerpts are available. Adjust the keywords or time range and retry.") }
                        else {
                            Text("Search excerpts are used by default. You can separately confirm extracting one page's body text and choose which passage to answer from; the extraction isn't guaranteed to include the whole page. You open any link yourself.") .font(.caption).foregroundStyle(.secondary)
                            ForEach(batch.sources) { source in
                                VStack(alignment: .leading, spacing: 10) {
                                    Link("[\(source.id)] \(source.title)", destination: source.url).font(.headline).frame(minHeight: 44, alignment: .leading)
                                    Text(source.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                                    if let matched = source.matchedQueries { Text("From: " + matched.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary) }
                                    Text(source.excerpt).textSelection(.enabled)
                                    Text("Service-labeled date: \(source.publishedLabel ?? "not provided")\(source.excerptShortened ? " · excerpt shortened" : "")").font(.caption).foregroundStyle(.secondary)
                                    if let selected = source.pageExcerpt {
                                        Text("Current answer basis: selected page body").font(.headline)
                                        Text(selected.label).font(.caption).foregroundStyle(.secondary)
                                        Text(selected.text).textSelection(.enabled)
                                    }
                                    Button(source.pageExcerpt == nil ? "Read Page Body" : "View / Adjust Body Basis") { pageTarget = .init(batchID: batch.id, source: source) }.disabled(work != nil).frame(minHeight: 44)
                                }.agentPanel()
                            }
                            if batch.omitted > 0 { Text("Another \(batch.omitted) result(s) were unused: duplicates, missing a valid link / excerpt, or over the count limit.") .font(.caption).foregroundStyle(.secondary) }
                            Button("Answer From These Sources") { prepareAnswer(batch) }.buttonStyle(AgentButtonStyle(primary: false)).disabled(work != nil)
                        }
                        if let answer {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(answer.insufficient ? "Insufficient sources; keep verifying" : "Source Summary Draft").font(.title3.bold())
                                Text(answer.answer).textSelection(.enabled)
                                ForEach(answer.citations) { c in
                                    if let source = batch.sources.first(where: { $0.id == c.source_id }) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Link("[\(c.source_id)] Citation basis · \(source.title)", destination: source.url).frame(minHeight: 44)
                                            Text(c.quote).font(.footnote).textSelection(.enabled)
                                        }
                                    }
                                }
                                Text("The citations have been checked against the selected basis (search excerpts or body passages); the summary, dates, and facts still need human review. A working link or a successful search doesn't mean the source is trustworthy.") .font(.caption).foregroundStyle(.secondary)
                            }.agentPanel()
                        }
                        Button("Export Sources and Answer") { export(batch) }.disabled(work != nil).frame(minHeight: 44)
                    }
                    AgentHelp(title: "Saving Results", text: "Results and the answer stay only in this page's memory. You can export before leaving; leaving or backgrounding cancels processing, but can't recall a request the service already received.")
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("Web Search").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Dismiss Keyboard") { focusedField = nil } }
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { cancel(); dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button { cancel(); approval = nil; showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Search Settings") }
                }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .sheet(isPresented: $showInvestigation) { WebInvestigationView(initialQuestion: query) }
            .sheet(isPresented: $showSettings, onDismiss: refreshConfig) {
                NavigationStack { WebSearchSettingsView(onClose: { showSettings = false }).navigationTitle("Search Settings").navigationBarTitleDisplayMode(.inline) }.tint(AgentPalette.accent).agentSheetStyle()
            }
            .sheet(item: $approval) { snapshot in approvalView(snapshot) }
            .sheet(item: $pageTarget) { target in
                WebPageView(source: target.source) { excerpt in
                    guard phase == .active, work == nil, let current = batch, current.id == target.batchID else { throw AgentError.message("The current sources changed; go back and choose again") }
                    batch = try current.usingPage(sourceID: target.source.id, excerpt: excerpt); answer = nil
                }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: "Web Search.txt") { result in
                if case .failure(let e) = result { error = e.localizedDescription }; document = nil
            }
            .onChange(of: phase) { _, value in if value != .active { cancel(); approval = nil } }
            .onChange(of: query) { _, _ in cancel(); approval = nil; plan = nil; planQuestion = "" }
            .onChange(of: fingerprint) { _, _ in cancel(); approval = nil; pageTarget = nil; answer = nil; plan = nil; planQuestion = "" }
            .onChange(of: model.consentReady) { _, _ in cancel(); approval = nil; pageTarget = nil; answer = nil; plan = nil; planQuestion = "" }
            .onDisappear { cancel(); batch = nil; answer = nil; plan = nil }
    }
    private func approvalView(_ value: SearchApproval) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(value.kind == .plan ? "Confirm Creating a Search Plan" : value.kind == .research ? "Confirm All Search Items" : value.kind == .search ? "Confirm This Search" : "Confirm Summarizing Sources").font(.title.bold())
                    Text(value.kind == .search || value.kind == .research ? "Recipient: \(value.config.provider.title)\n\(value.config.provider.endpoint.absoluteString)" : "Recipient: \(PrivacyConsent.recipient(model.settings))\n\(model.settings.endpoint)").font(.footnote).textSelection(.enabled)
                    Text(value.kind == .plan ? "The question below, the default time condition, and the current time will be sent to the model to generate an editable plan, consuming one model request. This step does not search." : value.kind == .research ? "Each keyword and time condition below is sent to the search service in order, each consuming quota separately. You can cancel midway, but can't recall requests already sent. It won't add queries or summarize an answer on its own." : value.kind == .search ? "The query terms and time filter below will be sent to the search service and consume its account quota. The screen, voice, history, and memory are not sent." : "The question, the plan and completed count below (if any), and all selected source bases will be sent to the current model, consuming model quota. The search key, screen, voice, conversation history, and memory are not sent.")
                    Text(value.query).font(.headline).textSelection(.enabled)
                    if let plan = value.plan {
                        ForEach(plan.queries.indices, id: \.self) { i in Text("\(i + 1). \(plan.queries[i].query)\n\(plan.queries[i].freshness.title) · \(plan.queries[i].reason)").textSelection(.enabled) }
                    } else { Text(value.config.freshness.title).font(.caption) }
                    if let batch = value.batch { Text(batch.referenceText).font(.footnote).textSelection(.enabled) }
                    Text("The recipient may store the request and continue processing the data; check its policy for how it retains and deletes data.") .font(.footnote).foregroundStyle(.secondary)
                    Text("The screen, voice, conversation history, and on-device memory are not sent; the search key goes only to the search service.") .font(.caption).foregroundStyle(.secondary)
                    Button(value.kind == .plan ? "Agree and Generate One Plan" : value.kind == .research ? "Agree and Run the Searches Above" : value.kind == .search ? "Agree and Search Once" : "Agree and Summarize Once") { approval = nil; execute(value) }.buttonStyle(AgentButtonStyle())
                }.padding(20)
            }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { approval = nil } } }
        }.tint(AgentPalette.accent).agentSheetStyle()
    }
    private func refreshConfig() {
        let latest = WebSearchStore.load()
        if latest != config { cancel(); batch = nil; answer = nil }
        config = latest
    }
    private func prepareSearch() {
        focusedField = nil
        do {
            let q = try WebSearchBatch.validatedQuery(query)
            guard !WebSearchStore.key(config.provider).isEmpty else { error = "Save a search key in Search Settings first"; showSettings = true; return }
            error = ""; approval = SearchApproval(kind: .search, query: q, config: config, batch: nil, modelFingerprint: fingerprint)
        } catch { self.error = error.localizedDescription }
    }
    private func planQuery(_ index: Int) -> Binding<String> {
        Binding(get: { guard let current = plan, current.queries.indices.contains(index) else { return "" }; return current.queries[index].query }, set: { if plan?.queries.indices.contains(index) == true { plan?.queries[index].query = $0 } })
    }
    private func planFreshness(_ index: Int) -> Binding<WebSearchFreshness> {
        Binding(get: { guard let current = plan, current.queries.indices.contains(index) else { return .any }; return current.queries[index].freshness }, set: { if plan?.queries.indices.contains(index) == true { plan?.queries[index].freshness = $0 } })
    }
    private func preparePlan() {
        focusedField = nil
        do {
            let q = try WebSearchBatch.validatedQuery(query)
            guard model.modelReady, model.consentReady else { error = "Save the model and confirm the current AI data authorization first"; return }
            error = ""; approval = .init(kind: .plan, query: q, config: config, batch: nil, modelFingerprint: fingerprint)
        } catch { self.error = error.localizedDescription }
    }
    private func prepareResearch() {
        focusedField = nil
        do {
            guard let plan, planQuestion == (try WebSearchBatch.validatedQuery(query)) else { throw AgentError.message("The question changed; create the plan again") }
            try plan.validate()
            guard !WebSearchStore.key(config.provider).isEmpty else { error = "Save a search key first"; showSettings = true; return }
            error = ""; approval = .init(kind: .research, query: planQuestion, config: config, batch: nil, modelFingerprint: fingerprint, plan: plan)
        } catch { self.error = error.localizedDescription }
    }
    private func prepareAnswer(_ batch: WebSearchBatch) {
        focusedField = nil
        guard model.modelReady, model.consentReady else { error = "Save the model in Model Settings and confirm the current AI data authorization first"; return }
        error = ""; approval = SearchApproval(kind: .answer, query: batch.query, config: config, batch: batch, modelFingerprint: fingerprint)
    }
    private func cancel() { generation = UUID(); work?.cancel(); work = nil; state = "" }
    private func execute(_ value: SearchApproval) {
        guard work == nil, phase == .active, config == value.config else { error = "The page or search settings changed; confirm again"; return }
        if value.kind == .search || value.kind == .research {
            guard (try? WebSearchBatch.validatedQuery(query)) == value.query else { error = "The query terms changed; confirm again"; return }
            if value.kind == .research {
                guard let approved = value.plan, approved == plan, planQuestion == value.query, (try? approved.validate()) != nil else { error = "The plan changed; review it again"; return }
            }
        } else if value.kind == .plan {
            guard value.modelFingerprint == fingerprint, model.modelReady, model.consentReady, (try? WebSearchBatch.validatedQuery(query)) == value.query else { error = "The question, model, or authorization changed; confirm again"; return }
        } else {
            guard value.modelFingerprint == fingerprint, model.consentReady, value.batch?.id == batch?.id else { error = "The model, authorization, or sources changed; confirm again"; return }
        }
        let token = UUID(); generation = token
        let settings = model.settings
        let key = value.kind == .search || value.kind == .research ? WebSearchStore.key(value.config.provider) : SettingsStore.apiKey(for: settings.endpoint)
        state = value.kind == .plan ? "Creating the search plan" : value.kind == .search || value.kind == .research ? "Searching sources" : "Summarizing sources"; error = ""
        work = Task {
            defer { if generation == token { work = nil; state = "" } }
            var completed = 0
            do {
                if value.kind == .search {
                    let result = try await WebSearchClient(settings: value.config, apiKey: key).search(query: value.query)
                    try Task.checkCancellation()
                    guard generation == token, phase == .active, config == value.config else { return }
                    batch = result; answer = nil
                } else if value.kind == .plan {
                    let result = try await VisionClient(settings: settings, apiKey: key).searchPlan(question: value.query, freshness: value.config.freshness)
                    try Task.checkCancellation()
                    guard generation == token, phase == .active, fingerprint == value.modelFingerprint, model.consentReady, (try? WebSearchBatch.validatedQuery(query)) == value.query else { return }
                    plan = result; planQuestion = value.query
                } else if value.kind == .research, let approved = value.plan {
                    _ = try await WebResearchClient(settings: value.config, apiKey: key).search(question: value.query, plan: approved) { partial in
                        guard generation == token, phase == .active, config == value.config else { return }
                        completed = partial.completedQueries ?? 0; batch = partial; answer = nil
                        state = "Completed \(completed)/\(approved.queries.count) searches"
                    }
                } else if let source = value.batch {
                    let result = try await VisionClient(settings: settings, apiKey: key).searchAnswer(batch: source)
                    try Task.checkCancellation()
                    guard generation == token, phase == .active, fingerprint == value.modelFingerprint, model.consentReady, batch?.id == source.id else { return }
                    answer = result
                }
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription + (completed > 0 ? " \(completed) item(s) completed this time; the returned sources are kept, and later searches did not continue." : "") } }
        }
    }
    private func export(_ batch: WebSearchBatch) {
        var text = batch.referenceText
        if let answer { text += "\n\nModel summary draft\(answer.insufficient ? " (insufficient sources)" : "")\n" + answer.answer + "\n\n" + answer.citations.map { "[\($0.source_id)] Quote: \($0.quote)" }.joined(separator: "\n") }
        text += "\n\nThe above is only search excerpts and a model draft; checked citations don't guarantee the facts or attribution are correct.\n"
        document = ArtifactDocument(data: Data(text.utf8)); exporting = true
    }
}
