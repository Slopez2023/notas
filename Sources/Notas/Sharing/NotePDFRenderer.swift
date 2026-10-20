import AppKit
import SwiftUI

/// Text uses the editor's layout fragments. Only interactive object blocks need a print layout.
@MainActor
final class NotePDFRenderer: NSObject, NSTextLayoutManagerDelegate {
    private struct Item {
        let height: CGFloat
        let breaks: [CGFloat]
        let draw: (CGContext) -> Void
    }

    private let file: SharedNoteFile
    private let style: ResolvedStyle
    private var width: CGFloat { style.width.points }
    private let margin: CGFloat = 48

    init(file: SharedNoteFile) {
        self.file = file
        style = ResolvedStyle(style: file.style, systemIsDark: false, appAccent: .violet)
    }

    func render() throws -> Data {
        let storage = NSTextStorage(attributedString: RichTextCodec.attributedString(from: file.content.document))
        EditorStyler(style: style).restyle(storage, around: NSRange(location: 0, length: storage.length))
        // TextKit's standalone fragment renderer otherwise substitutes the system link blue.
        let shareLink = NSAttributedString.Key("notas.shareLink")
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let value else { return }
            storage.addAttributes([shareLink: value, .foregroundColor: style.nsAccent,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: style.nsAccent], range: range)
            storage.removeAttribute(.link, range: range)
        }
        let content = NSTextContentStorage()
        content.textStorage = storage
        let manager = NSTextLayoutManager()
        content.addTextLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        manager.delegate = self
        manager.ensureLayout(for: manager.documentRange)

