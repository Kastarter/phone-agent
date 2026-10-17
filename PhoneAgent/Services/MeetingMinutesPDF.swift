import Foundation
import CoreGraphics
import CoreText

// Keep each short statement and its quote on the same page. Very long blocks
// continue with a repeated label; no characters are discarded for pagination.
enum MeetingMinutesPDF {
    private struct Block { let heading: String; let text: String }
    static func make(notes: MeetingNotes, source: String) throws -> Data {
        try notes.validate(source: source); try Task.checkCancellation()
        var blocks = [Block(heading:"Review Notes",text:"Structured meeting minutes draft. Quote matching only confirms the source; it doesn't prove interpretation or causation. Check the transcript, decisions, action items, and hypotheses. Action items don't create reminders or run automatically.")]
        func statement(_ heading: String, _ value: MeetingStatement) { blocks.append(.init(heading:heading,text:value.text+"\nQuote: "+value.quote)) }
        if let summary = notes.summary { statement("Summary",summary) }
        for (i,value) in notes.points.enumerated() { statement("Point \(i+1)",value) }
        for (i,value) in notes.decisions.enumerated() { statement("Decision \(i+1)",value) }
        for (i,value) in notes.actions.enumerated() { blocks.append(.init(heading:"Action \(i+1)",text:value.text+"\nOwner: \(value.owner ?? "Unspecified") · Due: \(value.due ?? "Unspecified")\nQuote: "+value.quote)) }
        for (i,value) in notes.questions.enumerated() { statement("Open Question \(i+1)",value) }
        if let bone = notes.fishbone {
            statement("Fishbone Problem",bone.problem); var index=0
            for group in bone.groups {
                for cause in group.causes { index += 1; blocks.append(.init(heading:"\(group.name) [\(index)] · \(cause.hypothesis ? "Unverified hypothesis" : "Mentioned in source")",text:cause.text+"\nQuote: "+cause.quote)) }
            }
        }
        let bytes=NSMutableData();var media=CGRect(x:0,y:0,width:595,height:842)
        guard let consumer=CGDataConsumer(data:bytes),let context=CGContext(consumer:consumer,mediaBox:&media,nil) else { throw AgentError.message("Can't create minutes PDF") }
        func attributed(_ text:String,size:CGFloat,bold:Bool=false)->NSAttributedString {
            var spacing: CGFloat = 4
            let paragraph = withUnsafePointer(to: &spacing) { pointer in
                var setting = CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: UnsafeRawPointer(pointer))
                return CTParagraphStyleCreate(&setting, 1)
            }
            return NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString,size,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0.1,alpha:1),NSAttributedString.Key(kCTParagraphStyleAttributeName as String):paragraph])
        }
        func height(_ value:NSAttributedString,width:CGFloat)->CGFloat {
            ceil(CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(value),CFRange(location:0,length:0),nil,CGSize(width:width,height:100000),nil).height)+5
        }
        func draw(_ setter:CTFramesetter,offset:Int,x:CGFloat,top:CGFloat,width:CGFloat,height:CGFloat)->Int {
            let path=CGPath(rect:CGRect(x:x,y:842-top-height,width:width,height:height),transform:nil)
            let frame=CTFramesetterCreateFrame(setter,CFRange(location:offset,length:0),path,nil);CTFrameDraw(frame,context)
            return CTFrameGetVisibleStringRange(frame).length
        }
        var page=0;var y:CGFloat=0;var pageHasContent=false;let bottom:CGFloat=784;let width:CGFloat=499
        func newPage() throws {
            if page>0 { context.endPDFPage() }
            guard page<100 else { throw AgentError.message("Minutes PDF exceeds 100 pages; no partial file was exported. Reduce extra line breaks or items.") }
            page += 1;context.beginPDFPage(nil);context.textMatrix = .identity
            let title=attributed(notes.title,size:page==1 ? 23 : 12,bold:true);let titleHeight=height(title,width:width)
            guard titleHeight<160 else { throw AgentError.message("Title wraps too many lines. Shorten it and export again.") }
            guard draw(CTFramesetterCreateWithAttributedString(title),offset:0,x:48,top:42,width:width,height:titleHeight) == title.length else { throw AgentError.message("Minutes title can't be fully laid out") }
            _=draw(CTFramesetterCreateWithAttributedString(attributed("\(page)",size:10)),offset:0,x:286,top:809,width:40,height:20)
            y=42+titleHeight+22;pageHasContent=false
        }
        try newPage()
        for block in blocks {
            try Task.checkCancellation()
            let body=attributed(block.text,size:13);let setter=CTFramesetterCreateWithAttributedString(body)
            let fullHeight=height(body,width:width);let label=attributed(block.heading,size:14,bold:true)
            let labelHeight=height(label,width:width)
            // A normal item moves as a whole. Blocks too large for a fresh page
            // are split deliberately, with a visible continuation heading.
            if pageHasContent, y+labelHeight+fullHeight+20>bottom, fullHeight+labelHeight+20 <= bottom-90 { try newPage() }
            var offset=0;var continued=false
            while offset<body.length {
                try Task.checkCancellation()
                let heading=continued ? attributed(block.heading+" (cont.)",size:14,bold:true) : label
                let headingHeight=height(heading,width:width)
                if y+headingHeight+40>bottom { try newPage() }
                guard headingHeight+40 <= bottom-y,
                      draw(CTFramesetterCreateWithAttributedString(heading),offset:0,x:48,top:y,width:width,height:headingHeight) == heading.length else { throw AgentError.message("A section heading wraps too many lines; no partial content was exported") }
                pageHasContent=true
                y += headingHeight+6
                let available=bottom-y
                let remaining=body.attributedSubstring(from:NSRange(location:offset,length:body.length-offset))
                let remainingHeight=ceil(CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(remaining),CFRange(location:0,length:0),nil,CGSize(width:width,height:100000),nil).height)+5
                let drawnHeight=min(remainingHeight,available)
                let count=draw(setter,offset:offset,x:48,top:y,width:width,height:drawnHeight)
                guard count>0 else { throw AgentError.message("Minutes text can't be paginated; no partial content was exported") }
                offset += count;y += drawnHeight+20
                if offset<body.length { continued=true;try newPage() }
            }
        }
        context.endPDFPage();context.closePDF();return bytes as Data
    }
}
