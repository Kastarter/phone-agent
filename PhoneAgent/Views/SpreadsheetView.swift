import SwiftUI
import UIKit
import Charts
import UniformTypeIdentifiers

struct SpreadsheetSeed: Identifiable { let id = UUID(); let title: String; let text: String }
private enum SheetEditorAlert {
    case close, remove(row: Bool), restore(WorkbookReceipt), removeSheet(UUID)
    var title: String {
        switch self { case .close: return "Spreadsheet changes not saved"; case .remove(let row): return row ? "Delete last row?" : "Delete last column?"; case .restore: return "Restore draft and replace the whole workbook?"; case .removeSheet: return "Delete this sheet?" }
    }
    var message: String {
        switch self {
        case .close: return "Leaving clears this page's draft. Keep editing and tap \"Export Draft\" at the top to save JSON with the original formulas and chart settings. Excel and CSV exports don't save this page's editing state."
        case .remove: return "The row or column contents will be removed. Formula addresses won't adjust automatically, so recheck references."
        case .restore: return "All unsaved changes in the workbook will be replaced."
        case .removeSheet: return "Removes this sheet's cells and chart. At least one sheet must remain; formulas won't be rewritten automatically."
        }
    }
}

struct SpreadsheetView: View {
    let seed: SpreadsheetSeed
    @Environment(\.dismiss) private var dismiss
    private enum Field: Hashable { case title, sheetName, paste }
    @FocusState private var focusedField: Field?
    private enum EditorTab: String, CaseIterable { case cells = "Cells", chart = "Chart" }
    @State private var editorTab: EditorTab = .cells
    @State private var title = "Spreadsheet"
    @State private var draft: SpreadsheetDraft?
    @State private var paste = ""
    @State private var selected = SheetAddress(row: 0, column: 0)
    @State private var cellText = ""
    @State private var cellFocused = false
    @State private var values: [[SheetValue]]?
    @State private var chart = SheetChartSpec()
    @State private var chartEnabled = false
    @State private var points: [SheetChartPoint] = []
    @State private var error = ""
    @State private var message = ""
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    @State private var exportType = UTType.data
    @State private var exportName = "Spreadsheet"
    @State private var importing = false
    @State private var replace = false
    @State private var activeAlert: SheetEditorAlert?
    @State private var sheets: [WorkbookSheet] = []
    @State private var activeID = UUID()
    @State private var sheetName = "Sheet1"
    @State private var savedReceipt: WorkbookReceipt?
    @State private var exportReceipt: WorkbookReceipt?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text(title).font(.title3.weight(.semibold)); Spacer(); Text(sheetName).font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup("Workbook & Import") {
                        VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Workbook Title").font(.caption).foregroundStyle(.secondary)
                        TextField("Spreadsheet title", text: $title).agentField().focused($focusedField, equals: .title).accessibilityLabel("Workbook title")
                    }
                    workbookControls
                    AgentHelp(title: "About Workbooks", text: "Editing and calculation happen on device; no model is called. Formulas run only here; the main workspace's Excel export still treats them as text. Edit up to 12 sheets with in-sheet and cross-sheet calculation; each sheet keeps its own chart. Export JSON before leaving to keep your draft.")
                    DisclosureGroup("Paste Table or Restore Draft") {
                        TextField("Tabs separate columns, newlines separate rows", text: $paste, axis: .vertical).lineLimit(3...10).agentField().focused($focusedField, equals: .paste)
                        Button("Replace Current Sheet with Pasted Content") { focusedField = nil; replace = true }.disabled(pendingCell).frame(minHeight: 44)
                        Button("Import JSON Draft") { focusedField = nil; importing = true }.frame(minHeight: 44)
                        Text("JSON saves the whole workbook and supports older single-sheet drafts; Excel exports all sheets. CSV / SVG export only the current sheet. Importing regular Office files still extracts only text and cached values.") .font(.caption).foregroundStyle(.secondary)
                    }
                        }.padding(.top, 12)
                    }.font(.subheadline).agentPanel()
                    if let draft {
                        Picker("Editing Area", selection: $editorTab) {
                            ForEach(EditorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).disabled(pendingCell)
                            .onChange(of: editorTab) { _, _ in focusedField = nil; cellFocused = false }
                        if editorTab == .cells {
                        Text("\(draft.rows.count) rows × \(draft.columns) columns · \(draft.text.count)/12000 chars").font(.caption).foregroundStyle(.secondary)
                        grid(draft)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Edit \(selected.name)").font(.headline)
                            if pendingCell { Text("Cell change not applied. Tap Apply before switching cells, calculating, or exporting.").font(.caption).foregroundStyle(.orange) }
                            SheetCellInput(text: $cellText, isFocused: $cellFocused, onApply: { if editCell() { cellFocused = false } })
                                .frame(height: 130).agentField()
                            Button("Apply Cell") { if editCell() { focusedField = nil; cellFocused = false } }.buttonStyle(AgentButtonStyle(primary: false))
                            AgentHelp(title: "Supported Formulas", text: "Start input with ' to force text. Use a period for decimals. Formulas support + − × ÷, parentheses, %, A1 / $A$1, rectangular ranges, and SUM, AVERAGE, MIN, MAX, COUNT, ROUND. Function names are in English with comma-separated arguments; ROUND digits range from −6 to 6.")
                            AgentHelp(title: "References & Calculation", text: "Blanks and text in ranges and standalone references are ignored by aggregate functions; in arithmetic, blanks count as 0 and text is an error. Supports Sheet1!B2, 'Sheet Name'!$B$2, and SUM('Sheet Name'!B2:B4). Write a single quote in a sheet name as two single quotes. 3D ranges, external workbooks, string / date functions, and macros aren't supported. After renaming or deleting a sheet, fix formula references yourself.")
                        }.agentPanel()
                        HStack {
                            Button("Add Row") { resize(row: true, add: true) }.disabled(pendingCell || draft.rows.count >= 200)
                            Spacer()
                            Button("Add Column") { resize(row: false, add: true) }.disabled(pendingCell || draft.columns >= 26)
                        }.frame(minHeight: 44)
                        HStack {
                            Button("Delete Last Row", role: .destructive) { activeAlert = .remove(row: true) }.disabled(pendingCell || draft.rows.count <= 1)
                            Spacer()
                            Button("Delete Last Column", role: .destructive) { activeAlert = .remove(row: false) }.disabled(pendingCell || draft.columns <= 1)
                        }.frame(minHeight: 44)
                        Button("Recalculate & Check") { calculate() }.buttonStyle(AgentButtonStyle()).disabled(pendingCell)
                        if let values {
                            let errors = values.enumerated().flatMap { row, cells in cells.enumerated().compactMap { column, value -> String? in if case .error(let code) = value { return "\(SheetAddress(row: row, column: column).name): \(code)" }; return nil } }
                            if !errors.isEmpty { Text(errors.joined(separator: "\n")).foregroundStyle(.red).textSelection(.enabled) }
                            else { Text("Cells calculated. Still check values and formulas before exporting.") .font(.caption).foregroundStyle(.secondary) }
                        }
                        } else {
                        Toggle("Add Chart", isOn: $chartEnabled).tint(AgentPalette.accent)
                        if chartEnabled {
                            Picker("Chart Type", selection: $chart.kind) { ForEach(SheetChartSpec.Kind.allCases) { Text($0.rawValue).tag($0) } }
                            Picker("Label Column", selection: $chart.labelColumn) { ForEach(0..<draft.columns, id: \.self) { Text(String(UnicodeScalar(65 + $0)!)).tag($0) } }
                            Text("Value Columns (up to 3)").font(.headline)
                            ForEach(0..<draft.columns, id: \.self) { column in
                                if column != chart.labelColumn {
                                    Toggle(String(UnicodeScalar(65 + column)!), isOn: Binding(get: { chart.valueColumns.contains(column) }, set: { enabled in
                                        if enabled { if chart.valueColumns.count < 3 { chart.valueColumns.append(column); chart.valueColumns.sort() } else { error = "Select up to 3 value columns" } }
                                        else { chart.valueColumns.removeAll { $0 == column } }
                                    })).tint(AgentPalette.accent)
                                }
                            }
                            Stepper("Start row: \(chart.firstRow + 1)", value: $chart.firstRow, in: 1...max(1, draft.rows.count - 1))
                            Stepper("End row: \(chart.lastRow + 1)", value: $chart.lastRow, in: 1...max(1, draft.rows.count - 1))
                            Text("The first row is the header; charts use 1–60 consecutive rows. Blanks, text, and formula errors aren't skipped, so value columns must be all numbers. Recalculate after editing chart settings.") .font(.caption).foregroundStyle(.secondary)
                            if !points.isEmpty {
                                chartPreview
                                DisclosureGroup("Chart Data & Full Labels") {
                                    ForEach(points) { point in Text("Row \(point.row + 1) · \(point.label) · \(point.name): \(point.value)").textSelection(.enabled) }
                                }
                            }
                        }
                            Button("Update Chart") { calculate() }.buttonStyle(AgentButtonStyle()).disabled(pendingCell || !chartEnabled)
                        }
                        HStack {
                            Button("Export Excel") { export("xlsx") }.buttonStyle(AgentButtonStyle())
                            Button("Export CSV") { export("csv") }.buttonStyle(AgentButtonStyle(primary: false))
                        }.disabled(pendingCell)
                        HStack {
                            Button("Save JSON Draft") { export("json") }.frame(minHeight: 44)
                            Spacer()
                            if chartEnabled { Button("Export SVG Chart") { export("svg") }.frame(minHeight: 44) }
                        }.disabled(pendingCell)
                        AgentHelp(title: "Export Formats", text: "Excel exports all sheets, numbers, supported in-sheet / cross-sheet formulas, and cached results; each sheet can have its own chart. A formula / chart error in any sheet blocks the whole Excel export; use JSON to save a draft to fix later. CSV and SVG export only the current sheet; CSV escapes text that starts with formula characters.")
                    }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if !message.isEmpty { AgentNotice(text: message) }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("Spreadsheet & Chart").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Export Draft") { focusedField = nil; export("json") }.disabled(pendingCell).accessibilityLabel("Save JSON draft") }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { if hasUnsavedChanges { activeAlert = .close } else { dismiss() } } }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Hide Keyboard") { focusedField = nil; cellFocused = false }
                    }
                }
                .interactiveDismissDisabled(hasUnsavedChanges)
                .onAppear { if draft == nil { title = seed.title; paste = seed.text; do { apply(try SpreadsheetDraft(text: seed.text.isEmpty ? "Item\tValue\n\t" : seed.text)); if let currentReceipt { sheets = currentReceipt.sheets }; savedReceipt = currentReceipt } catch { self.error = error.localizedDescription } } }
                .onChange(of: chart) { _, _ in points = []; values = nil; message = "" }
                .onChange(of: chartEnabled) { _, _ in points = []; message = "" }
                .onChange(of: chart.labelColumn) { _, column in chart.valueColumns.removeAll { $0 == column } }
                .confirmationDialog("Replace the current sheet? Unsaved changes will be replaced.", isPresented: $replace) {
                    Button("Replace") { do { apply(try SpreadsheetDraft(text: paste)); error = "" } catch { self.error = error.localizedDescription } }
                }
                .alert(activeAlert?.title ?? "Spreadsheet", isPresented: Binding(get: { activeAlert != nil }, set: { if !$0 { activeAlert = nil } }), presenting: activeAlert) { alert in
                    switch alert {
                    case .close:
                        Button("Keep Editing", role: .cancel) {}
                        Button("Discard Changes", role: .destructive) { dismiss() }
                    case .remove(let row):
                        Button("Cancel", role: .cancel) {}
                        Button("Delete", role: .destructive) { resize(row: row, add: false) }
                    case .removeSheet(let id):
                        Button("Cancel", role: .cancel) {}
                        Button("Delete Sheet", role: .destructive) { removeSheet(id) }
                    case .restore(let value):
                        Button("Cancel", role: .cancel) {}
                        Button("Restore") {
                            do { try restore(value); savedReceipt = value; error = "" }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                } message: { alert in Text(alert.message) }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    do {
                        let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, let size = attributes.fileSize, size > 0, size <= WorkbookReceipt.maxBytes else { throw AgentError.message("Workbook JSON must be a regular file under 2 MB") }
                        let data = try Data(contentsOf: url); guard data.count <= WorkbookReceipt.maxBytes else { throw AgentError.message("Workbook JSON exceeds 2 MB") }
                        let value = try WorkbookReceipt.decode(data); activeAlert = .restore(value)
                    } catch { self.error = error.localizedDescription }
                }
        }
                .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { result in
                    switch result {
                    case .success:
                        if let exportReceipt { savedReceipt = exportReceipt }
                        message = "Exported"
                    case .failure(let failure): error = failure.localizedDescription
                    }
                    document = nil; exportReceipt = nil
                }
    }
    private var currentReceipt: WorkbookReceipt? {
        guard let draft else { return nil }
        let receipt = SheetReceipt(version: 1, title: sheetName, rows: draft.rows, chart: chart, chartEnabled: chartEnabled)
        let active = WorkbookSheet(id: activeID, name: sheetName, receipt: receipt)
        var snapshot = sheets
        if let index = snapshot.firstIndex(where: { $0.id == activeID }) { snapshot[index] = active }
        else if snapshot.isEmpty { snapshot = [active] }
        else { return nil }
        return WorkbookReceipt(version: 2, title: title, sheets: snapshot, selectedID: activeID)
    }
    private var hasUnsavedChanges: Bool {
        pendingCell || currentReceipt?.title != savedReceipt?.title || currentReceipt?.sheets != savedReceipt?.sheets
    }
    private var workbookControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Current Sheet") {
                Picker("", selection: Binding(get: { activeID }, set: { switchSheet($0) })) {
                    ForEach(sheets) { sheet in Text(sheet.id == activeID ? sheetName : sheet.name).tag(sheet.id) }
                }.pickerStyle(.menu).disabled(pendingCell)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Sheet Name").font(.caption).foregroundStyle(.secondary)
                TextField("Unique name, up to 31 chars", text: $sheetName).agentField().focused($focusedField, equals: .sheetName).accessibilityLabel("Sheet name")
            }
            Text("\(sheets.count)/12 sheets · Names identify each sheet; apply cell changes before switching. Names must be unique, can't contain []:*?/\\, can't start or end with a single quote, and can't be History.") .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Add Sheet") { addSheet() }.disabled(pendingCell || sheets.count >= 12)
                Spacer()
                Button("Delete Current Sheet", role: .destructive) { focusedField = nil; activeAlert = .removeSheet(activeID) }.disabled(pendingCell || sheets.count <= 1)
            }.frame(minHeight: 44)
        }
    }
    private func commitSheet() throws {
        guard !pendingCell, let value = currentReceipt else { throw AgentError.message("Apply the current cell change first") }
        try value.checked(); sheets = value.sheets
    }
    private func selectSheet(_ sheet: WorkbookSheet) throws {
        let value = try sheet.receipt.checked()
        activeID = sheet.id; sheetName = sheet.name; apply(value)
        chart = sheet.receipt.chart; chartEnabled = sheet.receipt.chartEnabled
        error = ""; focusedField = nil
    }
    private func switchSheet(_ id: UUID) {
        guard id != activeID else { return }
        do { try commitSheet(); guard let target = sheets.first(where: { $0.id == id }) else { return }; try selectSheet(target) }
        catch { self.error = error.localizedDescription }
    }
    private func addSheet() {
        do {
            try commitSheet(); guard sheets.count < 12 else { throw AgentError.message("Up to 12 sheets") }
            let names = Set(sheets.map { $0.name.lowercased() }); var number = 1
            while names.contains("sheet\(number)") { number += 1 }
            let name = "Sheet\(number)"
            let value = try SpreadsheetDraft(text: "Item\tValue\n\t")
            let receipt = SheetReceipt(version: 1, title: name, rows: value.rows, chart: SheetChartSpec(valueColumns: [1], lastRow: 1), chartEnabled: false)
            let item = WorkbookSheet(id: UUID(), name: name, receipt: receipt)
            sheets.append(item); try selectSheet(item); message = "Sheet added; workbook not saved yet"
        } catch { self.error = error.localizedDescription }
    }
    private func removeSheet(_ id: UUID) {
        do {
            try commitSheet(); guard sheets.count > 1, let index = sheets.firstIndex(where: { $0.id == id }) else { return }
            sheets.remove(at: index)
            if activeID == id { try selectSheet(sheets[min(index, sheets.count - 1)]) }
            message = "Sheet removed; workbook not saved yet"
        } catch { self.error = error.localizedDescription }
    }
    private func restore(_ value: WorkbookReceipt) throws {
        try value.checked()
        guard let active = value.sheets.first(where: { $0.id == value.selectedID }) else { throw AgentError.message("Workbook has no current sheet") }
        sheets = value.sheets; title = value.title; try selectSheet(active)
    }
    private var pendingCell: Bool {
        guard let draft, draft.rows.indices.contains(selected.row), (0..<draft.columns).contains(selected.column) else { return false }
        return cellText != draft.rows[selected.row][selected.column]
    }
    private func grid(_ draft: SpreadsheetDraft) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) { Text("Row").frame(width: 38); ForEach(0..<draft.columns, id: \.self) { Text(String(UnicodeScalar(65 + $0)!)).font(.headline).frame(width: 120) } }
                ForEach(draft.rows.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        Text("\(row + 1)").font(.caption).frame(width: 38)
                        ForEach(0..<draft.columns, id: \.self) { column in
                            let address = SheetAddress(row: row, column: column)
                            let value = values?[row][column].display ?? draft.rows[row][column]
                            Button { selected = address; cellText = draft.rows[row][column] } label: {
                                Text(value.isEmpty ? " " : value).lineLimit(2).frame(width: 104, height: 44, alignment: .leading).padding(.horizontal, 8)
                                    .background(selected == address ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).disabled(pendingCell).accessibilityLabel("\(address.name), \(value.isEmpty ? "blank" : value)").accessibilityHint("Edit this cell")
                        }
                    }
                }
            }
        }.frame(height: CGFloat(min(360, max(144, (draft.rows.count + 1) * 48))))
    }
    private var chartPreview: some View {
        let labels = Dictionary(points.map { (String($0.row), $0.label) }, uniquingKeysWith: { first, _ in first })
        return ScrollView(.horizontal) {
            Chart(points) { point in
                if chart.kind == .column {
                    BarMark(x: .value("Row", String(point.row)), y: .value("Value", point.value)).foregroundStyle(by: .value("Series", point.name)).position(by: .value("Series", point.name))
                } else {
                    LineMark(x: .value("Row", String(point.row)), y: .value("Value", point.value)).foregroundStyle(by: .value("Series", point.name)).symbol(by: .value("Series", point.name))
                }
            }.chartXAxis { AxisMarks { value in AxisGridLine(); AxisTick(); AxisValueLabel { if let key = value.as(String.self) { Text(labels[key] ?? key).font(.caption2).frame(width: 64) } } } }
                .frame(width: CGFloat(max(320, labels.count * 80)), height: 340).padding(.bottom, 12)
        }.accessibilityLabel("\(chart.kind.rawValue). Full values and labels are in Chart Data.")
    }
    private func apply(_ value: SpreadsheetDraft) {
        draft = value; selected = SheetAddress(row: 0, column: 0); cellText = value.rows[0][0]; values = nil; points = []; message = ""
        chart = SheetChartSpec(valueColumns: value.columns > 1 ? [1] : [], lastRow: max(1, min(4, value.rows.count - 1)))
    }
    private func editCell() -> Bool {
        guard var value = draft else { return false }
        value.rows[selected.row][selected.column] = cellText
        do { try value.validate(); draft = value; values = nil; points = []; message = "Applied. Recalculate."; error = ""; return true } catch { self.error = error.localizedDescription; return false }
    }
    private func resize(row: Bool, add: Bool) {
        guard var value = draft else { return }
        if row { if add { value.rows.append(Array(repeating: "", count: value.columns)) } else { value.rows.removeLast() } }
        else { value.rows = value.rows.map { var cells = $0; if add { cells.append("") } else { cells.removeLast() }; return cells } }
        do { try value.validate(); apply(value); message = "Size updated and chart range reset. Check formula addresses."; error = "" } catch { self.error = error.localizedDescription }
    }
    private func currentValues() throws -> [[SheetValue]] {
        guard let workbook = currentReceipt, let index = workbook.sheets.firstIndex(where: { $0.id == activeID }) else { throw AgentError.message("No sheet to calculate") }
        return try workbook.calculated()[index]
    }
    private func calculate() {
        guard let draft else { return }
        do { let result = try currentValues(); values = result; points = chartEnabled ? try draft.chart(chart, values: result) : []; error = ""; message = "Recalculated" } catch { points = []; self.error = error.localizedDescription; message = "" }
    }
    private func export(_ ext: String) {
        guard let draft else { return }
        do {
            let data: Data
            var snapshot: WorkbookReceipt?
            switch ext {
            case "xlsx":
                guard let workbook = currentReceipt else { throw AgentError.message("No workbook to export") }; data = try SpreadsheetFiles.excel(workbook)
            case "csv": data = try SpreadsheetFiles.csv(draft, values: currentValues())
            case "svg": data = try SpreadsheetFiles.svg(draft, title: title, chart: chart, values: currentValues())
            default:
                guard let receipt = currentReceipt else { throw AgentError.message("No workbook to save") }
                try receipt.checked(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; data = try encoder.encode(receipt)
                guard data.count <= WorkbookReceipt.maxBytes else { throw AgentError.message("Workbook JSON exceeds 2 MB") }; snapshot = receipt
            }
            exportReceipt = snapshot; document = ArtifactDocument(data: data); exportType = UTType(filenameExtension: ext) ?? .data; exportName = ArtifactFiles.filename(title) + "." + ext; exporting = true; error = ""; message = ""
        } catch { self.error = error.localizedDescription; message = "" }
    }
}

