# Power blocks

The note remains one TextKit 2 document. Each gallery, table, board, two-column section, or sketch occupies one object character in its own paragraph.

## Usage

```swift
editor.insertRichBlock(.table)
editor.importPhotos()
editor.convertListToBoard()
editor.showScanMenu()
attachment.update(newPayload, coalesce: "cell-0-1")
```

The slash menu, Insert menu, and command palette call these operations. Child controls submit payload values through the editor; they do not save notes themselves.

## Ownership and flow

`RichTextCodec` creates a new `RichBlockAttachment` for every object block and extracts its current value when saving. `RichBlockState` holds the payload and resolved theme. `RichBlockAttachment.height(for:)` determines the space TextKit reserves. `NotasTextView` retains one hosting view per attachment identity and positions it using `NSTextLayoutFragment.frameForTextAttachment`. Deleting an attachment removes its host; undo mounts it again. The view is stable across cell edits, so first responder stays in the field.

`updateRichBlock` registers the previous payload value on the editor's undo manager, then changes the observable payload. The inverse captures the current value when undo runs, so redo restores the complete edit. Repeated keystrokes in the same field within 600 ms share the original snapshot. Structural changes and sketch gestures have separate actions. Native child text controls disable their own undo recording. Character changes use the existing `shouldChangeText` / storage replacement / `didChangeText` path.

`NoteAssets` imports images and every PDF page into the note package. Clipboard data contains the semantic document and photo bytes. Paste imports all referenced assets before changing the destination document. A missing asset reports an error. Removing a photo retains the file because undo can restore it. Trash moves the whole package. Object presence counts as content even when the note has no searchable words.

## Design comparison and synthesis

The architect pass compared native attachment providers with manually positioned views. The Sol candidate supplied the ownership and value-undo design. The Grok candidate highlighted geometry, focus, clipboard transfer, and undo sequencing. Claude was unavailable because of its API rate limit. The cross-judge preferred Sol with asset-transfer and hosting adaptations.

Two live provider attempts on macOS 26.6 reserved attachment space but did not display the editable views. The final implementation therefore uses standard attachments for layout and editor-owned hosting views for controls. This retains one height calculation and TextKit's actual attachment frames rather than maintaining a separate layout engine.

The proposed payload-attribute cache was rejected. It would add another content representation to synchronize. The implemented value-snapshot history passes edit, undo, redo, delete, undo-delete, undo-edit, redo-edit, redo-delete, and coalesced typing checks against a real window and undo manager. Photo preview uses a SwiftUI sheet, verified in the app.

## Tradeoffs

- Boards and text columns have fixed heights with internal scrolling.
- Table cells, cards, and the two columns contain plain text.
- Unused asset files remain in a note package to preserve undo.
- Search includes table, card, and column text. It does not perform OCR on images or drawings.
- Continuity Camera discovery requires a compatible nearby device. Image and multi-page PDF delivery are covered by the self-test; an actual iPhone capture still needs a device check.

## Verification

Run `scripts/test.sh` for codec, editor, undo, geometry, asset copying, scan delivery, and storage checks. Native UI checks use a temporary `NOTAS_LIBRARY` and a separate `NOTAS_DEFAULTS_SUITE` so their tabs and preferences stay separate from the normal library.
