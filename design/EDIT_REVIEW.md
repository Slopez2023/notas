# Reviewing assistant edits

The first release makes exact changes easier to see. It keeps the chat beside the note and accepts a proposal in one undoable action.

## Research and direction

These are established product patterns, rather than evidence that one layout is best for Notas:

- [Google Docs with Gemini](https://support.google.com/docs/answer/13447609?hl=en) shows suggestions in the document and supports individual acceptance, Accept all, and Reject all.
- [Notion suggested edits](https://www.notion.com/help/suggested-edits) ties accept and reject actions to contextual suggestions. This is a collaboration feature, not evidence about Notion AI's exact workflow.
- [Grammarly's suggestion architecture](https://www.grammarly.com/blog/engineering/how-suggestions-work-grammarly-editor/) describes why remaining suggestions must be adjusted after another edit is accepted.
- [Microsoft's validated human-AI interaction guidelines](https://www.microsoft.com/en-us/research/publication/guidelines-for-human-ai-interaction/) support efficient dismissal and correction. They support explicit controls, but do not prove this particular design.

We compared three concrete sketches in [the interactive prototype](prototypes/edit-review.html): contextual sidebar cards, inline editor review, and whole-draft comparison. The user identified the main problem as difficulty seeing exactly what changed. That makes preview clarity the first priority.

## The Notas interaction

**Changes** is the default. Each edit has a contextual location and separate Before and After lines. Removed words are struck through; added words are underlined. Colors reinforce those marks. Unchanged words retain ordinary styling, so both sentences remain readable. **Proposed** and **Original** show clean text without comparison marks.

The first native render used one inline diff. It fragmented larger rewrites into alternating fragments, so the implementation switched to stacked lines. The existing batch acceptance remains explicit: **Accept change** or **Accept N changes**, followed by **Keep original**. Acceptance creates one editor Undo action. Acknowledgments describe the historical decision, not whether the note still contains the accepted text after Undo.

New proposals persist section-based locations while the request snapshot is available. Older proposals use excerpts from their saved original text. Unchanged replacements are filtered only after the complete model response passes validation. The assistant is instructed to make focused corrections, preserve the writer's voice, and leave the exact rewritten text to the preview.

## Implementation shape

The sidebar calls `NoteProposalCard` with the proposal, style, and two lifecycle actions. `NoteEditPreview` supplies bounded, lossless text differences and snapshot-derived locations. `NoteAssistant.finish` validates the model response, removes no-ops, and captures optional locations and formatting-impact flags. `NoteAssistant.apply` remains the only acceptance path and retains the full-document and disk revision checks.

Diff segments are display data. They never reconstruct the operations applied to the note. The diff preserves extended grapheme clusters, whitespace, and punctuation. It caps detailed comparison at 1,000 tokens per side and 160,000 token pairs. Longer inputs use a common-prefix-and-suffix comparison. Both render paths reproduce the exact original and proposed strings.

Optional locations and formatting-impact fields preserve the version 1 history format. A larger normalized review-item schema was considered, but its migration and extra types were unnecessary for a preview-only change.

## Synthesis and tradeoffs

The sidebar-card design is the base because it improves inspection without adding temporary editor content or new acceptance state. The clean proposed-text view comes from whole-draft comparison. Inline editor annotations remain a future possibility, particularly for navigation to a suggestion's destination.

The independent design candidate favored the same direction and contributed the formatting notice, no-op policy, bounded diff, and persisted locations. Its normalized batch schema was rejected for this scope. The cross-judge preferred the focused implementation on scope, compatibility, and maintenance. Its labeling finding was fixed by naming each block kind and counting matching kinds within the section; formatting notices were narrowed to affected rows. Claude's initial grounding task failed because of a rate limit. The Grok candidate produced no artifact during the bounded exploration and was cancelled.

Individual acceptance is deferred. Blocks currently have no stable IDs, and insertions or deletions change later indices. Adding buttons without addressing that would make remaining suggestions unsafe or stale. The first release deliberately keeps whole-batch acceptance.

Text-changing replacements still use plain text inside the rewritten paragraph. Affected replacement rows state this before acceptance. Older proposals without formatting metadata retain a general notice. Preserving rich inline formatting through replacements is a separate editor change.

## Verification

Run `scripts/test-assistant.sh` for preview reconstruction, literal changed-word emphasis, contextual locations, old-proposal decoding, no-op filtering, protected-block validation, stale-proposal rejection, persistence, and editor Undo and Redo.

Run `NOTAS_REVIEW_PREVIEWS=/tmp/notas-review-previews scripts/test-assistant.sh` to also render the actual native review card in Paper and Midnight. Inspect both PNGs in that directory. These are native views rendered with synthetic content, not screenshots of a real conversation or a usability study.
