import Foundation

struct SheetAddress: Hashable {
    let row: Int
    let column: Int
    var name: String { String(UnicodeScalar(65 + column)!) + String(row + 1) }
    static func parse(_ input: String) -> SheetAddress? {
        let normalized = input.uppercased()
        guard normalized.range(of: #"^\$?[A-Z]\$?[1-9][0-9]{0,2}$"#, options: .regularExpression) != nil else { return nil }
        let bytes = Array(normalized.utf8).filter { $0 != 36 }
        guard let first = bytes.first, (65...90).contains(first), bytes.count > 1,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) }), bytes[1] != 48,
              let row = Int(String(decoding: bytes.dropFirst(), as: UTF8.self)), (1...200).contains(row) else { return nil }
        return SheetAddress(row: row - 1, column: Int(first - 65))
    }
}

enum SheetValue: Equatable {
    case number(Double), text(String), empty, error(String)
    var display: String {
        switch self {
        case .number(let value): return value == 0 ? "0" : String(value)
        case .text(let value), .error(let value): return value
        case .empty: return ""
        }
    }
}

struct SheetChartSpec: Equatable, Codable {
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case column = "Column Chart", line = "Line Chart"
        var id: String { rawValue }
    }
    var kind: Kind = .column
    var labelColumn = 0
    var valueColumns = [1]
    var firstRow = 1
    var lastRow = 4
}

struct SheetChartPoint: Identifiable, Equatable {
    let row: Int
    let series: Int
    let label: String
    let name: String
    let value: Double
    var id: String { "\(row)-\(series)" }
}

struct SpreadsheetDraft: Equatable {
    var rows: [[String]]
    init(text: String) throws {
        guard !text.isEmpty, text.count <= 12000 else { throw AgentError.message("Table content must be 1–12,000 characters") }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        let values = lines.map { $0.components(separatedBy: "\t") }
        let width = values.map(\.count).max() ?? 1
        rows = values.map { $0 + Array(repeating: "", count: width - $0.count) }
        try validate()
    }
    var text: String { rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") }
    var columns: Int { rows.first?.count ?? 0 }
    func validate() throws {
        guard (1...200).contains(rows.count), (1...26).contains(columns), rows.allSatisfy({ $0.count == columns }), text.count <= 12000,
              rows.flatMap({ $0 }).allSatisfy({ $0.count <= 3000 && !$0.contains("\t") && !$0.contains("\n") && !$0.contains("\r") && $0.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF }) }) else {
            throw AgentError.message("Up to 200 rows, 26 columns, and 12,000 characters; each cell up to 3,000 characters with no line breaks or control characters")
        }
    }
    func calculated() throws -> [[SheetValue]] { try validate(); return SheetCalculator(self).all() }
    func chart(_ spec: SheetChartSpec, values: [[SheetValue]]) throws -> [SheetChartPoint] {
        try validate()
        guard values.count == rows.count, values.allSatisfy({ $0.count == columns }),
              (0..<columns).contains(spec.labelColumn), (1...3).contains(spec.valueColumns.count),
              Set(spec.valueColumns).count == spec.valueColumns.count,
              spec.valueColumns.allSatisfy({ (0..<columns).contains($0) && $0 != spec.labelColumn }),
              spec.firstRow >= 1, spec.lastRow >= spec.firstRow, spec.lastRow < rows.count,
              spec.lastRow - spec.firstRow < 60 else { throw AgentError.message("Charts use 1–60 rows after the header, one label column, and 1–3 value columns. Check the row and column range") }
        var points: [SheetChartPoint] = []
        for row in spec.firstRow...spec.lastRow {
            let label = values[row][spec.labelColumn].display
            guard label.count <= 120 else { throw AgentError.message("Chart labels can be up to 120 characters") }
            if case .error = values[row][spec.labelColumn] { throw AgentError.message("The label column contains a formula error. Fix it first") }
            for column in spec.valueColumns {
                guard case .number(let value) = values[row][column], value.isFinite, abs(value) <= 1e100 else { throw AgentError.message("\(SheetAddress(row: row, column: column).name) is not a chartable number; the row was not skipped") }
                let header = values[0][column].display
                guard header.count <= 120 else { throw AgentError.message("Chart series names can be up to 120 characters") }
                if case .error = values[0][column] { throw AgentError.message("The chart header contains an error. Fix it first") }
                points.append(SheetChartPoint(row: row, series: column, label: label.isEmpty ? "Row \(row + 1)" : label, name: (header.isEmpty ? "Value" : header) + " (\(String(UnicodeScalar(65 + column)!)))", value: value))
            }
        }
        return points
    }
}

