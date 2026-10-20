import AppKit
import SwiftUI

struct SketchCanvas: NSViewRepresentable {
    enum Tool: String { case pen, marker, eraser }
    let data: SketchData
    let tool: Tool
    let ink: UInt32?
    let style: ResolvedStyle
    let onChange: (SketchData) -> Void

    func makeNSView(context: Context) -> DrawingView { DrawingView() }
    func updateNSView(_ view: DrawingView, context: Context) {
        view.data = data
        view.tool = tool
        view.ink = ink
        view.textColor = style.nsText
        view.onChange = onChange
        view.needsDisplay = true
    }

    final class DrawingView: NSView {
        var data = SketchData(width: 640, height: 260, strokes: [])
        var tool: Tool = .pen
        var ink: UInt32?
        var textColor = NSColor.labelColor
        var onChange: ((SketchData) -> Void)?
        private var draft: SketchData?
        private var current: SketchStroke?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityLabel("Sketch canvas")
            setAccessibilityRole(.image)
        }
        required init?(coder: NSCoder) { nil }

        private func point(_ event: NSEvent) -> NSPoint {
            let p = convert(event.locationInWindow, from: nil)
            return NSPoint(x: min(max(p.x, 0), bounds.width) / max(1, bounds.width) * data.width,
                           y: min(max(p.y, 0), bounds.height) / max(1, bounds.height) * data.height)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            draft = data
            let p = point(event)
            if tool == .eraser { erase(at: p) }
            else { current = SketchStroke(tool: tool == .marker ? .marker : .pen, color: ink, size: tool == .marker ? 15 : 2.8, points: [p.x, p.y]) }
            needsDisplay = true
        }
        override func mouseDragged(with event: NSEvent) {
            let p = point(event)
            if tool == .eraser { erase(at: p) }
            else { current?.points += [p.x, p.y] }
            needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            if let stroke = current { draft?.strokes.append(stroke) }
            current = nil
            if let draft, draft != data { data = draft; onChange?(draft) }
            draft = nil
            needsDisplay = true
        }
        override func cancelOperation(_ sender: Any?) {
            draft = nil; current = nil; needsDisplay = true
            var parent = superview
            while let view = parent {
                if let editor = view as? NotasTextView { editor.refocus(); break }
                parent = view.superview
            }
        }

        private func erase(at point: NSPoint) {
            draft?.strokes.removeAll { stroke in
                let points = stroke.points
                guard points.count >= 2 else { return false }
                let tolerance = 12.0 + stroke.size / 2
                for i in stride(from: 0, to: points.count - 1, by: 2) {
                    if hypot(points[i] - point.x, points[i + 1] - point.y) <= tolerance { return true }
                    if i + 3 < points.count {
                        let ax = points[i], ay = points[i + 1], dx = points[i + 2] - ax, dy = points[i + 3] - ay
                        let t = max(0, min(1, ((point.x - ax) * dx + (point.y - ay) * dy) / max(0.001, dx * dx + dy * dy)))
                        if hypot(point.x - ax - t * dx, point.y - ay - t * dy) <= tolerance { return true }
                    }
                }
                return false
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.035).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            var drawing = draft ?? data
            if let current { drawing.strokes.append(current) }
            drawing.draw(in: context, size: bounds.size, ink: textColor)
        }
    }
}

extension SketchData {
    func draw(in context: CGContext, size: CGSize, ink: NSColor) {
        context.saveGState()
        context.scaleBy(x: size.width / max(1, width), y: size.height / max(1, height))
        for stroke in strokes where stroke.points.count >= 2 {
            let color = stroke.color.map { NSColor(hex: $0) } ?? ink
            context.setStrokeColor(color.withAlphaComponent(stroke.tool == .marker ? 0.32 : 1).cgColor)
            context.setFillColor(color.withAlphaComponent(stroke.tool == .marker ? 0.32 : 1).cgColor)
            context.setLineWidth(stroke.size)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if stroke.points.count == 2 {
                context.fillEllipse(in: CGRect(x: stroke.points[0] - stroke.size / 2, y: stroke.points[1] - stroke.size / 2, width: stroke.size, height: stroke.size))
            } else {
                context.beginPath()
                context.move(to: CGPoint(x: stroke.points[0], y: stroke.points[1]))
                for i in stride(from: 2, to: stroke.points.count - 1, by: 2) { context.addLine(to: CGPoint(x: stroke.points[i], y: stroke.points[i + 1])) }
                context.strokePath()
            }
        }
        context.restoreGState()
    }
}
