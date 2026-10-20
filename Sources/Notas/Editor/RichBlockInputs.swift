import AppKit
import SwiftUI

/// Child controls send edits to the note's undo history instead of recording a second history.
struct BlockInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var style: ResolvedStyle
    var bold = false
    var focus = false
    var label: String
    var onTab: ((Bool) -> Void)?
    var onEscape: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.font = style.bodyFont.nsFont(size: 12, weight: bold ? .semibold : .regular)
        field.textColor = style.nsText
        field.setAccessibilityLabel(label)
        if focus && !context.coordinator.wasFocused {
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: (field.stringValue as NSString).length)
            }
        }
        context.coordinator.wasFocused = focus
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BlockInput
        var wasFocused = false
        init(_ parent: BlockInput) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) {
            ((notification.object as? NSTextField)?.currentEditor() as? NSTextView)?.allowsUndo = false
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            ((notification.object as? NSTextField)?.currentEditor() as? NSTextView)?.allowsUndo = true
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)), let onTab = parent.onTab { onTab(false); return true }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)), let onTab = parent.onTab { onTab(true); return true }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), let escape = parent.onEscape { escape(); return true }
            return false
        }
    }
}

struct BlockTextArea: NSViewRepresentable {
    @Binding var text: String
    let style: ResolvedStyle
    let label: String
    let escape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = ColumnTextView()
        view.onEscape = escape
        view.isRichText = false
        view.drawsBackground = false
        view.allowsUndo = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 2, height: 4)
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ColumnTextView else { return }
        if view.string != text { view.string = text }
        view.font = style.bodyFont.nsFont(size: style.textSize)
        view.textColor = style.nsSecondary
        view.insertionPointColor = style.nsAccent
        view.setAccessibilityLabel(label)
        view.onEscape = escape
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockTextArea
        init(_ parent: BlockTextArea) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
    }
}

private final class ColumnTextView: NSTextView {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

struct BoardDragHandle: NSViewRepresentable {
    let cardID: String
    let color: NSColor
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) { view.cardID = cardID; view.color = color; view.needsDisplay = true }

    final class Handle: NSView, NSDraggingSource {
        var cardID = ""
        var color = NSColor.secondaryLabelColor
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Drag card")
            toolTip = "Drag card to another column"
        }
        required init?(coder: NSCoder) { nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func draw(_ dirtyRect: NSRect) {
            color.setStroke()
            let path = NSBezierPath()
            for y in [bounds.midY - 3, bounds.midY, bounds.midY + 3] {
                path.move(to: NSPoint(x: 3, y: y)); path.line(to: NSPoint(x: bounds.width - 3, y: y))
            }
            path.lineWidth = 1
            path.stroke()
        }
        override func mouseDown(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: ("notas-card:" + cardID) as NSString)
            let image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Card") ?? NSImage(size: bounds.size)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .move] }
    }
}
