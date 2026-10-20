# Sending complete note copies

The top-right Share button opens the native macOS share popover. Each share sends two files with the same title:

- A PDF preserves the note's colors and visible formatting on devices without Notas.
- A `.notasnote` file preserves the editable document, photos, theme, fonts, tags, notebook, and sketch strokes.

The PDF is a reading copy. Interactive editing happens in Notas after the recipient opens the `.notasnote` file. Every import creates an independent note. Later edits do not sync between the two copies.

## Usage and ownership

`ShareBarButton` calls `AppState.shareActiveNote(from:)`. The File menu calls the same method using the toolbar button as its anchor.

`SharedNoteFile` takes the current document and resolved style as one snapshot. It stores no source note ID. Auto theme and inherited accent become explicit values, so the receiver's system appearance cannot change the copy's colors. Only referenced photos travel with the file. Missing photos stop sharing with an error.

`NoteSharing` writes both files into a separate staging folder and presents `NSSharingServicePicker`. Each session retains its picker and service delegates. Staged files survive completion callbacks because the receiving service may still need them. Subsequent shares remove inactive folders older than seven days.

`AppDelegate.application(_:open:)` handles `.notasnote` file URLs alongside the existing `notas://` links. `LibraryStore.importSharedNote` writes the note and renamed photos into a temporary package, then moves the complete package into the library before exposing it. Matching notebook names and colors reuse an existing notebook. Otherwise, the import creates the sender's notebook.

## Rendering complete content

`NotePDFRenderer` uses `RichTextCodec`, `EditorStyler`, and `NotasLayoutFragment` for the same text fonts, colors, list markers, checkboxes, highlights, quotes, and callouts as the editor. PDF text stays selectable and links have clickable annotations.

`SharedRichBlockView` draws static versions of the five interactive blocks. It has no scroll views or editing controls. Photos fit without cropping, table cells wrap, boards show every card, and text columns grow to fit their contents. Sketches share the editor's vector stroke renderer.

Wide tables split into groups of six columns. Long tables repeat their header across groups of twelve rows. Boards wrap after three columns. Normal text breaks between lines. Object blocks stay together on a taller page when necessary. These changes expose content that scrolling hides in the editor.

## Design selection

Two independent designs compared editor layout reuse with HTML and WebKit export. A third design provider stopped at its usage limit. An independent judge scored editor reuse 22 of 25 and HTML export 18 of 25. Editor reuse won because it keeps typography and decorations in their existing owners. The final design adopted the alternative's ID-free portable file and atomic import.

The PDF renderer measures static blocks separately instead of introducing a print mode into the live editor. This keeps export behavior out of editing state. HTML was rejected because it duplicated text style rules and required another pagination mechanism.

The native presentation follows Apple's [NSSharingServicePicker documentation](https://developer.apple.com/documentation/appkit/nssharingservicepicker).

## Verification

`scripts/test.sh` includes portable-file round trips, appearance independence, photo remapping, independent imports, disk reload, malformed-file rejection, full rich-block PDF text, and link annotation alignment. Set `NOTAS_SHARE_TEST_OUTPUT` to save the fixture PDF and portable note for visual review.

The fixture includes nine table columns, eighteen rows, six board columns with twenty-five cards each, long text columns, a photo, colored text, a highlight, a completed checklist item, and a sketch.

On 2026-10-20, all 147 self-test checks passed. The signed packaged app opened the portable fixture in an isolated library. The native popover offered AirDrop, Mail, Messages, Shortcuts, and Copy. Copy transferred both files, which remained readable after dismissal. A live edit inserted immediately before the mouse click appeared in both outgoing files. The normal app session was restored afterward. No message was sent to another person.
