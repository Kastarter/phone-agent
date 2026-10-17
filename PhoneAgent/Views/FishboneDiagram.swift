import Foundation
import CoreGraphics
import CoreText
import ImageIO

enum FishboneDiagram {
    struct Label {
        let text: String
        let x: CGFloat
        let baseline: CGFloat
        let size: CGFloat
        let bold: Bool
        let orange: Bool
        let width: CGFloat
    }
    struct Segment { let from: CGPoint; let to: CGPoint; let dashed: Bool }
    struct CauseRegion { let text: String; let bounds: CGRect }
    struct Layout {
        let size: CGSize
        let labels: [Label]
        let segments: [Segment]
        let head: CGRect
        let referenceText: String
        let causes: [CauseRegion]
    }
    private struct Wrapped { let lines: [(String, CGFloat, CGFloat)]; let height: CGFloat }
    private static func font(_ size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
    }
    private static func wrap(_ text: String, width: CGFloat, size: CGFloat, bold: Bool = false) -> Wrapped {
        let face = font(size, bold: bold)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): face])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let original = text as NSString; var position = 0; var lines: [(String, CGFloat, CGFloat)] = []
        let lineHeight = ceil(CTFontGetAscent(face) + CTFontGetDescent(face) + CTFontGetLeading(face) + 5)
        while position < original.length {
            var count = max(1, CTTypesetterSuggestLineBreak(typesetter, position, Double(width)))
            let remainder = original.length-position-count
            if (1...4).contains(remainder) {
                let first = original.substring(with: NSRange(location: position, length: count))
                let tail = original.substring(from: position+count)
                if first.rangeOfCharacter(from: .newlines) == nil, !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    count = max(1, CTTypesetterSuggestLineBreak(typesetter, position, Double(width*0.65)))
                }
            }
            let value = original.substring(with: NSRange(location: position, length: min(count, original.length-position))).trimmingCharacters(in: .newlines)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): face]))
            lines.append((value, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), CTFontGetAscent(face)))
            position += count
        }
        return Wrapped(lines: lines, height: CGFloat(max(1, lines.count)) * lineHeight)
    }
    static func layout(notes: MeetingNotes, source: String) throws -> Layout {
        try Task.checkCancellation()
        try notes.validate(source: source)
        guard let bone = notes.fishbone else { throw AgentError.message("These notes have no fishbone diagram; add a problem and causes first") }
        let columns = (bone.groups.count + 1) / 2
        let width = CGFloat(max(1100, columns*400+340)); let headX = width-290
        let columnWidth = (headX-60)/CGFloat(columns)
        let causeWidth = min(270, columnWidth-140)
        let heading = wrap(notes.title, width: width-80, size: 30, bold: true)
        let legend = wrap("Cause summary · Orange dashed lines are unverified hypotheses · Citation numbers refer to the notes · Not proven causation", width: width-80, size: 16)
        let headerHeight = 40 + heading.height + 12 + legend.height + 32
        var texts: [[Wrapped]] = []; var heights: [CGFloat] = []; var index = 0
        for group in bone.groups {
            try Task.checkCancellation()
            let names = group.causes.map { cause -> String in index += 1; return "[\(index)] \(cause.hypothesis ? "Hypothesis: " : "")\(cause.text)" }
            let values = names.map { wrap($0, width: causeWidth, size: 16) }
            texts.append(values)
            heights.append(values.reduce(0) { $0 + $1.height + 18 })
        }
        let categories = bone.groups.map { wrap($0.name, width: columnWidth-40, size: 21, bold: true) }
        let categoryBand = max(40, categories.map(\.height).max() ?? 40)
        let upperHeight = max(120, heights.enumerated().filter { $0.offset % 2 == 0 }.map(\.element).max() ?? 0)
        let lowerHeight = max(120, heights.enumerated().filter { $0.offset % 2 == 1 }.map(\.element).max() ?? 0)
        let problem = wrap(bone.problem.text, width: 210, size: 20, bold: true)
        let centerPadding = max(72, problem.height/2 + 24)
        let spine = headerHeight + categoryBand + 14 + upperHeight + centerPadding
        let lowerEnd = spine + centerPadding + lowerHeight
        let height = lowerEnd + 38 + categoryBand + 60
        guard width*height <= 12_000_000, height <= 12000 else { throw AgentError.message("Fishbone diagram is too large; reduce causes or extra line breaks. Nothing was truncated") }
        var labels: [Label] = []; var segments: [Segment] = []; var regions: [CauseRegion] = []
        func add(_ value: Wrapped, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, orange: Bool = false) {
            let step = value.height / CGFloat(max(1,value.lines.count))
            for (i,line) in value.lines.enumerated() { labels.append(.init(text:line.0,x:x,baseline:y+CGFloat(i)*step+line.2,size:size,bold:bold,orange:orange,width:line.1)) }
        }
        add(heading,x:40,y:32,size:30,bold:true)
        add(legend,x:40,y:44+heading.height,size:16)
        segments.append(.init(from:CGPoint(x:30,y:spine),to:CGPoint(x:headX,y:spine),dashed:false))
        segments.append(.init(from:CGPoint(x:headX-14,y:spine-9),to:CGPoint(x:headX,y:spine),dashed:false))
        segments.append(.init(from:CGPoint(x:headX-14,y:spine+9),to:CGPoint(x:headX,y:spine),dashed:false))
        for (g,group) in bone.groups.enumerated() {
            try Task.checkCancellation()
            let upper = g % 2 == 0
            let x = 40+CGFloat(g/2)*columnWidth
            let join = CGPoint(x:x+columnWidth-30,y:spine)
            let outer = CGPoint(x:join.x-90,y:upper ? headerHeight+categoryBand : lowerEnd+24)
            segments.append(.init(from:outer,to:join,dashed:false))
            let category = categories[g]
            add(category,x:x,y:upper ? headerHeight : lowerEnd+38,size:21,bold:true)
            var y = upper ? headerHeight+categoryBand+14 : spine+centerPadding
            for (c,cause) in group.causes.enumerated() {
                let value = texts[g][c]
                regions.append(.init(text: cause.text, bounds: CGRect(x: x, y: y, width: causeWidth, height: value.height)))
                add(value,x:x,y:y,size:16,orange:cause.hypothesis)
                let mid = y+value.height/2
                let fraction = (mid-outer.y)/(join.y-outer.y)
                let boneX = outer.x+(join.x-outer.x)*fraction
                segments.append(.init(from:CGPoint(x:x+causeWidth+8,y:mid),to:CGPoint(x:boneX,y:mid),dashed:cause.hypothesis))
                y += value.height+18
            }
        }
        let head = CGRect(x:headX,y:spine-problem.height/2-22,width:250,height:problem.height+44)
        add(problem,x:headX+20,y:head.minY+22,size:20,bold:true)
        add(wrap("Draft summary · Verify against the source and transcript",width:width-80,size:14),x:40,y:height-38,size:14)
        // Validate actual text/path extents before producing an artifact.
        guard labels.allSatisfy({ $0.x >= 0 && $0.x+$0.width <= width && $0.baseline >= 0 && $0.baseline+8 <= height }),
              segments.allSatisfy({ [$0.from,$0.to].allSatisfy { $0.x >= 0 && $0.x <= width && $0.y >= 0 && $0.y <= height } }) else { throw AgentError.message("Fishbone content can't be fully laid out; reduce line breaks or adjust the text") }
        return .init(size:CGSize(width:width,height:height),labels:labels,segments:segments,head:head,referenceText:notes.plainText,causes:regions)
    }
    static func draw(_ layout: Layout, in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(origin:.zero,size:layout.size))
        context.setLineWidth(2)
        for segment in layout.segments {
            context.setStrokeColor(segment.dashed ? CGColor(red:0.69,green:0.31,blue:0.05,alpha:1) : CGColor(gray:0.45,alpha:1))
            context.setLineDash(phase:0,lengths:segment.dashed ? [6,4] : [])
            context.beginPath(); context.move(to:segment.from); context.addLine(to:segment.to); context.strokePath()
        }
        context.setLineDash(phase:0,lengths:[])
        context.setFillColor(CGColor(red:0.92,green:0.95,blue:0.98,alpha:1))
        context.addPath(CGPath(roundedRect:layout.head,cornerWidth:16,cornerHeight:16,transform:nil)); context.fillPath()
        context.textMatrix = CGAffineTransform(scaleX:1,y:-1)
        for label in layout.labels {
            let color = label.orange ? CGColor(red:0.69,green:0.31,blue:0.05,alpha:1) : CGColor(gray:0.09,alpha:1)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:label.text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font(label.size,bold:label.bold),NSAttributedString.Key(kCTForegroundColorAttributeName as String):color]))
            context.textPosition = CGPoint(x:label.x,y:label.baseline); CTLineDraw(line,context)
        }
    }
    static func image(_ layout: Layout) throws -> CGImage {
        try Task.checkCancellation()
        guard let context = CGContext(data:nil,width:Int(ceil(layout.size.width)),height:Int(ceil(layout.size.height)),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AgentError.message("Can't allocate the fishbone canvas") }
        context.translateBy(x:0,y:layout.size.height); context.scaleBy(x:1,y:-1); draw(layout,in:context)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw AgentError.message("Can't generate the fishbone preview") }; return image
    }
    static func png(_ layout: Layout) throws -> Data {
        let bytes = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(bytes,"public.png" as CFString,1,nil) else { throw AgentError.message("Can't create PNG") }
        CGImageDestinationAddImage(output,try image(layout),nil)
        guard CGImageDestinationFinalize(output) else { throw AgentError.message("PNG export failed") }; return bytes as Data
    }
    static func pdf(_ layout: Layout) throws -> Data {
        let bytes = NSMutableData(); var media = CGRect(origin:.zero,size:layout.size)
        guard let consumer = CGDataConsumer(data:bytes), let context = CGContext(consumer:consumer,mediaBox:&media,nil) else { throw AgentError.message("Can't create fishbone PDF") }
        context.beginPDFPage(nil); context.translateBy(x:0,y:layout.size.height); context.scaleBy(x:1,y:-1)
        draw(layout,in:context); context.endPDFPage(); context.closePDF(); return bytes as Data
    }
    static func svg(_ layout: Layout) -> Data {
        func xml(_ text:String)->String { text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;") }
        func number(_ n:CGFloat)->String { String(format:"%.2f",locale:Locale(identifier:"en_US_POSIX"),Double(n)) }
        var body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(number(layout.size.width))\" height=\"\(number(layout.size.height))\" viewBox=\"0 0 \(number(layout.size.width)) \(number(layout.size.height))\"><title>Fishbone Diagram Draft</title><desc>\(xml(layout.referenceText))</desc><rect width=\"100%\" height=\"100%\" fill=\"white\"/>"
        for line in layout.segments { body += "<line x1=\"\(number(line.from.x))\" y1=\"\(number(line.from.y))\" x2=\"\(number(line.to.x))\" y2=\"\(number(line.to.y))\" stroke=\"\(line.dashed ? "#b04f0d" : "#737373")\" stroke-width=\"2\"\(line.dashed ? " stroke-dasharray=\"6 4\"" : "")/>" }
        body += "<rect x=\"\(number(layout.head.minX))\" y=\"\(number(layout.head.minY))\" width=\"\(number(layout.head.width))\" height=\"\(number(layout.head.height))\" rx=\"16\" fill=\"#ebf2fa\"/>"
        for label in layout.labels { body += "<text x=\"\(number(label.x))\" y=\"\(number(label.baseline))\" font-family=\"PingFang SC, Noto Sans CJK SC, sans-serif\" font-size=\"\(number(label.size))\" font-weight=\"\(label.bold ? "600" : "400")\" fill=\"\(label.orange ? "#b04f0d" : "#171717")\" xml:space=\"preserve\"\(label.width > 0 ? " textLength=\"\(number(label.width))\" lengthAdjust=\"spacingAndGlyphs\"" : "")>\(xml(label.text))</text>" }
        return Data((body+"</svg>").utf8)
    }
}