// No JavaScript, NSExpression, macros, URLs, external links or workbook code.
// The parser accepts only this documented arithmetic and function grammar.
private struct SheetReference: Hashable {
    let sheet: Int
    let address: SheetAddress
}
private final class SheetCalculator {
    let sheets: [SpreadsheetDraft]
    let names: [String]
    var cache: [SheetReference: SheetValue] = [:]
    var active: Set<SheetReference> = []
    var work = 0
    init(_ sheet: SpreadsheetDraft) { sheets = [sheet]; names = ["Sheet1"] }
    init(sheets: [SpreadsheetDraft], names: [String]) { self.sheets = sheets; self.names = names }
    func index(named name: String) -> Int? {
        names.firstIndex { $0.precomposedStringWithCanonicalMapping.lowercased() == name.precomposedStringWithCanonicalMapping.lowercased() }
    }
    func all(in index: Int = 0) -> [[SheetValue]] {
        let sheet = sheets[index]
        return sheet.rows.indices.map { row in (0..<sheet.columns).map { cell(SheetAddress(row: row, column: $0), in: index) } }
    }
    func cell(_ address: SheetAddress, in index: Int = 0) -> SheetValue {
        guard sheets.indices.contains(index) else { return .error("#REF!") }
        let sheet = sheets[index], reference = SheetReference(sheet: index, address: address)
        guard sheet.rows.indices.contains(address.row), (0..<sheet.columns).contains(address.column) else { return .error("#REF!") }
        if let value = cache[reference] { return value }
        guard !active.contains(reference) else { return .error("#CYCLE!") }
        guard active.count < 64, work < 100000 else { return .error("#LIMIT!") }
        work += 1
        active.insert(reference); defer { active.remove(reference) }
        let raw = sheet.rows[address.row][address.column]
        let input = raw.trimmingCharacters(in: .whitespaces)
        let value: SheetValue
        if input.hasPrefix("'") { value = .text(String(input.dropFirst())) }
        else if input.hasPrefix("=") {
            if input.utf8.count > 512 { value = .error("#LIMIT!") }
            else {
                do { var parser = SheetFormula(String(input.dropFirst()), calculator: self, sheet: index); value = .number(try parser.parse()) }
                catch let failure as SheetFailure { value = .error(failure.code) }
                catch { value = .error("#FORMULA!") }
            }
        } else if input.isEmpty { value = .empty }
        else if let number = SheetFormula.number(input) { value = .number(number) }
        else { value = .text(raw) }
        cache[reference] = value; return value
    }
    func consume() throws { work += 1; guard work <= 100000 else { throw SheetFailure(code: "#LIMIT!") } }
}
private struct SheetFailure: Error { let code: String }
private struct SheetFormula {
    let bytes: [UInt8]
    let calculator: SheetCalculator
    let sheet: Int
    var cursor = 0
    var depth = 0
    init(_ text: String, calculator: SheetCalculator, sheet: Int) { bytes = Array(text.utf8); self.calculator = calculator; self.sheet = sheet }
    static func number(_ text: String) -> Double? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) || [43,45,46,69,101].contains($0) }), let value = Double(text), value.isFinite, abs(value) <= 1e100 else { return nil }
        return value
    }
    mutating func space() { while cursor < bytes.count && bytes[cursor] == 32 { cursor += 1 } }
    mutating func take(_ byte: UInt8) -> Bool { space(); if cursor < bytes.count && bytes[cursor] == byte { cursor += 1; return true }; return false }
    func finite(_ value: Double) throws -> Double { guard value.isFinite, abs(value) <= 1e100 else { throw SheetFailure(code: "#NUM!") }; return value == 0 ? 0 : value }
    mutating func parse() throws -> Double { let result = try expression(); space(); guard cursor == bytes.count else { throw SheetFailure(code: "#FORMULA!") }; return try finite(result) }
    mutating func expression() throws -> Double {
        var result = try term()
        while true { if take(43) { result = try finite(result + term()) } else if take(45) { result = try finite(result - term()) } else { return result } }
    }
    mutating func term() throws -> Double {
        var result = try unary()
        while true {
            if take(42) { result = try finite(result * unary()) }
            else if take(47) { let divisor = try unary(); guard divisor != 0 else { throw SheetFailure(code: "#DIV/0!") }; result = try finite(result / divisor) }
            else { return result }
        }
    }
    mutating func unary() throws -> Double {
        try calculator.consume(); depth += 1; defer { depth -= 1 }
        guard depth <= 64 else { throw SheetFailure(code: "#LIMIT!") }
        if take(43) { return try unary() }
        if take(45) { return try finite(-unary()) }
        var result = try atom()
        while take(37) { result /= 100 }
        return try finite(result)
    }
    func scalar(_ value: SheetValue) throws -> Double {
        switch value { case .number(let value): return value; case .empty: return 0; case .error(let code): throw SheetFailure(code: code); case .text: throw SheetFailure(code: "#VALUE!") }
    }
    mutating func word() -> String {
        space(); let start = cursor
        while cursor < bytes.count && ((65...90).contains(bytes[cursor]) || (97...122).contains(bytes[cursor]) || (48...57).contains(bytes[cursor]) || [36,95,46].contains(bytes[cursor])) { cursor += 1 }
        return String(decoding: bytes[start..<cursor], as: UTF8.self)
    }
    mutating func reference(defaultSheet: Int? = nil) throws -> SheetReference? {
        space(); let start = cursor
        var target = defaultSheet ?? sheet
        let addressName: String
        if take(39) {
            var name: [UInt8] = []; var closed = false
            while cursor < bytes.count {
                let byte = bytes[cursor]; cursor += 1
                if byte == 39 {
                    if cursor < bytes.count && bytes[cursor] == 39 { name.append(39); cursor += 1 }
                    else { closed = true; break }
                } else { name.append(byte) }
            }
            guard closed, take(33) else { throw SheetFailure(code: "#FORMULA!") }
            guard let index = calculator.index(named: String(decoding: name, as: UTF8.self)) else { throw SheetFailure(code: "#REF!") }
            target = index; addressName = word()
        } else {
            let name = word()
            if take(33) {
                guard let first = name.utf8.first, (65...90).contains(first) || (97...122).contains(first) || first == 95,
                      !name.contains("$"), let index = calculator.index(named: name) else { throw SheetFailure(code: "#REF!") }
                target = index; addressName = word()
            } else {
                guard let address = SheetAddress.parse(name) else { cursor = start; return nil }
                return SheetReference(sheet: target, address: address)
            }
        }
        guard let address = SheetAddress.parse(addressName) else { throw SheetFailure(code: "#REF!") }
        return SheetReference(sheet: target, address: address)
    }
    mutating func atom() throws -> Double {
        if take(40) { let value = try expression(); guard take(41) else { throw SheetFailure(code: "#FORMULA!") }; return value }
        space(); guard cursor < bytes.count else { throw SheetFailure(code: "#FORMULA!") }
        if let reference = try reference() { return try scalar(calculator.cell(reference.address, in: reference.sheet)) }
        if (65...90).contains(bytes[cursor]) || (97...122).contains(bytes[cursor]) || bytes[cursor] == 95 || bytes[cursor] == 36 {
            let name = word().uppercased()
            if take(40) { return try function(name) }
            throw SheetFailure(code: "#REF!")
        }
        let start = cursor
        while cursor < bytes.count && ((48...57).contains(bytes[cursor]) || bytes[cursor] == 46) { cursor += 1 }
        if cursor < bytes.count && [69,101].contains(bytes[cursor]) {
            cursor += 1
            if cursor < bytes.count && [43,45].contains(bytes[cursor]) { cursor += 1 }
            while cursor < bytes.count && (48...57).contains(bytes[cursor]) { cursor += 1 }
        }
        guard let value = Self.number(String(decoding: bytes[start..<cursor], as: UTF8.self)) else { throw SheetFailure(code: "#FORMULA!") }
        return value
    }
    mutating func argument() throws -> [Double] {
        let saved = cursor
        if let first = try reference() {
            if take(58) {
                guard let last = try reference(defaultSheet: first.sheet), first.sheet == last.sheet,
                      first.address.row <= last.address.row, first.address.column <= last.address.column else { throw SheetFailure(code: "#REF!") }
                let target = calculator.sheets[first.sheet]
                guard last.address.row < target.rows.count, last.address.column < target.columns else { throw SheetFailure(code: "#REF!") }
                var values: [Double] = []
                for row in first.address.row...last.address.row { for column in first.address.column...last.address.column {
                    try calculator.consume()
                    switch calculator.cell(SheetAddress(row: row, column: column), in: first.sheet) {
                    case .number(let value): values.append(value)
                    case .error(let code): throw SheetFailure(code: code)
                    case .empty, .text: break
                    }
                } }
                return values
            }
            space()
            if cursor == bytes.count || [44,41].contains(bytes[cursor]) {
                switch calculator.cell(first.address, in: first.sheet) { case .number(let value): return [value]; case .error(let code): throw SheetFailure(code: code); case .text, .empty: return [] }
            }
        }
        cursor = saved; return [try expression()]
    }
    mutating func function(_ name: String) throws -> Double {
        guard ["SUM", "AVERAGE", "MIN", "MAX", "COUNT", "ROUND"].contains(name) else { throw SheetFailure(code: "#NAME?") }
        if name == "ROUND" {
            let value = try expression(); guard take(44) else { throw SheetFailure(code: "#FORMULA!") }
            let digits = try expression()
            guard take(41), digits.rounded(.towardZero) == digits, (-6...6).contains(digits) else { throw SheetFailure(code: "#VALUE!") }
            let scale = pow(10, digits)
            return try finite((value * scale).rounded(.toNearestOrAwayFromZero) / scale)
        }
        var values: [Double] = []; var arguments = 0
        repeat {
            arguments += 1; guard arguments <= 100 else { throw SheetFailure(code: "#LIMIT!") }
            values += try argument()
        } while take(44)
        guard take(41) else { throw SheetFailure(code: "#FORMULA!") }
        switch name {
        case "COUNT": return Double(values.count)
        case "SUM": return try values.reduce(0) { try finite($0 + $1) }
        case "AVERAGE": guard !values.isEmpty else { throw SheetFailure(code: "#DIV/0!") }; return try finite(values.reduce(0, +) / Double(values.count))
        case "MIN": return values.min() ?? 0
        default: return values.max() ?? 0
        }
    }
}

