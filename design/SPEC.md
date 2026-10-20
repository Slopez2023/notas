# Notas — product spec (draft v1)

A premium, dark-first notes app for the Mac, built for one person who wants every
note to *look* nicely done and still have real power under the hood.

Mockups: `concepts-v2.html` (the three directions), `concept-v3.html` (chosen direction).

## Decisions so far

| Topic | Decision |
|---|---|
| Layout | **Page**: the note fills the window. Notebook dots on the left rail, open notes as tabs across the top, everything else behind ⌘K, `/`, and hover. |
| Vibe | Bold and modern. **Dark-first**, with a polished light mode that follows the system setting. |
| Platform | **Mac only**, Apple Silicon, macOS 26+. Free, so no paid Apple Developer account. |
| Accent | She picks from a curated set of about 8. Default is violet `#8B7CFF`. |
| Typography | Serif titles (New York) + clean sans body (Inter, bundled). Mono for metadata. |
| Organization | Notebooks (one per note) + #tags across notebooks. Pinned, Recent, and Inbox built in. |
| Per-note themes | 8–10 curated presets (Midnight, Paper, Terminal, Blush, Sage, Ink, …), each adjustable per note: accent, title/body font, size, spacing, width. |
| Rich styling | Highlighter and text colors, callouts, quotes, dividers, two-column blocks. |
| Core blocks | Text, checklist, photo gallery, simple sketch (pen / highlighter / eraser with trackpad or mouse), document scan (Continuity Camera from her iPhone), table, board (any list → kanban). |
| AI | On-device only (Apple Foundation Models): tidy up, turn into checklist, summarize, make a table, find related. Free, private, works offline. |
| Capture | Global hotkey window (⌥Space), desktop/Notification Center widgets, share extension. |
| Sharing | Export a note as a styled image (story 9:16 / square) or PDF in its theme. No live sharing. |
| Sync/storage | Notes saved as files in her iCloud Drive folder, so they're backed up and visible on any of her Macs. No CloudKit (needs the paid account). |
| Updates | Sparkle auto-update from releases. She clicks "Open Anyway" once on first launch (not notarized). |
| Name | Notas |

## Not doing (for now)
iPhone/iPad app · live shared notebooks · cloud AI · reminders · note linking/backlinks · covers · templates · Face ID lock · Apple Notes import (decided: she starts fresh).

## Technical approach
- Built with **Swift Package Manager** + a bundling script (Command Line Tools compile the app and extension artifacts; Xcode supplies the signing setup for extension installation). Builds against the macOS 26 SDK.
- **SwiftUI** app shell + **AppKit `NSTextView` on TextKit 2** for the editor. Tables, galleries, boards, and sketches use text attachments with editor-owned views positioned from TextKit attachment frames (see `PHASE3.md`), so the whole note is one continuous text flow. Selection, undo, find, and copy/paste work across blocks the way a premium editor should. SwiftUI's new rich `TextEditor` is simpler but can't host tables or boards inline.
- **Storage:** one `.notas` package per note (semantic JSON document + attachment assets) in a flat `iCloud Drive/Notas/Notes/` folder; notebooks live in `notebooks.json`. Text is stored semantically (block kinds + inline marks), never as fonts, so themes can restyle any note. A local SQLite/FTS index for instant search and tags, rebuilt from the files. Files stay the source of truth.
- **Themes** as data (a JSON preset + per-note overrides), rendered identically in the editor, widgets, and export.
- **Extensions:** WidgetKit widget + share extension communicate through an App Group container.

## Risks to check early
1. **Personal Team signing:** the app and both extensions sign successfully, and live sharing through the team-prefixed App Group passed. Widget gallery rendering and clicks still need a live check.
2. **TextKit 2 attachments** with live, editable SwiftUI views (tables/boards) is the hardest engineering piece. Prototype first.
3. **Sparkle** + non-notarized builds: confirm updates install cleanly without Gatekeeper re-prompting.
4. Files in iCloud Drive edited on two Macs at once → need conflict handling (keep both, show a merge banner).

## Build phases
1. **Core** ✅ (2026-10-19): window shell, rail/tabs/⌘K, editor with text styling + checklists, notebooks/tags, file storage, search, dark/light, themes.
2. **Make it pretty** ✅ (2026-10-19): 10 theme presets + per-note customizing, floating format bar (Liquid Glass), "/" block menu, dividers, 7 highlighter + 7 text colors, links, checkbox ripple + haptic, theme crossfade, app icon (`scripts/make-icon.swift`).
3. **Power blocks** ✅ (2026-10-20; live iPhone capture still requires a device check): photo gallery, tables, boards, two-column blocks (moved from phase 2: needs view attachments like tables), sketch, Continuity Camera scan.
4. **Everywhere on the Mac:** implemented quick capture, menu-bar access, share extension, and widgets. Both extensions are signed and registered. Live sharing checks passed; the widget gallery check remains. See `PHASE4.md`.
5. **Smart + share:** on-device AI actions, styled image/PDF export, Sparkle updates.
