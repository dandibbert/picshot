#!/usr/bin/env python3
"""Verify final production text-helper signing, source identity and relocation.

macOS packaging evidence only: this does not execute scripts or qualify app UI.
Run on the final signed app, or an extracted ZIP/mounted DMG app, with the exact
source checkout. Reports must be written outside the signed application.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile


HELPER = 'PicShotTextScriptHelper'
IDENTIFIER = 'com.picshot.TextScriptHelper'
HELPER_PATH = 'Contents/Helpers/' + HELPER
APP_IDENTIFIER = 'local.picshot.app'
ENTITLEMENT = 'com.apple.security.app-sandbox'
MODULES = ('PicShotTextScriptCore', 'PicShotTextScriptProcess', HELPER)
FORBIDDEN = {'PicShotTextScriptGate', 'PicShotTextScriptTransportFixture'}
PACKAGE_SOURCES = (
    'Package.swift', 'scripts/package.sh', 'scripts/verify-text-script-package.py',
    'scripts/read-signed-helper-plist.swift', 'scripts/text-script-helper-Info.plist',
    'scripts/text-script-helper.entitlements')
INTEGRATION_SOURCES = (
    'Sources/PicShot/AppMain.swift',
    'Sources/PicShot/SmokeVerification.swift',
    'Sources/PicShot/CaptureChainRunner.swift',
    'Sources/PicShot/CaptureChainTextRuntime.swift',
    'Sources/PicShot/CaptureChainController.swift',
    'Sources/PicShot/TextScriptController.swift',
    'Sources/PicShot/TextScriptStore.swift',
    'Sources/PicShot/TextScriptUIPreviewFixture.swift',
    'Sources/PicShotCore/TextScriptDefinition.swift',
    'scripts/check-text-script-demo.py')


def run(command, *, cwd=None, timeout=60):
    result = subprocess.run(command, cwd=cwd, timeout=timeout, check=False,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError('Command failed: ' + ' '.join(map(str, command)) + '\n' +
                           result.stderr.decode('utf-8', errors='replace')[:8192])
    return result


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_sandbox(value):
    # bool is a subclass of int: ordinary dictionary equality accepts 1 as True.
    if (not isinstance(value, dict) or set(value) != {ENTITLEMENT} or
            value[ENTITLEMENT] is not True):
        raise RuntimeError('Expected only Boolean app-sandbox=true')
    return value


def require_helper_plist(value):
    if (not isinstance(value, dict) or value.get('CFBundleIdentifier') != IDENTIFIER or
            value.get('CFBundleExecutable') != HELPER):
        raise RuntimeError('Unexpected checked-in helper Info.plist identity')
    return value


def require_exact_plist(actual, expected):
    # Preserve scalar types as well as keys and values (True must not equal 1).
    if json.dumps(actual, sort_keys=True) != json.dumps(expected, sort_keys=True):
        raise RuntimeError('Signed embedded Info.plist differs from checked-in dictionary')


def signing_fields(value, expected_identifier):
    fields = {}
    for name in ('Identifier', 'CDHash', 'TeamIdentifier', 'Signature'):
        matches = re.findall(r'^' + name + r'=(.*)$', value, re.MULTILINE)
        if len(matches) > 1:
            raise RuntimeError('Ambiguous signing field: ' + name)
        fields[name] = matches[0] if matches else None
    if (fields['Identifier'] != expected_identifier or
            not re.fullmatch(r'[0-9a-f]{40,64}', fields['CDHash'] or '') or
            not fields['TeamIdentifier']):
        raise RuntimeError('Missing or unexpected signing identity')
    if fields['TeamIdentifier'] == 'not set':
        if fields['Signature'] != 'adhoc':
            raise RuntimeError('Absent Team ID is allowed only for ad-hoc signatures')
        fields['TeamIdentifier'] = None
    return fields


def require_same_team(app, helper):
    if app['TeamIdentifier'] != helper['TeamIdentifier']:
        raise RuntimeError('Application and helper Team IDs differ')


def signature(path, identifier):
    run(['codesign', '--verify', '--deep', '--strict', str(path)])
    result = run(['codesign', '-d', '--verbose=4', str(path)])
    return signing_fields((result.stdout + result.stderr).decode('utf-8'), identifier)


def check_regular_helper(app):
    helper = app / HELPER_PATH
    if app.resolve(strict=True) != app or helper.resolve(strict=True) != helper:
        raise RuntimeError('Application/helper path contains symlinks')
    info = helper.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not os.access(helper, os.X_OK):
        raise RuntimeError('Helper must be a single-link regular executable')
    if any(path.name in FORBIDDEN for path in app.rglob('*')):
        raise RuntimeError('Decision gate or transport fixture must not ship')
    return helper


def source_inventory(root, source):
    if run(['git', 'rev-parse', 'HEAD'], cwd=root).stdout.decode().strip() != source:
        raise RuntimeError('Requested source differs from checkout HEAD')
    files = [root / name for name in PACKAGE_SOURCES + INTEGRATION_SOURCES]
    for module in MODULES:
        sources = sorted((root / 'Sources' / module).glob('*.swift'))
        if not sources:
            raise RuntimeError('Missing production module: ' + module)
        files.extend(sources)
    for module in ('PicShotTextScriptCoreTests', 'PicShotTextScriptHelperTests'):
        sources = sorted((root / 'Tests' / module).glob('*.swift'))
        if not sources:
            raise RuntimeError('Missing production test module: ' + module)
        files.extend(sources)
    inventory = []
    for path in sorted(files):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink() or not path.is_file():
            raise RuntimeError('Invalid source path: ' + relative)
        committed = run(['git', 'show', source + ':' + relative], cwd=root).stdout
        if path.read_bytes() != committed:
            raise RuntimeError('Source differs from exact commit: ' + relative)
        inventory.append({'path': relative, 'bytes': path.stat().st_size, 'sha256': sha(path)})
    return inventory


def verify_app(app, source, expected_plist, root):
    helper = check_regular_helper(app)
    app_plist_path = app / 'Contents/Info.plist'
    app_plist = plistlib.loads(app_plist_path.read_bytes())
    build_info_path = app / 'Contents/Resources/build-info.json'
    build_info = json.loads(build_info_path.read_text())
    if (app_plist.get('CFBundleIdentifier') != APP_IDENTIFIER or
            app_plist.get('CFBundleExecutable') != 'PicShot' or
            app_plist.get('PicShotSourceCommit') != source or
            build_info.get('sourceCommit') != source or
            app_plist.get('CFBundleShortVersionString') != build_info.get('version')):
        raise RuntimeError('Application metadata does not match source/version')
    outer = signature(app, APP_IDENTIFIER)
    inner = signature(helper, IDENTIFIER)
    require_same_team(outer, inner)
    decoded = plistlib.loads(run(['codesign', '-d', '--entitlements', ':-', str(helper)]).stdout)
    require_sandbox(decoded)
    observed_plist = json.loads(run(['xcrun', 'swift', str(root / 'scripts/read-signed-helper-plist.swift'),
                                    str(helper), IDENTIFIER]).stdout)
    require_exact_plist(observed_plist, expected_plist)
    architectures = sorted(run(['lipo', '-archs', str(helper)]).stdout.decode().split())
    app_architectures = sorted(run(['lipo', '-archs', str(app / 'Contents/MacOS/PicShot')]).stdout.decode().split())
    if not architectures or architectures != app_architectures:
        raise RuntimeError('Helper and application architectures differ')
    libraries = []
    for line in run(['otool', '-L', str(helper)]).stdout.decode().splitlines()[1:]:
        library = line.strip().split(' ', 1)[0]
        if not library.startswith(('/usr/lib/', '/System/Library/')):
            raise RuntimeError('Non-system helper dependency: ' + library)
        libraries.append(library)
    return {
        'appIdentifier': outer['Identifier'], 'appCDHash': outer['CDHash'],
        'appTeamIdentifier': outer['TeamIdentifier'],
        'executableSHA256': sha(app / 'Contents/MacOS/PicShot'),
        'appInfoPlistSHA256': sha(app_plist_path), 'buildInfoSHA256': sha(build_info_path),
        'version': build_info['version'], 'build': app_plist.get('CFBundleVersion'),
        'architectures': architectures, 'appSignatureVerified': True,
        'helper': {'path': HELPER_PATH, 'identifier': inner['Identifier'],
                   'teamIdentifier': inner['TeamIdentifier'], 'cdHash': inner['CDHash'],
                   'sha256': sha(helper), 'bytes': helper.stat().st_size,
                   'entitlements': decoded, 'signedInfoPlist': observed_plist,
                   'linkedLibraries': libraries, 'strictSignatureVerified': True},
        'sameTeamIdentifierVerified': True,
        'helperEntitlementsVerifiedAfterOuterSigning': True,
        'helperSignedInfoPlistVerifiedAfterOuterSigning': True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--source', required=True)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--verify-relocation', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('This check requires macOS codesign and Security.framework')
    if not re.fullmatch(r'[0-9a-f]{40}', args.source):
        parser.error('Expected exact source commit')
    # abspath does not hide an app/helper symlink from the validation below.
    app = Path(os.path.abspath(args.app))
    if app.suffix != '.app' or not app.is_dir():
        parser.error('Expected an existing .app bundle')
    report = args.report.resolve()
    if report == app or app in report.parents:
        parser.error('Write packaging proof outside the signed application')
    root = Path(__file__).resolve().parents[1]
    inventory = source_inventory(root, args.source)
    expected_plist = require_helper_plist(plistlib.loads((root / 'scripts/text-script-helper-Info.plist').read_bytes()))
    require_sandbox(plistlib.loads((root / 'scripts/text-script-helper.entitlements').read_bytes()))
    result = verify_app(app, args.source, expected_plist, root)
    result.update({'schemaVersion': 1, 'sourceCommit': args.source, 'sources': inventory,
                   'scope': 'experimental package identity/signatures only; installed runtime and UI acceptance are separate',
                   'embeddedInfoPlistSHA256': sha(root / 'scripts/text-script-helper-Info.plist'),
                   'entitlementsSourceSHA256': sha(root / 'scripts/text-script-helper.entitlements'),
                   'relocationVerified': False, 'installedRuntimeAcceptanceVerified': False})
    if args.verify_relocation:
        with tempfile.TemporaryDirectory(prefix='PicShotTextScript-package-') as temporary:
            relocated = Path(temporary).resolve() / 'Relocated.app'
            run(['ditto', str(app), str(relocated)], timeout=120)
            relocated_result = verify_app(relocated, args.source, expected_plist, root)
            if relocated_result != {key: result[key] for key in relocated_result}:
                raise RuntimeError('Relocation changed signed package identity')
            result['relocationVerified'] = True
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'report': str(report), 'sourceCommit': args.source,
                      'helperSHA256': result['helper']['sha256'],
                      'relocationVerified': result['relocationVerified']}))


if __name__ == '__main__':
    main()