struct SheetReceipt: Codable, Equatable {
    let version: Int
    let title: String
    let rows: [[String]]
    let chart: SheetChartSpec
    let chartEnabled: Bool
    func checked() throws -> SpreadsheetDraft {
        guard version == 1, title.count <= 120 else { throw AgentError.message("Invalid spreadsheet draft version or title") }
        var draft = try SpreadsheetDraft(text: " ")
        draft.rows = rows; try draft.validate()
        guard (1...max(1, rows.count - 1)).contains(chart.firstRow),
              (1...max(1, rows.count - 1)).contains(chart.lastRow), (0..<draft.columns).contains(chart.labelColumn), chart.valueColumns.count <= 3,
              Set(chart.valueColumns).count == chart.valueColumns.count, chart.valueColumns.allSatisfy({ (0..<draft.columns).contains($0) && $0 != chart.labelColumn }) else { throw AgentError.message("Invalid draft chart range") }
        return draft
    }
}


// Version 2 preserves raw formulas; calculation resolves references inside this workbook only.
struct WorkbookSheet: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var receipt: SheetReceipt
}
struct WorkbookReceipt: Codable, Equatable {
    let version: Int
    var title: String
    var sheets: [WorkbookSheet]
    var selectedID: UUID
    static let maxBytes = 2_000_000
    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf16.count <= 31 &&
        !name.contains(where: { "[]:*?/\\".contains($0) }) && !name.hasPrefix("'") && !name.hasSuffix("'") &&
        name.lowercased() != "history" && name.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF }
    }
    func checked() throws {
        guard version == 2, title.count <= 120, (1...12).contains(sheets.count),
              Set(sheets.map(\.id)).count == sheets.count, sheets.contains(where: { $0.id == selectedID }),
              sheets.allSatisfy({ Self.validName($0.name) && $0.receipt.title == $0.name }),
              Set(sheets.map { $0.name.precomposedStringWithCanonicalMapping.lowercased() }).count == sheets.count else {
            throw AgentError.message("A workbook can have up to 12 sheets with unique names that follow Excel naming rules (up to 31 characters, no []:*?/\\, no leading or trailing apostrophe, and not named History)")
        }
        var total = 0
        for sheet in sheets { let draft = try sheet.receipt.checked(); total += draft.text.count }
        guard total <= 120000 else { throw AgentError.message("Workbook cell content can total up to 120,000 characters; nothing was truncated or saved") }
    }
    func calculated() throws -> [[[SheetValue]]] {
        try checked()
        let drafts = try sheets.map { try $0.receipt.checked() }
        let calculator = SheetCalculator(sheets: drafts, names: sheets.map(\.name))
        return sheets.indices.map { calculator.all(in: $0) }
    }
    static func decode(_ data: Data) throws -> WorkbookReceipt {
        guard !data.isEmpty, data.count <= maxBytes else { throw AgentError.message("Workbook JSON is empty or larger than 2 MB") }
        struct Version: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Version.self, from: data).version
        let value: WorkbookReceipt
        switch version {
        case 1:
            let old = try JSONDecoder().decode(SheetReceipt.self, from: data); _ = try old.checked()
            let normalized = SheetReceipt(version: 1, title: "Sheet1", rows: old.rows, chart: old.chart, chartEnabled: old.chartEnabled)
            let sheet = WorkbookSheet(id: UUID(), name: "Sheet1", receipt: normalized)
            value = .init(version: 2, title: old.title, sheets: [sheet], selectedID: sheet.id)
        case 2: value = try JSONDecoder().decode(Self.self, from: data)
        default: throw AgentError.message("This workbook draft version is not supported")
        }
        try value.checked(); return value
    }
}
