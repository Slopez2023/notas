#!/usr/bin/env python3
"""Compile extension artifacts; embed them only with an Apple signing identity."""
import argparse
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SDK = pathlib.Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk')
SWIFTC = '/Library/Developer/CommandLineTools/usr/bin/swiftc'


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def signing_identity():
    result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, check=True)
    entries = re.findall(r'([A-F0-9]{40}) "([^"]+)"', result.stdout)
    requested = os.environ.get('NOTAS_SIGNING_IDENTITY')
    if requested == '-':
        return None
    for fingerprint, name in entries:
        if (requested and requested in (fingerprint, name)) or (not requested and name.startswith(('Apple Development:', 'Developer ID Application:'))):
            team = os.environ.get('NOTAS_DEVELOPMENT_TEAM')
            if not team:
                certificate = run(['security', 'find-certificate', '-c', name, '-p'], capture_output=True).stdout
                subject = run(['openssl', 'x509', '-noout', '-subject', '-nameopt', 'sep_multiline'], input=certificate, capture_output=True).stdout.decode()
                match = re.search(r'\bOU\s*=\s*([A-Z0-9]{10})\b', subject)
                team = match.group(1) if match else None
            if not team or not re.fullmatch('[A-Z0-9]{10}', team):
                raise RuntimeError('Set NOTAS_DEVELOPMENT_TEAM to the ten-character Apple team ID.')
            return fingerprint, team
    if requested:
        raise RuntimeError('NOTAS_SIGNING_IDENTITY does not match a valid code-signing identity in this keychain.')
    return None


def expand(value, replacements):
    if isinstance(value, dict):
        return {k: expand(v, replacements) for k, v in value.items()}
    if isinstance(value, list):
        return [expand(v, replacements) for v in value]
    if isinstance(value, str):
        for key, replacement in replacements.items():
            value = value.replace('$(' + key + ')', replacement)
    return value


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value, sort_keys=False))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=pathlib.Path, default=ROOT / 'build/Notas.app')
    parser.add_argument('--require-signing', action='store_true')
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    args = parser.parse_args()
    identity = signing_identity()
    if args.require_signing and not identity:
        raise RuntimeError('No Apple signing identity is available. Finish Xcode → Settings → Accounts, then run this again.')
    team = identity[1] if identity else ''
    group = team + '.com.stephenlopez.notas.shared' if team else ''
    artifacts = ROOT / 'build/extension-artifacts'
    shared_sources = sorted((ROOT / 'Sources/NotasShared').glob('*.swift'))
    for module in ['NotasShare', 'NotasWidgets']:
        extension = artifacts / (module + '.appex')
        if extension.exists():
            shutil.rmtree(extension)
        executable = extension / 'Contents/MacOS' / module
        executable.parent.mkdir(parents=True)
        flags = ['-swift-version', '5', '-sdk', SDK, '-target', 'arm64-apple-macos26.0', '-application-extension', '-parse-as-library', '-module-name', module]
        flags += ['-O'] if args.configuration == 'release' else ['-Onone', '-g']
        flags += ['-Xlinker', '-e', '-Xlinker', '_NSExtensionMain']
        sources = shared_sources + sorted((ROOT / 'Extensions' / module).glob('*.swift'))
        run([SWIFTC, *flags, *sources, '-o', executable])
        template = plistlib.loads((ROOT / 'Extensions' / module / 'Info.plist').read_bytes())
        metadata = expand(template, {'DEVELOPMENT_TEAM': team, 'PRODUCT_MODULE_NAME': module})
        metadata['NotasAppGroupIdentifier'] = group
        metadata['CFBundleSupportedPlatforms'] = ['MacOSX']
        write_plist(extension / 'Contents/Info.plist', metadata)
        run(['plutil', '-lint', extension / 'Contents/Info.plist'])
        if identity:
            entitlements = expand(plistlib.loads((ROOT / 'Extensions' / module / (module + '.entitlements')).read_bytes()), {'DEVELOPMENT_TEAM': team})
            entitlement_path = artifacts / (module + '.entitlements')
            write_plist(entitlement_path, entitlements)
            run(['codesign', '--force', '--sign', identity[0], '--entitlements', entitlement_path, '--timestamp=none', extension])
            destination = args.app / 'Contents/PlugIns' / extension.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(extension, destination)
            run(['codesign', '--verify', '--strict', destination])
    app_info = args.app / 'Contents/Info.plist'
    metadata = plistlib.loads(app_info.read_bytes())
    metadata['NotasAppGroupIdentifier'] = group
    write_plist(app_info, metadata)
    if identity:
        entitlements = expand(plistlib.loads((ROOT / 'Resources/Notas.entitlements').read_bytes()), {'DEVELOPMENT_TEAM': team})
        entitlement_path = artifacts / 'Notas.entitlements'
        write_plist(entitlement_path, entitlements)
        run(['codesign', '--force', '--sign', identity[0], '--entitlements', entitlement_path, '--timestamp=none', args.app])
        print('Signed and embedded both extensions. App group: ' + group)
    else:
        # Never leave an old signed extension attached to an unsigned app rebuild.
        plugins = args.app / 'Contents/PlugIns'
        if plugins.exists():
            shutil.rmtree(plugins)
        run(['codesign', '--force', '--sign', '-', '--timestamp=none', args.app])
        print('Extension code compiled into build/extension-artifacts. Signing is required to install the share extension and widgets.')
    run(['codesign', '--verify', '--deep', '--strict', args.app])


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
