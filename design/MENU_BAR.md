# Menu-bar redesign

## Problem

The existing menu gives shortcut configuration the same weight as capturing or reopening work. It also has no note context, so it does little beyond launching windows. The redesign should make capture and resuming a recent note one click away while keeping native macOS menu behavior.

## Usage

The scene owns one menu view:

```swift
MenuBarExtra("Notas", systemImage: "square.and.pencil") {
    NotasMenu(delegate: delegate)
}
```

The main calls are direct:

```swift
delegate.quickCapture?.show()
delegate.app.open(note.id, newTab: true)
delegate.showMainWindow { openWindow(id: "main") }
```

The menu reads recent notes from `LibraryStore.search("", limit: 5)`, which orders by modification time instead of putting pinned notes first.

## Shape

`NotasMenu` is a native menu-style `MenuBarExtra` view. Its hierarchy is:

```text
Quick Note… / Continue Quick Note…    current global shortcut
───────────────────────────────────────────────────────────
Recent Notes
  First recently edited note
  Second recently edited note
  Up to five total
  Search Notes…
───────────────────────────────────────────────────────────
Open Notas
Quick Note Shortcut                                      ›
───────────────────────────────────────────────────────────
Quit Notas
```

The recent section shows `No notes yet` when empty. Recent items open in a new tab so the current workspace is not replaced. Search opens the existing command palette. Both actions open and activate the main window with the menu view's `OpenWindowAction`, so they do not depend on `MainView` having appeared before.

The shortcut submenu uses the existing `CaptureShortcut` and `QuickCaptureController.setShortcut`. A failed registration leaves quick capture available and adds a disabled warning inside the submenu. The top item only displays a key equivalent for a shortcut that registered successfully.

The menu does not add note previews, notebooks, pinned groups, an inline editor, or a separate new-note action. Those would turn the menu into a second library or duplicate quick capture and the command palette.

## Synthesis decision

Two independent candidates converged on a native menu with direct recent notes. Candidate A is the base because it uses one view and no new model, cache, or coordinator. The final design takes Candidate B's explicit `OpenWindowAction` handoff, duplicate-title disambiguation, and shortcut-error placement. A cross-judge preferred this combination for its smaller implementation and native keyboard behavior. One earlier candidate dropped out after a provider rate limit.

## Tradeoffs accepted

- We accept one-line recent titles instead of previews in exchange for native menu navigation and dismissal.
- We accept a five-note limit in exchange for keeping every recent note one pointer step away.
- We keep shortcut configuration in the menu because registration can fail and the capture panel already directs the user here.

## Alternatives considered

- A custom window-style popover could show previews and richer chrome, but it would duplicate the command palette and require custom focus, dismissal, and accessibility behavior.
- A Recent Notes submenu would be shorter, but reopening a note would take another navigation step.
- An inline capture editor would duplicate the existing draft, notebook, save, and error states.

## Open questions and risks

- Does SwiftUI render the dynamic key equivalent consistently for both supported global shortcuts on the minimum macOS version?
- Should future usage data justify changing the five-note limit?

## Next implementation step

Add `NotasMenu`, route main-window presentation through its `OpenWindowAction`, then build and exercise the real menu.
