import SwiftUI
import UniformTypeIdentifiers

struct MeetingEditorSeed: Identifiable {
    let id = UUID()
    let source: String
    let sourceName: String
    let notes: MeetingNotes
}

private enum MeetingExport: String, CaseIterable, Identifiable {
    case word = "Notes Word", minutesPDF = "Notes PDF", markdown = "Notes Markdown", json = "Structured Notes JSON"
    case png = "Fishbone PNG", svg = "Fishbone SVG", diagramPDF = "Fishbone PDF"
    var id: String { rawValue }
    var ext: String { switch self { case .word:return "docx"; case .minutesPDF,.diagramPDF:return "pdf"; case .markdown:return "md"; case .json:return "json"; case .png:return "png"; case .svg:return "svg" } }
    var type: UTType { UTType(filenameExtension:ext) ?? .data }
    var diagram: Bool { [.png,.svg,.diagramPDF].contains(self) }
}

struct MeetingNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let seed: MeetingEditorSeed
    let onApply: (MeetingNotes) -> Void
    let onRetainDraft: (MeetingNotes) -> Void
    private enum SectionTab: String, CaseIterable { case minutes = "Notes", actions = "Actions", diagram = "Fishbone" }
    @State private var sectionTab: SectionTab = .minutes
    @State private var notes: MeetingNotes
    @State private var error = ""
    @State private var message = ""
    @State private var preview: CGImage?
    @State private var previewSize = CGSize.zero
    @State private var zoom = 0.6
    @State private var working = false
    @State private var operation: Task<Void,Never>?
    @State private var generation = UUID()
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    @State private var exportType = UTType.data
    @State private var exportName = "Meeting Notes"
    @FocusState private var focusedField: String?
    init(seed:MeetingEditorSeed,onApply:@escaping (MeetingNotes)->Void,onRetainDraft:@escaping (MeetingNotes)->Void) {
        self.seed=seed;self.onApply=onApply;self.onRetainDraft=onRetainDraft;_notes=State(initialValue:seed.notes)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    Text(notes.title).font(.title3.weight(.semibold))
                    DisclosureGroup("Title & Source Text") {
                        VStack(alignment: .leading, spacing: 14) {
                            MeetingLabeledField(label: "Notes title", placeholder: "Name these notes", text: $notes.title, focus: $focusedField, fieldID: "title", accessibility: "Notes title, up to 80 characters")
                            Text(seed.sourceName).font(.caption).foregroundStyle(.secondary)
                            Text(seed.source).font(.subheadline).textSelection(.enabled)
                            Text("Quote matching only confirms the source; transcripts, paraphrases, and causes still need review.") .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }.font(.subheadline).agentPanel()
                    Picker("Notes Section", selection: $sectionTab) {
                        ForEach(SectionTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).onChange(of: sectionTab) { _, _ in focusedField = nil }
                    switch sectionTab {
                    case .minutes: minutesPanel
                    case .actions: actionsPanel
                    case .diagram: diagramPanel
                    }
                    if working { ProgressView("Generating file") }
                    if !error.isEmpty { AgentNotice(text:error,error:true) }
                    if !message.isEmpty { AgentNotice(text:message) }
                    Menu {
                        ForEach(MeetingExport.allCases) { kind in Button(kind.rawValue) { export(kind) }.disabled(kind.diagram && notes.fishbone==nil) }
                    } label: { Label("Export Notes or Fishbone",systemImage:"square.and.arrow.up") }.buttonStyle(AgentButtonStyle()).disabled(working || exporting)
                    Text("Notes files and JSON include quoted source excerpts, and so does the SVG description; review before sharing. Drafts are kept only in the current workbench session, so save or export before leaving. Tap \"Use Notes\" to save the text as a memory. The fishbone PDF is a full vector canvas for zooming; use the notes file to copy text.") .font(.caption).foregroundStyle(.secondary)
                }.padding(20).disabled(working || exporting)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("Edit Notes").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement:.keyboard) { Spacer();Button("Hide Keyboard") { focusedField=nil } }
                    ToolbarItem(placement:.cancellationAction) { Button(working ? "Cancel" : "Back") { if working { cancel() } else { dismiss() } } }
                    ToolbarItem(placement:.confirmationAction) { Button("Use Notes") { do { try notes.validate(source:seed.source);onApply(notes);dismiss() } catch { self.error=error.localizedDescription } }.disabled(working || exporting) }
                }
                .fileExporter(isPresented:$exporting,document:document,contentType:exportType,defaultFilename:exportName) { result in
                    switch result { case .success:message="File exported";case .failure(let error):self.error=error.localizedDescription };document=nil
                }
                .onChange(of:phase) { _,value in if value == .background { cancel() } }
                .onDisappear { cancel();onRetainDraft(notes) }
        }.agentSheetStyle()
    }
    private var minutesPanel: some View { VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment:.leading,spacing:14) {
                        Text("Summary").font(.headline)
                        if notes.summary != nil {
                            MeetingStatementFields(item:Binding(get:{notes.summary ?? .init(text:"",quote:"")},set:{notes.summary=$0}),focus:$focusedField)
                            Button("Remove Summary",role:.destructive) { notes.summary=nil }
                        } else { Button("Add Summary") { notes.summary = .init(text:"",quote:"") } }
                    }.agentPanel()
                    statementSection("Key Points",items:$notes.points,maximum:24)
                    statementSection("Decisions",items:$notes.decisions,maximum:16)
                    statementSection("Open Questions",items:$notes.questions,maximum:12)
    } }
    private var actionsPanel: some View { VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment:.leading,spacing:14) {
                        Text("Action Items").font(.headline)
                        Text("Recorded only; no reminders are created and nothing is carried out. Leave owner and deadline blank if not stated.") .font(.caption).foregroundStyle(.secondary)
                        ForEach($notes.actions) { $item in
                            VStack(alignment:.leading,spacing:12) {
                                MeetingLabeledField(label:"Action item",placeholder:"What needs to be done",text:$item.text,focus:$focusedField,fieldID:item.id.uuidString+".text",lines:2...5)
                                MeetingLabeledField(label:"Owner",placeholder:"Leave blank if not stated",text:optional($item.owner),focus:$focusedField,fieldID:item.id.uuidString+".owner")
                                MeetingLabeledField(label:"Deadline as stated",placeholder:"Leave blank if not stated",text:optional($item.due),focus:$focusedField,fieldID:item.id.uuidString+".due")
                                MeetingLabeledField(label:"Source quote",placeholder:"Quote the source verbatim",text:$item.quote,focus:$focusedField,fieldID:item.id.uuidString+".quote",lines:2...5,accessibility:"Source quote; must appear verbatim in the material")
                                Button("Delete Action Item",role:.destructive) { notes.actions.removeAll { $0.id==item.id } }.frame(minHeight:44)
                            }.padding(.vertical,8)
                        }
                        Button("Add Action Item") { notes.actions.append(.init(text:"",quote:"",owner:nil,due:nil)) }.frame(minHeight:44).disabled(notes.actions.count>=24)
                    }.agentPanel()
    } }
    private var diagramPanel: some View { VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment:.leading,spacing:14) {
                        Text("Fishbone").font(.headline)
                        Text("Groups the causes mentioned in the material; inferences are marked as hypotheses to verify. Skip it if the material discusses no causes.") .font(.caption).foregroundStyle(.secondary)
                        if notes.fishbone != nil {
                            MeetingFishboneFields(bone:Binding(get:{notes.fishbone ?? .init(problem:.init(text:"",quote:""),groups:[])},set:{notes.fishbone=$0}),focus:$focusedField)
                            Button("Remove Fishbone",role:.destructive) { notes.fishbone=nil;preview=nil }
                            Button("Update Fishbone Preview") { focusedField=nil;makePreview() }.frame(minHeight:44)
                            if let preview {
                                ScrollView([.horizontal,.vertical]) { Image(decorative:preview,scale:1,orientation:.up).resizable().frame(width:previewSize.width*zoom,height:previewSize.height*zoom) }.frame(height:340).background(.white,in:RoundedRectangle(cornerRadius:16))
                                    .accessibilityLabel("Fishbone preview; the full content is in the cause entries above")
                                Slider(value:$zoom,in:0.25...1.5).accessibilityLabel("Fishbone preview zoom")
                                Text("The preview shows the last update; exporting redraws the current content.") .font(.caption).foregroundStyle(.secondary)
                            }
                        } else { Button("Add Fishbone") { notes.fishbone = .init(problem:.init(text:"",quote:""),groups:[]) }.frame(minHeight:44) }
                    }.agentPanel()
    } }
    private func optional(_ value:Binding<String?>)->Binding<String> { Binding(get:{value.wrappedValue ?? ""},set:{value.wrappedValue=$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : $0}) }
    private func statementSection(_ title:String,items:Binding<[MeetingStatement]>,maximum:Int)->some View {
        VStack(alignment:.leading,spacing:14) {
            Text(title).font(.headline)
            ForEach(items) { $item in
                VStack(alignment:.leading,spacing:10) { MeetingStatementFields(item:$item,focus:$focusedField);Button("Delete Entry",role:.destructive) { items.wrappedValue.removeAll { $0.id==item.id } }.frame(minHeight:44) }.padding(.vertical,8)
            }
            Button("Add to \(title)") { items.wrappedValue.append(.init(text:"",quote:"")) }.frame(minHeight:44).disabled(items.wrappedValue.count>=maximum)
        }.agentPanel()
    }
    private func cancel() { generation=UUID();operation?.cancel();operation=nil;working=false }
    private func makePreview() {
        error="";message="";let value=notes;let source=seed.source;working=true;let token=UUID();generation=token
        operation=Task {
            let worker=Task.detached(priority:.userInitiated) { let layout=try FishboneDiagram.layout(notes:value,source:source);try Task.checkCancellation();return (try FishboneDiagram.image(layout),layout.size) }
            do {
                let result=try await withTaskCancellationHandler { try await worker.value } onCancel:{worker.cancel()}
                guard !Task.isCancelled,token==generation,phase == .active else { return };preview=result.0;previewSize=result.1;working=false;operation=nil
            } catch { guard token==generation,!Task.isCancelled else { return };self.error=error.localizedDescription;working=false;operation=nil }
        }
    }
    private func export(_ kind:MeetingExport) {
        focusedField=nil
        do { try notes.validate(source:seed.source) } catch { self.error=error.localizedDescription;return }
        error="";message="";let value=notes;let source=seed.source;working=true;let token=UUID();generation=token
        operation=Task {
            do {
                let data:Data
                if kind.diagram {
                    let worker=Task.detached(priority:.userInitiated) {
                        let layout=try FishboneDiagram.layout(notes:value,source:source);try Task.checkCancellation()
                        switch kind { case .png:return try FishboneDiagram.png(layout);case .svg:return FishboneDiagram.svg(layout);default:return try FishboneDiagram.pdf(layout) }
                    }
                    data=try await withTaskCancellationHandler { try await worker.value } onCancel:{worker.cancel()}
                } else if kind == .json {
                    let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];data=try encoder.encode(value)
                } else if kind == .minutesPDF {
                    let worker=Task.detached(priority:.userInitiated) { try MeetingMinutesPDF.make(notes:value,source:source) }
                    data=try await withTaskCancellationHandler { try await worker.value } onCancel:{worker.cancel()}
                }
                else { data=try ArtifactFiles.make(title:value.title,text:value.plainText,format:kind == .word ? .word : .markdown) }
                guard !Task.isCancelled,token==generation,phase == .active else { return }
                document=ArtifactDocument(data:data);exportType=kind.type;exportName=ArtifactFiles.filename(value.title)+(kind.diagram ? "-fishbone" : "-notes")+"."+kind.ext
                working=false;operation=nil;exporting=true
            } catch { guard token==generation,!Task.isCancelled else { return };self.error=error.localizedDescription;working=false;operation=nil }
        }
    }
}

