#!/usr/bin/env python3
"""Verify that the checked-in Xcode app target includes current Swift sources."""
import json
import pathlib
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    project = json.loads(subprocess.check_output([
        'plutil', '-convert', 'json', '-o', '-',
        str(ROOT / 'Notas.xcodeproj/project.pbxproj'),
    ]))['objects']
    app = next(value for value in project.values()
               if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'Notas')
    actual = set()
    for phase_id in app['buildPhases']:
        phase = project[phase_id]
        if phase['isa'] == 'PBXSourcesBuildPhase':
            for build_id in phase['files']:
                actual.add(project[project[build_id]['fileRef']]['path'])
    expected = {str(path.relative_to(ROOT))
                for source in ('Sources/Notas', 'Sources/NotasShared')
                for path in (ROOT / source).rglob('*.swift')}
    missing, stale = expected - actual, actual - expected
    if missing or stale:
        for path in sorted(missing):
            print(f'MISSING {path}')
        for path in sorted(stale):
            print(f'STALE {path}')
        raise SystemExit(1)
    print(f'PASS Xcode app target includes all {len(expected)} Swift sources')


if __name__ == '__main__':
    main()
