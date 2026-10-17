import SwiftUI
import UniformTypeIdentifiers

private struct InvestigationApproval: Identifiable {
    let id = UUID()
    let question: String
    let rounds: Int
    let settings: WebSearchSettings
    let fingerprint: String
}
struct WebInvestigationView: View {
    let initialQuestion: String
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @FocusState private var questionFocused: Bool
    @State private var question = ""
    @State private var rounds = 3
    @State private var config = WebSearchStore.load()
    @State private var state: WebInvestigationState?
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var approval: InvestigationApproval?
    @State private var error = ""
    @State private var document: ArtifactDocument?
    @State private var exporting = false
    private var fingerprint: String { model.settings.endpoint + "|" + model.settings.model + "|" + PrivacyConsent.recipient(model.settings) + "|" + String(model.settings.responseTokenLimit) + "|" + String(model.settings.jsonMode) + "|" + String(model.settings.legacyTokenLimit) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Keep Digging for Evidence").font(.title2.weight(.semibold))
                    Text("The assistant proposes next-round keywords from the sources found so far, searches them in turn, then writes an answer with verbatim citations. You can cancel anytime; finishing the research doesn't mean every fact is verified.") .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Research Question").font(.caption).foregroundStyle(.secondary)
                        TextField("Enter the question to check", text: $question, axis: .vertical).lineLimit(1...5).agentField().disabled(work != nil).focused($questionFocused).accessibilityLabel("Research question")
                    }
                    DisclosureGroup("Rounds & Time Range") { VStack(spacing: 14) {
                    Stepper("Up to \(rounds) rounds", value: $rounds, in: 1...3).disabled(work != nil)
                    LabeledContent("Default Time Range") { Picker("", selection: $config.freshness) { ForEach(WebSearchFreshness.allCases) { Text($0.title).tag($0) } }.labelsHidden().disabled(work != nil) }
                    }.padding(.top, 12) }.agentPanel()
                    Text("Search recipient: \(config.provider.title)\nModel: \(model.settings.model.isEmpty ? "Not configured" : model.settings.model)\nUp to \(rounds * 3) searches and \(rounds + 1) model requests. The model proposes keywords automatically, which may include factual terms taken from sources; it continues only within this question and these limits. Each request may use quota.") .font(.footnote).foregroundStyle(.secondary)
                    Button("Review & Start Research") { prepare() }.buttonStyle(AgentButtonStyle()).disabled(work != nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if work != nil { HStack { ProgressView(); Text(state?.phase.rawValue ?? "Preparing"); Spacer(); Button("Cancel Research") { cancel() } } }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if let state {
                        Text(state.question).font(.title3.bold()).textSelection(.enabled)
                        Text("\(state.phase.rawValue) · \(state.searches) searches / \(state.modelRequests) model requests tried").font(.caption).foregroundStyle(.secondary)
                        if !state.message.isEmpty { Text(state.message).font(.footnote).foregroundStyle(.secondary) }
                        ForEach(state.rounds, id: \.number) { record in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Round \(record.number) · \(record.decision.finish ? "Suggests finishing" : "Completed \(record.completedQueries)/\(record.decision.queries.count)")").font(.headline)
                                Text(record.decision.note).textSelection(.enabled)
                                ForEach(record.decision.queries.indices, id: \.self) { i in
                                    Text("\(i + 1). \(record.decision.queries[i].query)\n\(record.decision.queries[i].freshness.title) · \(record.decision.queries[i].reason)").font(.footnote).textSelection(.enabled)
                                }
                                Text("Keywords and research notes are model drafts, not factual evidence.").font(.caption).foregroundStyle(.secondary)
                            }.agentPanel()
                        }
                        if let answer = state.answer, let evidence = state.evidence {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(answer.insufficient ? "Insufficient Evidence, Needs Review" : "Cited Answer Draft").font(.title2.bold())
                                Text(answer.answer).textSelection(.enabled)
                                ForEach(answer.citations) { citation in
                                    if let source = evidence.sources.first(where: { $0.id == citation.source_id }) {
                                        Link("[\(source.id)] \(source.title)", destination: source.url).frame(minHeight: 44)
                                        Text(citation.quote).font(.footnote).textSelection(.enabled)
                                    }
                                }
                                Text("Quotes were checked verbatim against sources; source quality, summary, dates, and attribution still need human review.").font(.caption).foregroundStyle(.secondary)
                            }.agentPanel()
                        }
                        if let evidence = state.evidence {
                            Text("\(evidence.sources.count) sources total").font(.headline)
                            ForEach(evidence.sources) { source in
                                VStack(alignment: .leading, spacing: 10) {
                                    Link("[\(source.id)] \(source.title)", destination: source.url).font(.headline).frame(minHeight: 44)
                                    Text(source.excerpt).textSelection(.enabled)
                                    Text("Date: \(source.publishedLabel ?? "Not provided by service")").font(.caption).foregroundStyle(.secondary)
                                    if let queries = source.matchedQueries { Text("From searches: " + queries.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary) }
                                }.agentPanel()
                            }
                            if evidence.omitted > 0 { Text("\(evidence.omitted) more results were unused: duplicates, without a valid source, or over the 20-source limit.") .font(.caption).foregroundStyle(.secondary) }
                        }
                        Button("Export Research Log & Answer (TXT)") { document = ArtifactDocument(data: Data(state.report.utf8)); exporting = true }.disabled(work != nil).frame(minHeight: 44)
                    }
                    Text("The separate search key goes only to the search service. The model receives this question, rounds and time range, tried keywords, and collected source excerpts. No screenshots, audio, chat history, or on-device memory. Web page bodies aren't read automatically, and no phone actions run. Results stay in this page's memory only; export before leaving. Backgrounding or leaving stops the research, and it doesn't resume after relaunch.") .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("Multi-Round Research").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide Keyboard") { questionFocused = false } }
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { cancel(); dismiss() } }
                }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .onAppear { if question.isEmpty { question = initialQuestion }; config = WebSearchStore.load() }
            .onChange(of: phase) { _, value in if value != .active { cancel() } }
            .onChange(of: fingerprint) { _, _ in cancel() }
            .onChange(of: model.consentReady) { _, _ in cancel() }
            .onChange(of: question) { _, _ in approval = nil }
            .onChange(of: rounds) { _, _ in approval = nil }
            .onChange(of: config) { _, _ in approval = nil }
            .onDisappear { cancel(); state = nil; document = nil }
            .sheet(item: $approval) { value in approvalView(value) }
            .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: "Multi-Round Research.txt") { result in if case .failure(let e) = result { error = e.localizedDescription }; document = nil }
    }
    private func prepare() {
        questionFocused = false
        do {
            let q = try WebSearchBatch.validatedQuery(question)
            guard model.modelReady, model.consentReady, !WebSearchStore.key(config.provider).isEmpty else { throw AgentError.message("Save the model and search keys and confirm the current AI data consent first") }
            error = ""; approval = .init(question: q, rounds: rounds, settings: config, fingerprint: fingerprint)
        } catch { self.error = error.localizedDescription }
    }
    private func approvalView(_ value: InvestigationApproval) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Confirm This Research").font(.title.bold())
                    Text(value.question).font(.headline).textSelection(.enabled)
                    Text("Search recipient: \(value.settings.provider.title)\n\(value.settings.provider.endpoint.absoluteString)\nModel recipient: \(PrivacyConsent.recipient(model.settings))\n\(model.settings.endpoint)").font(.footnote).textSelection(.enabled)
                    Text("Authorizes the assistant to propose next-round keywords within this question, search them in turn, and produce one cited answer. Up to \(value.rounds) rounds, \(value.rounds * 3) searches, and \(value.rounds + 1) model requests; it may finish early. Each request may be billed, and a complete answer isn't guaranteed when sources are thin.")
                    Text("This question, rounds / time range, tried keywords, and collected source excerpts go to the model. Keywords the model proposes and their time ranges go to the search service; keywords may include factual terms from sources. The search key goes only to the search service and the model key only to the model API. No screenshots, audio, chat history, memory, or original files; page bodies aren't extracted, links aren't followed, and no phone actions run.") .font(.footnote)
                    Text("Cancel anytime. Errors, backgrounding, or leaving the page stop new requests and keep sources already returned, with no automatic retry; data already received by a service can't be recalled. Recipients may retain data, so check their policies. Records live only in this page's memory and are saved only if you export them.") .font(.footnote).foregroundStyle(.secondary)
                    Button("Agree & Start Research") { approval = nil; start(value) }.buttonStyle(AgentButtonStyle())
                }.padding(20)
            }.navigationTitle("Review Research Scope").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { approval = nil } } }
        }.tint(AgentPalette.accent).agentSheetStyle()
    }
    private func cancel() {
        generation = UUID(); work?.cancel(); work = nil; approval = nil
        if var current = state, [.planning, .searching, .answering].contains(current.phase) { current.phase = .cancelled; current.message = "Stopped new requests and kept returned sources; data already sent can't be recalled"; state = current }
    }
    private func start(_ value: InvestigationApproval) {
        guard phase == .active, work == nil, rounds == value.rounds, config == value.settings, fingerprint == value.fingerprint, model.modelReady, model.consentReady,
              (try? WebSearchBatch.validatedQuery(question)) == value.question else { error = "The question, settings, or consent changed. Review again."; return }
        let token = UUID(); generation = token; let settings = model.settings
        let searchKey = WebSearchStore.key(value.settings.provider); let modelKey = SettingsStore.apiKey(for: settings.endpoint)
        error = ""
        work = Task {
            defer { if generation == token { work = nil } }
            let authorized = { generation == token && phase == .active && fingerprint == value.fingerprint && model.consentReady && rounds == value.rounds && config == value.settings && (try? WebSearchBatch.validatedQuery(question)) == value.question && WebSearchStore.key(value.settings.provider) == searchKey && SettingsStore.apiKey(for: settings.endpoint) == modelKey }
            do {
                _ = try await WebInvestigationRunner(settings: value.settings, searchKey: searchKey).run(question: value.question, maxRounds: value.rounds, authorized: authorized,
                    decide: { try await VisionClient(settings: settings, apiKey: modelKey).researchDecision(context: $0) },
                    summarize: { try await VisionClient(settings: settings, apiKey: modelKey).searchAnswer(batch: $0) },
                    progress: { if generation == token { state = $0 } })
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription } }
        }
    }
}