private struct MeetingLabeledField:View {
    let label:String
    let placeholder:String
    @Binding var text:String
    let focus:FocusState<String?>.Binding
    let fieldID:String
    var lines:ClosedRange<Int> = 1...1
    var accessibility:String? = nil
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if !label.isEmpty { Text(label).font(.caption).foregroundStyle(.secondary) }
            TextField(placeholder,text:$text,axis:.vertical).lineLimit(lines).agentField()
                .focused(focus,equals:fieldID).accessibilityLabel(accessibility ?? label)
        }
    }
}

private struct MeetingStatementFields:View {
    @Binding var item:MeetingStatement
    let focus:FocusState<String?>.Binding
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            MeetingLabeledField(label:"",placeholder:"Enter the note",text:$item.text,focus:focus,fieldID:item.id.uuidString+".text",lines:2...6,accessibility:"Note entry")
            MeetingLabeledField(label:"Source quote",placeholder:"Quote the source verbatim",text:$item.quote,focus:focus,fieldID:item.id.uuidString+".quote",lines:2...5,accessibility:"Source quote; must appear verbatim in the material")
        }
    }
}
private struct MeetingFishboneFields:View {
    @Binding var bone:MeetingFishbone
    let focus:FocusState<String?>.Binding
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Problem Discussed").font(.subheadline.bold());MeetingStatementFields(item:$bone.problem,focus:focus)
            ForEach($bone.groups) { $group in
                VStack(alignment:.leading,spacing:14) {
                    MeetingLabeledField(label:"Cause group",placeholder:"Name this group of causes",text:$group.name,focus:focus,fieldID:group.id.uuidString+".name")
                    ForEach($group.causes) { $cause in
                        VStack(alignment:.leading,spacing:10) {
                            MeetingLabeledField(label:"Cause",placeholder:"Enter a cause from the material",text:$cause.text,focus:focus,fieldID:cause.id.uuidString+".text",lines:2...5)
                            Toggle("Hypothesis to verify",isOn:$cause.hypothesis).tint(.orange)
                            MeetingLabeledField(label:"Source quote for cause",placeholder:"Quote the source verbatim",text:$cause.quote,focus:focus,fieldID:cause.id.uuidString+".quote",lines:2...5)
                            Button("Delete Cause",role:.destructive) { group.causes.removeAll { $0.id==cause.id } }.frame(minHeight:44)
                        }
                    }
                    Button("Add Cause") { group.causes.append(.init(text:"",quote:"",hypothesis:true)) }.frame(minHeight:44).disabled(group.causes.count>=8)
                    Button("Delete Group",role:.destructive) { bone.groups.removeAll { $0.id==group.id } }.frame(minHeight:44)
                }.padding(14).background(AgentPalette.inset,in:RoundedRectangle(cornerRadius:18))
            }
            Button("Add Cause Group") { bone.groups.append(.init(name:"",causes:[])) }.frame(minHeight:44).disabled(bone.groups.count>=8)
        }
    }
}
