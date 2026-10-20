# Enable sharing and widgets

The main app and quick capture work without an Apple signing identity. Sharing and widgets require the app and both extensions to be signed by the same Apple team.

## Prepare Xcode

1. Open Xcode and finish its first-launch setup. Review and accept its license yourself.
2. Open **Xcode → Settings → Accounts** and add your Apple Account.
3. Select your team and open **Manage Certificates**.
4. Create an **Apple Development** certificate if none exists. If that menu item is disabled for a Personal Team, open the Notas project, select the main target's **Signing & Capabilities** tab, and select your team. Xcode can create the development certificate automatically.

Do not put account credentials or signing keys in this repository.

## Build, install, and launch

Run these commands in the project directory:

```sh
scripts/build-app.sh
```

Quit Notas before replacing an installed copy, then run:

```sh
python3 scripts/install-app.py
open ~/Applications/Notas.app
```

The installer validates the signatures, keeps the previous app in `build/install-backups/`, and registers the installed copy with macOS. Use this copy for widgets and `notas://` links.

The builder selects an available Apple Development identity. If multiple identities exist, select one explicitly:

```sh
NOTAS_SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' scripts/build-app.sh
```

A successful extension build prints `Signed and embedded both extensions`. If the output says signing is required, the keychain still has no matching signing identity.

If macOS asks to let `codesign` use the new certificate's private key, review and approve the Keychain prompt directly on your Mac.

To use Xcode instead, regenerate the project with your ten-character team ID:

```sh
python3 scripts/generate-xcode-project.py --team YOURTEAMID
open Notas.xcodeproj
```

Select the **Notas** scheme and run it. If Xcode requests signing-key access, review the macOS prompt.

## Enable the share extension

1. Open a web page in Safari and open its **Share** menu.
2. Select **Edit Extensions** or **Manage Extensions** if Notas is absent.
3. Enable **Notas** under the macOS Sharing extensions.
4. Share the page to Notas, choose a notebook, and select **Save note**.
5. Open Notas and confirm that the new note contains the link.

Repeat the check with an image or PDF in Finder. Every PDF page should appear in the note's gallery. Sharing while Notas is closed keeps the capture in its inbox until the app opens.

## Add the widgets

1. Open a note in Notas.
2. Choose **Go → Show This Note in Widget**.
3. Control-click the desktop and choose **Edit Widgets**.
4. Find **Notas** and add **Favorite note** or **Quick note**.
5. Click Favorite note to open the selected note. Click Quick note to open the capture panel.

To change the displayed note, repeat the first two steps. macOS may delay a widget refresh.

## Diagnose missing or stale widgets

Run the read-only diagnostic from the project directory:

```sh
python3 scripts/diagnose-widgets.py
```

The installed extension should be the only registered copy, at `~/Applications/Notas.app/Contents/PlugIns/NotasWidgets.appex`. If other copies appear, quit Notas and rerun the installer.

To verify the displayed content, add both widgets to Notification Center and leave Notification Center open. Run:

```sh
python3 scripts/diagnose-widgets.py --verify-rendered
```

This check compares the displayed title and body or first checklist item with the app's published snapshot. It also checks for Quick note. If a refresh is pending, wait for macOS to update the widget and rerun the check. The UI check requires Accessibility access for the terminal running it.

## Check quick capture

1. Switch to another app and press **⌥Space**.
2. Write a title on the first line and details below it.
3. Press **Escape**, then press **⌥Space** again. The draft should remain.
4. Press **⌘Return** to save. Open Notas and confirm that one new note exists.

Use the Notas menu-bar icon to change the shortcut to **⌃⌥Space** or turn it off.
