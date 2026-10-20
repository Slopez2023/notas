#!/usr/bin/env python3
"""Inspect Notas widget registration and discovery without changing system state."""
import argparse
import json
import pathlib
import plistlib
import re
import subprocess
from collections import Counter


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--verify-rendered', action='store_true',
                    help='Require both widgets in Notification Center and compare the displayed note with the published snapshot.')
args = parser.parse_args()

identifier = 'com.stephenlopez.notas.NotasWidgets'
registration = subprocess.run(
    ['pluginkit', '-m', '-A', '-D', '-vv', '-i', identifier],
    check=True, capture_output=True, text=True,
).stdout
paths = re.findall(r'^\s*Path = (.+)$', registration, re.MULTILINE)
print(f'Registered copies: {len(paths)}')
for path in paths:
    print(path)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', path], check=True)

if args.verify_rendered:
    if len(paths) != 1:
        raise SystemExit('Expected one registered widget extension. Install Notas with scripts/install-app.py first.')
    app = pathlib.Path(paths[0]).parents[2]
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    group = info['NotasAppGroupIdentifier']
    snapshot = pathlib.Path.home() / 'Library/Group Containers' / group / 'widget-library.json'
    note = json.loads(snapshot.read_text()).get('note')
    if not note:
        raise SystemExit('Select a note in Notas before checking its rendered widget.')
    script = '''
tell application "System Events" to tell process "NotificationCenter"
    set scroller to scroll area 1 of group 1 of group 1 of window "Notification Center"
    set widgets to first UI element of scroller whose role is "AXOpaqueProviderGroup"
    set widgetValues to {}
    repeat with widget in every group of widgets
        set widgetValues to widgetValues & (value of every static text of widget)
    end repeat
end tell
set AppleScript's text item delimiters to linefeed
return widgetValues as text
'''
    rendered = subprocess.run(['osascript', '-e', script], capture_output=True, text=True)
    if rendered.returncode:
        raise SystemExit('Open Notification Center with both Notas widgets added, then rerun this check.\n' + rendered.stderr.strip())
    lines = rendered.stdout.splitlines()
    expected = ['NOTAS', note['title'], 'Quick note', "What's on your mind?"]
    content = note['checklist'][0]['text'] if note['checklist'] else note['text'] or 'Open in Notas'
    expected.extend(content.splitlines())
    missing = [value for value in expected if value not in lines]
    if missing:
        raise SystemExit('Widget content is missing or awaiting a refresh: ' + ', '.join(missing))
    print('Rendered widgets verified. Favorite note matches the published title:', note['title'])

logs = subprocess.run(
    ['/usr/bin/log', 'show', '--last', '1h', '--style', 'compact', '--predicate',
     f'subsystem == "com.apple.chrono" AND eventMessage CONTAINS "{identifier}"'],
    check=True, capture_output=True, text=True,
).stdout
purges = Counter(re.findall(r"shouldn't cache it: .*?identifier: ([^,]+),", logs))
print('Descriptor purge counts:', dict(purges))
print('Recent discovery events:')
for line in logs.splitlines()[-12:]:
    print(line)
