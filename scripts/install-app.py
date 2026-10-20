#!/usr/bin/env python3
"""Install the verified build in the user's Applications folder, keeping a backup."""
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'build/Notas.app'
DESTINATION = pathlib.Path.home() / 'Applications/Notas.app'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def unregister(app):
    result = subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True, text=True)
    if result.returncode and '-10814' not in result.stdout + result.stderr:
        result.check_returncode()


def main():
    run('codesign', '--verify', '--deep', '--strict', SOURCE)
    if DESTINATION.exists():
        info = plistlib.loads((DESTINATION / 'Contents/Info.plist').read_bytes())
        if DESTINATION.is_symlink() or info.get('CFBundleIdentifier') != 'com.stephenlopez.notas':
            raise RuntimeError('The destination is not a regular Notas app bundle.')
        pattern = '^' + re.escape(str(DESTINATION / 'Contents/MacOS/Notas')) + r'( |$)'
        running = subprocess.run(['pgrep', '-f', pattern], capture_output=True)
        if running.returncode == 0:
            raise RuntimeError('Quit the installed Notas app before replacing it.')
        if running.returncode != 1:
            raise RuntimeError('Could not check whether Notas is running.')

    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.notas-install-', dir=DESTINATION.parent) as temporary:
        staged = pathlib.Path(temporary) / 'Notas.app'
        run('ditto', SOURCE, staged)
        run('codesign', '--verify', '--deep', '--strict', staged)
        if DESTINATION.exists():
            backup = ROOT / 'build/install-backups' / str(uuid.uuid4()) / 'Notas.app'
            backup.parent.mkdir(parents=True)
            unregister(DESTINATION)
            shutil.move(DESTINATION, backup)
            print('Previous app saved at', backup)
        staged.rename(DESTINATION)

    # Keep development copies from competing with the installed app for links and widgets.
    registration = subprocess.run(
        ['pluginkit', '-m', '-A', '-D', '-vv', '-i', 'com.stephenlopez.notas.NotasWidgets'],
        check=True, capture_output=True, text=True,
    ).stdout
    copies = {pathlib.Path(path) for path in re.findall(r'^\s*Parent Bundle = (.+)$', registration, re.MULTILINE)}
    copies.update([SOURCE, ROOT / 'build/XcodeDerivedData/Build/Products/Debug/Notas.app'])
    for app in copies - {DESTINATION}:
        if app.exists():
            unregister(app)
    run(LSREGISTER, '-f', DESTINATION)
    print('Installed', DESTINATION)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
