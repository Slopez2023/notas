# Capture and extensions

Quick capture, the share extension, and widgets use one note writer. The main app owns the library. Extensions never edit a note package.

## Capture ownership

`QuickCaptureModel` keeps one local draft with a stable UUID. Saving uses that UUID as the new note ID. The note reaches disk before the draft clears. An interrupted save can retry without duplicating the note. Drafts stay in local Application Support, rather than the iCloud library, except in isolated test sessions.

The share extension loads text, web links, images, and PDFs from `NSItemProvider`. It copies temporary files before the provider's callback returns. It then commits an immutable capture package by moving its staging directory into the shared inbox. Cancelling removes the staged files.

`CaptureIntegration` imports each package on launch, activation, a directory change, or a capture notification. Each capture ID becomes its note ID. The importer acknowledges a package after the note and its images reach disk. A malformed package stays recoverable and does not block other captures. Import failures appear when the main app becomes active.

## Widget ownership

The app publishes `widget-library.json` atomically. The snapshot contains notebook choices for sharing and the selected widget note. Widgets read this snapshot without accessing iCloud or the editor.

The Favorite note widget shows text or checklist completion in small, medium, and large sizes. Clicking the widget opens the note. Checklist rows are previews, not interactive buttons. The Quick note widget opens the capture panel.

**Go → Show This Note in Widget** selects the note. Until a note is selected, the snapshot uses the first pinned note, then the most recent note. Saving, editing, and theme changes refresh the snapshot and request a widget timeline reload. macOS controls the final reload timing.

## Keyboard and window behavior

`GlobalCaptureHotKey` registers a Carbon hot key, so the default ⌥Space shortcut does not require Accessibility permission. The menu-bar menu offers ⌃⌥Space or Off if another app uses the default shortcut. A local event handler handles the same shortcut when Notas receives an app-local keyboard event.

The capture window is a floating, nonactivating `NSPanel`. It can appear on the current Space and beside a full-screen app. Escape and the close button keep the draft. ⌘Return saves, and ⇧⌘Return saves and opens the note. ⌘W dismisses the panel without closing a note tab.

## Signing boundary

The app and both extensions use a macOS app group named `<TEAM_ID>.com.stephenlopez.notas.shared`. macOS authorizes this group by matching its prefix to the signing team. This naming scheme does not require registering an app group or obtaining an app-group provisioning profile. It is specific to macOS. See Apple's [app-group container documentation](https://developer.apple.com/documentation/xcode/accessing-app-group-containers).

`scripts/build-app.sh` builds the app and compiles both extensions. With an Apple Development or Developer ID Application identity, the builder signs and embeds the extensions, then signs the containing app. Without an identity, it leaves the extension binaries in `build/extension-artifacts` and signs only the main app with an ad hoc signature. It does not install nonfunctional extensions into the app.

The generated Xcode project contains the same sources in three native targets. `scripts/generate-xcode-project.py` regenerates it. SwiftPM remains available for main-app development and tests.

## Verification limits

The self-test covers capture persistence, retry behavior, draft recovery, malformed input, image transfer, chosen notebooks, shared links, widget snapshots, checklist states, deep links, and Carbon hot-key delivery.

The packaged app also passed a live check in an isolated library: ⌥Space restored a draft after relaunch, Save & open displayed the resulting note, and ⌘Return saved a second note. Both notes appeared exactly once on disk, and each successful save cleared the draft. The normal library was restored afterward.

On 2026-10-20, Xcode setup completed and a Personal Team Apple Development identity signed the app and both extensions. Both the bundling script and the three-target Xcode build succeeded. macOS registered both extensions, and the app published its chosen widget note into the shared group container.

Live sharing checks passed in an isolated library: a Safari URL imported as a clickable link; one PNG and a two-page PDF imported as a gallery with three saved images; a capture made while Notas was closed imported on launch with its title, body, link, and selected notebook intact. These checks exposed Safari's data-backed URL representation. `CaptureItemDecoder` now handles URL objects, strings, and data, with regression checks in the 133-check self-test.

Live widget verification completed on 2026-10-20. The command-line extension build needed Apple's `_NSExtensionMain` entry point. The corrected package exposes Favorite note in small, medium, and large sizes, plus Quick note, in the macOS widget gallery. The installer places the signed app in `~/Applications` and unregisters competing development copies.

Both widgets were added to Notification Center. Favorite note displayed the guide's checklist and opened that note when clicked. Quick note opened the capture panel. In an isolated library, choosing a new note updated the displayed title and body. Editing both fields refreshed the widget, and checking a checklist item displayed its checkmark and strikethrough. The normal library was restored afterward.

`python3 scripts/diagnose-widgets.py --verify-rendered` compares the live Notification Center title and content against the published snapshot and checks for Quick note. The UI check requires Accessibility access. The 133-check self-test also passes. The setup procedure is in [Enable sharing and widgets](../docs/enable-extensions.md).
