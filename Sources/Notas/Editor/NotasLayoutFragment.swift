import AppKit

/// Draws the parts of a paragraph that aren't text: checkboxes, bullets, numbers,
/// the quote bar, and the rounded boxes behind callouts and code.
final class NotasLayoutFragment: NSTextLayoutFragment {
    let kind: BlockKind
    let checked: Bool
    let ordinal: Int
    let indent: Int
    let decor: DecorColors
    let font: NSFont
    let paragraphStyle: NSParagraphStyle

    static let checkboxSize: CGFloat = 15

    init(textElement: NSTextElement, range: NSTextRange?, attributes: [NSAttributedString.Key: Any]) {
        let block = BlockAttributes(attributes)
        kind = block.kind
        checked = block.checked
        indent = block.indent
        ordinal = attributes[.notasOrdinal] as? Int ?? 1
        decor = attributes[.notasDecor] as? DecorColors
            ?? DecorColors(accent: .controlAccentColor, muted: .tertiaryLabelColor, panel: .quaternaryLabelColor, text: .labelColor)
        font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 15)
        paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle ?? .default
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Geometry (fragment coordinates)

    private var firstLine: NSTextLineFragment? { textLineFragments.first }

    /// Lines that hold text. TextKit 2 appends the empty line after a trailing newline
    /// to the last paragraph's fragment; it isn't part of this block.
    private var contentLines: [NSTextLineFragment] {
        let lines = textLineFragments
        guard lines.count > 1, let last = lines.last, last.characterRange.length == 0 else { return lines }
        return Array(lines.dropLast())
    }

    private var linesRect: CGRect {
        contentLines.reduce(CGRect.null) { $0.union($1.typographicBounds) }
    }

    /// Baseline of the first line, in fragment coordinates.
    private var firstBaseline: CGFloat {
        guard let line = firstLine else { return font.ascender }
        return line.typographicBounds.minY + line.glyphOrigin.y
    }

    /// Left edge where the paragraph's text starts. TextKit 2 places the fragment's
    /// origin at the indented text, so this is ~0 and the page margin is negative.
    private var textStartX: CGFloat { firstLine?.typographicBounds.minX ?? 0 }

    /// The text container's left edge, in fragment coordinates.
    private var marginX: CGFloat { textStartX - paragraphStyle.firstLineHeadIndent }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// Where the checkbox sits; also used for click hit-testing.
    var markerRect: CGRect {
        let size = Self.checkboxSize
        let centerY = firstBaseline - font.capHeight / 2
        return CGRect(x: textStartX - size - 10, y: centerY - size / 2, width: size, height: size)
    }

    private var boxRect: CGRect {
        let lines = linesRect.isNull ? CGRect(x: 0, y: 0, width: layoutFragmentFrame.width, height: font.boundingRectForFont.height) : linesRect
        let padY: CGFloat = 10
        return CGRect(x: marginX, y: lines.minY - padY,
                      width: containerWidth,
                      height: lines.height + padY * 2)
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        switch kind {
        case .checklist, .bullet, .numbered: bounds = bounds.union(markerRect.insetBy(dx: -4, dy: -4)).union(CGRect(x: textStartX - 48, y: markerRect.minY, width: 48, height: markerRect.height))
        case .callout, .code: bounds = bounds.union(boxRect.insetBy(dx: -2, dy: -2))
        case .quote: bounds = bounds.union(CGRect(x: marginX, y: linesRect.minY, width: 6, height: linesRect.height))
        case .divider: bounds = bounds.union(dividerRect.insetBy(dx: -1, dy: -2))
        default: break
        }
        return bounds
    }

    private var dividerRect: CGRect {
        let lines = linesRect.isNull ? CGRect(x: 0, y: 0, width: 1, height: font.boundingRectForFont.height) : linesRect
        return CGRect(x: marginX, y: lines.midY.rounded() - 0.5, width: containerWidth, height: 1)
    }

    // MARK: Drawing

    override func draw(at point: CGPoint, in context: CGContext) {
        // Backgrounds go under the text.
        switch kind {
        case .callout: drawBox(at: point, in: context, fill: decor.accent.withAlphaComponent(0.12), bar: decor.accent)
        case .code: drawBox(at: point, in: context, fill: decor.panel, bar: nil)
        case .quote: drawQuoteBar(at: point, in: context)
        case .divider:
            context.saveGState()
            context.setFillColor(decor.muted.withAlphaComponent(0.45).cgColor)
            context.fill(dividerRect.offsetBy(dx: point.x, dy: point.y))
            context.restoreGState()
            return
        default: break
        }

        super.draw(at: point, in: context)

        switch kind {
        case .checklist: drawCheckbox(at: point, in: context)
        case .bullet: drawBullet(at: point, in: context)
        case .numbered: drawNumber(at: point)
        default: break
        }
    }

    private func drawBox(at point: CGPoint, in context: CGContext, fill: NSColor, bar: NSColor?) {
        let rect = boxRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil)
        context.addPath(path)
        context.setFillColor(fill.cgColor)
        context.fillPath()
        if let bar {
            context.addPath(path)
            context.clip()
            context.setFillColor(bar.cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height))
        }
        context.restoreGState()
    }

    private func drawQuoteBar(at point: CGPoint, in context: CGContext) {
        guard !linesRect.isNull else { return }
        let r = CGRect(x: point.x + marginX + 2, y: point.y + linesRect.minY + 3, width: 3, height: linesRect.height - 6)
        context.saveGState()
        context.addPath(CGPath(roundedRect: r, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        context.setFillColor(decor.accent.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private func drawCheckbox(at point: CGPoint, in context: CGContext) {
        let r = markerRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        let path = CGPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
        if checked {
            context.addPath(path)
            context.setFillColor(decor.accent.cgColor)
            context.fillPath()
            // Checkmark
            let check = CGMutablePath()
            check.move(to: CGPoint(x: r.minX + r.width * 0.27, y: r.minY + r.height * 0.52))
            check.addLine(to: CGPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.68))
            check.addLine(to: CGPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.34))
            context.addPath(check)
            context.setStrokeColor(contrastingInk(on: decor.accent).cgColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        } else {
            context.addPath(path)
            context.setStrokeColor(decor.muted.cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawBullet(at point: CGPoint, in context: CGContext) {
        let d: CGFloat = indent % 2 == 0 ? 6 : 5.5
        let cx = point.x + textStartX - 15
        let cy = point.y + firstBaseline - font.xHeight / 2
        let r = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        context.saveGState()
        if indent % 2 == 0 {
            context.setFillColor(decor.accent.cgColor)
            context.fillEllipse(in: r)
        } else {
            context.setStrokeColor(decor.accent.cgColor)
            context.setLineWidth(1.3)
            context.strokeEllipse(in: r.insetBy(dx: 0.65, dy: 0.65))
        }
        context.restoreGState()
    }

    private func drawNumber(at point: CGPoint) {
        let label = indent % 2 == 0 ? "\(ordinal)." : "\(Self.letter(ordinal))."
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.9, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: decor.accent]
        let size = (label as NSString).size(withAttributes: attrs)
        let x = point.x + textStartX - 8 - size.width
        let y = point.y + firstBaseline - numberFont.ascender
        // NSString drawing needs a flipped NSGraphicsContext matching the CG context.
        (label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    private static func letter(_ n: Int) -> String {
        let scalars = Array("abcdefghijklmnopqrstuvwxyz")
        return String(scalars[(max(n, 1) - 1) % scalars.count])
    }

    private func contrastingInk(on color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.62 ? NSColor(white: 0.08, alpha: 1) : .white
    }
}