// Formula punctuation must remain literal even when system Smart Punctuation is enabled.
private struct SheetCellInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onApply: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear; view.textColor = .label
        view.font = .preferredFont(forTextStyle: .body); view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.smartQuotesType = .no; view.smartDashesType = .no
        view.keyboardType = .asciiCapable
        view.autocorrectionType = .no; view.spellCheckingType = .no; view.autocapitalizationType = .none
        view.accessibilityLabel = "Cell contents"
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        toolbar.items = [.init(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                         .init(title: "Apply Cell", style: .plain, target: context.coordinator, action: #selector(Coordinator.applyCell)),
                         .init(title: "Hide Keyboard", style: .plain, target: context.coordinator, action: #selector(Coordinator.hideKeyboard))]
        view.inputAccessoryView = toolbar; context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text, view.markedTextRange == nil { view.text = text }
        if !isFocused, view.isFirstResponder { view.resignFirstResponder() }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SheetCellInput
        weak var view: UITextView?
        init(_ parent: SheetCellInput) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text }
        func textViewDidBeginEditing(_ view: UITextView) { if !parent.isFocused { parent.isFocused = true } }
        func textViewDidEndEditing(_ view: UITextView) { if parent.isFocused { parent.isFocused = false } }
        @objc func applyCell() { parent.onApply() }
        @objc func hideKeyboard() { parent.isFocused = false; view?.resignFirstResponder() }
    }
}
