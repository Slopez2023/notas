import AppKit
import SwiftUI

final class RichBlockState: ObservableObject {
    let kind: BlockKind
    @Published var payload: BlockPayload
    @Published var style = ResolvedStyle(style: NoteStyle(), systemIsDark: true, appAccent: .violet)

    init(block: Block) {
        kind = block.kind
        payload = block.payload ?? .empty(for: block.kind)
    }
}

/// The attachment identity stays stable while its editable content changes.
/// The editor records payload values in undo, never copies of this reference.
final class RichBlockAttachment: NSTextAttachment {
    let state: RichBlockState
    weak var editor: NotasTextView?
    var assets: NoteAssets? { editor?.noteAssets }
    var block: Block { Block(kind: state.kind, runs: [], payload: state.payload) }

    init(block: Block) {
        state = RichBlockState(block: block)
        super.init(data: nil, ofType: nil)
        attachmentCell = NSTextAttachmentCell()
        allowsTextAttachmentView = false
    }

    required init?(coder: NSCoder) { return nil }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = max(180, min(textContainer?.size.width ?? 600, proposedLineFragment.width))
        return CGRect(x: 0, y: 0, width: width, height: height(for: width))
    }

    func height(for width: CGFloat) -> CGFloat {
        switch state.kind {
        case .gallery:
            let count = state.payload.images?.count ?? 0
            let columns = max(1, min(4, state.payload.galleryColumns ?? min(3, max(1, count))))
            return count == 0 ? 170 : 52 + CGFloat((count + columns - 1) / columns) * (min(220, (width - 28 - CGFloat(columns - 1) * 8) / CGFloat(columns) * 0.72) + 8)
        case .table: return 68 + CGFloat(state.payload.table?.rows.count ?? 3) * 38
        case .board: return 358
        case .columns: return 292
        case .sketch: return 326
        default: return 100
        }
    }

    func update(_ payload: BlockPayload, coalesce key: String? = nil) { editor?.updateRichBlock(self, payload: payload, coalesce: key) }
}
