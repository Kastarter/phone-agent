import SwiftUI
import UniformTypeIdentifiers

struct WebPageView: View {
    let source: WebSearchSource
    let onUse: (WebPageExcerpt?) throws -> Void
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var savedKey = ""
    @State private var page: WebPageDocument?
    @State private var start = 0
    @State private var length = 4000
    @State private var approval = false
    @State private var showFullText = false
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var error = ""
    @State private var message = ""
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    private var selected: WebPageExcerpt? { page.flatMap { try? $0.excerpt(start: start, length: length) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(source.title).font(.title2.bold())
                    Text(source.url.absoluteString).font(.footnote).textSelection(.enabled)
                    AgentHelp(title: "Page text service and data", text: "Page text extraction service: Tavily. Only this link and your Tavily key are sent to that fixed service. The app does not open the page itself and does not send screen, voice, questions, history, or model keys. The service may charge; extracted text may miss sign-in, dynamic, or partial content.")
                    DisclosureGroup("Page text service key") { VStack(alignment: .leading, spacing: 12) {
                    SecureField("Tavily API Key", text: $key).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().agentField().disabled(work != nil).accessibilityLabel("Tavily page text API key")
                    Button("Save Tavily Key") {
                        do { try WebSearchStore.saveKey(key, for: .tavily); savedKey = key; error = ""; message = key.isEmpty ? "Tavily key cleared" : "Tavily key saved; search provider unchanged" }
                        catch { self.error = error.localizedDescription }
                    }.disabled(work != nil).frame(minHeight: 44)
                    }.padding(.top, 12) }.agentPanel()
                    Button(page == nil ? "Extract this page's text" : "Extract text again") { approval = true }.buttonStyle(AgentButtonStyle()).disabled(work != nil || savedKey.isEmpty || key != savedKey)
                    if key != savedKey { Text("Key changed. Save it before extracting.") .font(.caption).foregroundStyle(.secondary) }
                    if work != nil { HStack { ProgressView("Extracting text"); Spacer(); Button("Cancel") { cancel() } } }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if !message.isEmpty { AgentNotice(text: message) }
                    if let previous = source.pageExcerpt, page == nil {
                        Text("Excerpt used in the last answer").font(.headline)
                        Text(previous.label).font(.caption).foregroundStyle(.secondary)
                        Text(previous.text).textSelection(.enabled)
                    }
                    if let page {
                        Text("Received \(page.text.count) characters of extracted text").font(.headline)
                        Text("Received: \(page.retrievedAt.formatted(date: .abbreviated, time: .standard)). This is not the page's publish date and does not verify completeness or accuracy.") .font(.caption).foregroundStyle(.secondary)
                        Button("View all extracted text") { showFullText = true }.frame(minHeight: 44)
                        Button("Export extracted text (TXT)") {
                            let output = source.title + "\n" + page.url.absoluteString + "\nTavily text received: " + ISO8601DateFormatter().string(from: page.retrievedAt) + "\nExtracted text may be incomplete and needs review; the time above is not the page's publish date.\n\n" + page.text
                            document = ArtifactDocument(data: Data(output.utf8)); exporting = true
                        }.frame(minHeight: 44)
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Choose text for the answer").font(.title3.bold())
                            LabeledContent("Start (character #)") {
                                TextField("Start", value: Binding(get: { start + 1 }, set: {
                                    start = max(1, min($0, page.text.count)) - 1
                                    length = min(length, page.text.count - start)
                                }), format: .number)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100).agentField().disabled(work != nil)
                            }
                            LabeledContent("Length (characters)") {
                                TextField("Length", value: Binding(get: { length }, set: {
                                    length = max(1, min($0, min(12000, page.text.count - start)))
                                }), format: .number)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100).agentField().disabled(work != nil)
                            }
                            if let selected {
                                Text(selected.label).font(.caption).foregroundStyle(.secondary)
                                Text(selected.text).textSelection(.enabled)
                                Button("Use this text as source evidence") {
                                    do { try onUse(selected); dismiss() } catch { self.error = error.localizedDescription }
                                }.buttonStyle(AgentButtonStyle(primary: false)).disabled(work != nil)
                            } else {
                                Text("This excerpt is blank. Adjust the start or length.") .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Replaces only this source's evidence; the original search excerpt is kept. The model is not called automatically; review the answer material back on the search page. Up to 12,000 characters, and all model material must stay under 40,000 characters.") .font(.caption).foregroundStyle(.secondary)
                        }.agentPanel()
                    }
                    if source.pageExcerpt != nil {
                        Button("Revert to original search excerpt") { do { try onUse(nil); dismiss() } catch { self.error = error.localizedDescription } }.disabled(work != nil).frame(minHeight: 44)
                    }
                    AgentHelp(title: "How page text is kept", text: "Page text stays in this page's memory; export it before leaving. Excerpts added to a source stay on the search page and are cleared when you leave it. A failure does not clear existing text, and canceling does not retry automatically.")
                }.padding(20)
            }.navigationTitle("Page Text").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { cancel(); dismiss() } } }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .onAppear { savedKey = WebSearchStore.key(.tavily); key = savedKey }
            .onChange(of: key) { _, _ in cancel(); approval = false }
            .onChange(of: start) { _, _ in if let page { length = min(length, page.text.count - start) } }
            .onChange(of: phase) { _, value in if value != .active { cancel(); approval = false } }
            .onDisappear { cancel(); document = nil }
            .confirmationDialog("Extract this page with Tavily?", isPresented: $approval, titleVisibility: .visible) {
                Button("Agree and extract once") { read() }
            } message: { Text("Full link: \(source.url.absoluteString)\nRecipient: https://api.tavily.com/extract\nThe link's path and query parameters are sent. Uses your Tavily key and requests only page text; no questions, screen, voice, history, memory, or model keys are sent. The service may charge and store the request. Other links on the page are not extracted automatically.") }
            .sheet(isPresented: $showFullText) {
                NavigationStack { ScrollView { if let page { Text(page.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) } }.navigationTitle("Extracted Text").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFullText = false } } } }.tint(AgentPalette.accent).agentSheetStyle()
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: ArtifactFiles.filename(source.title) + "-text.txt") { result in
                if case .failure(let e) = result { error = e.localizedDescription }; document = nil
            }
    }
    private func cancel() { generation = UUID(); work?.cancel(); work = nil }
    private func read() {
        guard phase == .active, work == nil, !savedKey.isEmpty, key == savedKey else { error = "The page or key changed. Review and try again."; return }
        let token = UUID(); generation = token; let credential = savedKey; error = ""; message = ""
        work = Task {
            defer { if generation == token { work = nil } }
            do {
                let result = try await WebPageClient(apiKey: credential).read(url: source.url)
                try Task.checkCancellation()
                guard generation == token, phase == .active, savedKey == credential else { return }
                page = result; start = 0; length = min(4000, result.text.count); message = "Text received. Review it and choose an excerpt; the model was not called."
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription } }
        }
    }
}