        var items: [Item] = []
        if let name = file.notebookName {
            let metadata = ([name] + file.tags.map { "#" + $0 }).joined(separator: "   ")
            let text = NSAttributedString(string: metadata, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: style.nsTertiary])
            items.append(Item(height: 34, breaks: []) { _ in text.draw(at: .zero) })
        }
        var blocksByOffset: [Int: Block] = [:]
        var offset = 0
        for block in file.content.document.blocks {
            blocksByOffset[offset] = block
            offset += (block.kind.isObject ? 1 : (block.runs.map(\.text).joined() as NSString).length) + 1
        }
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let location = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            if let block = blocksByOffset[location], block.kind.isAttachment {
                for part in self.printParts(for: block) {
                    let renderer = ImageRenderer(content: SharedRichBlockView(block: part, style: self.style, images: self.file.content.assets)
                        .frame(width: self.width).fixedSize(horizontal: false, vertical: true))
                    renderer.proposedSize = ProposedViewSize(width: self.width, height: nil)
                    renderer.render { size, _ in
                        items.append(Item(height: size.height + 18, breaks: []) { context in
                            // ImageRenderer draws in an unflipped coordinate system.
                            context.saveGState()
                            context.translateBy(x: 0, y: size.height)
                            context.scaleBy(x: 1, y: -1)
                            renderer.render { _, draw in draw(context) }
                            context.restoreGState()
                        })
                    }
                }
            } else {
                let frame = fragment.layoutFragmentFrame
                let height = max(frame.height, fragment.renderingSurfaceBounds.maxY)
                let breaks = fragment.textLineFragments.map { $0.typographicBounds.maxY }.filter { $0 > 0 && $0 < height }
                items.append(Item(height: height, breaks: breaks) { context in
                    fragment.draw(at: CGPoint(x: frame.minX, y: 0), in: context)
                    self.addLinks(fragment, x: frame.minX, in: context)
                })
            }
            return true
        }
        guard !items.isEmpty else { throw SharedNoteFile.ShareError.rendering }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw SharedNoteFile.ShareError.rendering }
        var mediaBox = CGRect(x: 0, y: 0, width: width + margin * 2, height: (width + margin * 2) * sqrt(2))
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox,
                                      [kCGPDFContextTitle: file.content.document.title, kCGPDFContextCreator: "Notas"] as CFDictionary) else { throw SharedNoteFile.ShareError.rendering }
        let usualHeight = mediaBox.height
        var y = margin
        var pageHeight = usualHeight
        var pageOpen = false
        func beginPage(height: CGFloat) {
            if pageOpen { context.endPDFPage() }
            pageHeight = height
            var box = CGRect(x: 0, y: 0, width: mediaBox.width, height: height)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            context.setFillColor(style.nsBackground.cgColor)
            context.fill(box)
            y = margin
            pageOpen = true
        }
        beginPage(height: usualHeight)
        for item in items {
            // Keep each object block whole, with a taller page when its contents need it.
            if item.breaks.isEmpty {
                if y + item.height > pageHeight - margin, y > margin { beginPage(height: max(usualHeight, item.height + margin * 2)) }
                if item.height > pageHeight - margin * 2 { beginPage(height: item.height + margin * 2) }
                draw(item, from: 0, height: item.height, at: y, in: context, pageHeight: pageHeight)
                y += item.height
                continue
            }
            var start: CGFloat = 0
            while start < item.height {
                let available = pageHeight - margin - y
                let end = item.height - start <= available ? item.height
                    : item.breaks.last(where: { $0 > start && $0 - start <= available }) ?? start
                if end <= start { beginPage(height: usualHeight); continue }
                draw(item, from: start, height: end - start, at: y, in: context, pageHeight: pageHeight)
                y += end - start
                start = end
                if start < item.height { beginPage(height: usualHeight) }
            }
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func draw(_ item: Item, from start: CGFloat, height: CGFloat, at y: CGFloat, in context: CGContext, pageHeight: CGFloat) {
        context.saveGState()
        context.translateBy(x: margin, y: pageHeight - y)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(x: -20, y: 0, width: width + 40, height: height))
        context.translateBy(x: 0, y: -start)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        item.draw(context)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private func addLinks(_ fragment: NSTextLayoutFragment, x: CGFloat, in context: CGContext) {
        for line in fragment.textLineFragments {
            line.attributedString.enumerateAttribute(NSAttributedString.Key("notas.shareLink"), in: line.characterRange) { value, range, _ in
                guard let value, let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
                let a = line.locationForCharacter(at: range.location)
                let b = line.locationForCharacter(at: NSMaxRange(range))
                let rect = CGRect(x: x + line.typographicBounds.minX + min(a.x, b.x), y: line.typographicBounds.minY,
                                  width: abs(b.x - a.x), height: line.typographicBounds.height)
                    .intersection(context.boundingBoxOfClipPath)
                if !rect.isNull { context.setURL(url as CFURL, for: rect.applying(context.ctm)) }
            }
        }
    }

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let attributes = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
            switch BlockAttributes(attributes).kind {
            case .checklist, .bullet, .numbered, .quote, .callout, .code, .divider:
                return NotasLayoutFragment(textElement: textElement, range: textElement.elementRange, attributes: attributes)
            default: break
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    private func printParts(for block: Block) -> [Block] {
        guard let payload = block.payload else { return [block] }
        switch block.kind {
        case .table:
            guard let table = payload.table, table.columnCount > 6 || table.rows.count > 12 else { return [block] }
            var parts: [Block] = []
            for column in stride(from: 0, to: table.columnCount, by: 6) {
                for start in stride(from: 0, to: table.rows.count, by: 12) {
                    var rows = Array(table.rows[start..<min(start + 12, table.rows.count)])
                    if start > 0 && table.header, let header = table.rows.first { rows.insert(header, at: 0) }
                    rows = rows.map { Array($0.dropFirst(column).prefix(6)) }
                    parts.append(Block(kind: .table, runs: [], payload: BlockPayload(table: TableData(rows: rows, header: table.header))))
                }
            }
            return parts
        case .board:
            let columns = payload.board?.columns ?? []
            return stride(from: 0, to: columns.count, by: 3).map { start in
                Block(kind: .board, runs: [], payload: BlockPayload(board: BoardData(columns: Array(columns[start..<min(start + 3, columns.count)]))))
            }
        default: return [block]
        }
    }
}
