import AppKit

extension NotasTextView {
    func applyAssistantDocument(_ document: NoteDocument) {
        let replacement = RichTextCodec.attributedString(from: document)
        undoManager?.beginUndoGrouping()
        replaceAssistantText(replacement, selection: NSRange(location: min(selectedRange().location, replacement.length), length: 0))
        undoManager?.setActionName("Edit with Chat")
        undoManager?.endUndoGrouping()
    }

    private func replaceAssistantText(_ text: NSAttributedString, selection: NSRange) {
        guard let storage = textStorage else { return }
        let previous = NSAttributedString(attributedString: storage)
        let previousSelection = selectedRange()
        undoManager?.registerUndo(withTarget: self) { target in
            target.replaceAssistantText(previous, selection: previousSelection)
        }
        storage.setAttributedString(text)
        restyleAll()
        setSelectedRange(selection)
        didChangeText()
        onUserEdit?()
    }
}
