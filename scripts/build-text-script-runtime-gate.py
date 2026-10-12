#!/usr/bin/env python3
"""Build only the source-bound text helper decision gate, without app dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys


def run(command, *, cwd=None, timeout=240):
    try:
        return subprocess.run(command, cwd=cwd, check=True, timeout=timeout,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except subprocess.CalledProcessError as error:
        # Preserve the first actual compiler/signing failure in the existing
        # bounded-command log instead of reducing it to a Python exit code.
        sys.stdout.write(error.stdout or '')
        sys.stderr.write(error.stderr or '')
        raise
    except subprocess.TimeoutExpired as error:
        for stream, value in [(sys.stdout, error.stdout), (sys.stderr, error.stderr)]:
            stream.write(value.decode('utf-8', errors='replace') if isinstance(value, bytes) else (value or ''))
        raise


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--source', required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        raise RuntimeError('This gate must be built on macOS')
    if len(args.source) != 40 or any(c not in '0123456789abcdef' for c in args.source):
        raise ValueError('Expected exact source commit')
    root = Path(__file__).resolve().parents[1]
    if run(['git', 'rev-parse', 'HEAD'], cwd=root).stdout.strip() != args.source:
        raise RuntimeError('Requested source differs from checkout HEAD')
    if run(['git', 'status', '--porcelain', '--untracked-files=all'], cwd=root).stdout:
        raise RuntimeError('Decision gate requires a clean source checkout')
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    build = output / 'swift-package'
    app = output / 'PicShotTextScriptGate.app'
    if build.exists() or app.exists():
        raise RuntimeError('Refusing to replace an existing gate build')
    build.mkdir()
    inventory = []
    modules = ['PicShotTextScriptCore', 'PicShotTextScriptHelper',
               'PicShotTextScriptProcess', 'PicShotTextScriptGate',
               'PicShotTextScriptTransportFixture']
    for module in modules:
        files = sorted((root / 'Sources' / module).glob('*.swift'))
        if not files or len(files) > 20:
            raise RuntimeError('Missing or unexpectedly large module: ' + module)
        target = build / 'Sources' / module
        target.mkdir(parents=True)
        for source in files:
            if source.is_symlink() or source.stat().st_size > 256 * 1024:
                raise RuntimeError('Invalid source file')
            destination = target / source.name
            shutil.copyfile(source, destination)
            if sha(source) != sha(destination):
                raise RuntimeError('Source copy changed')
            inventory.append({'path': str(source.relative_to(root)),
                              'bytes': source.stat().st_size, 'sha256': sha(source)})
    for module in ['PicShotTextScriptCoreTests', 'PicShotTextScriptHelperTests']:
        files = sorted((root / 'Tests' / module).glob('*.swift'))
        if not files or len(files) > 20:
            raise RuntimeError('Missing or unexpectedly large test module: ' + module)
        target = build / 'Tests' / module
        target.mkdir(parents=True)
        for source in files:
            if source.is_symlink() or source.stat().st_size > 256 * 1024:
                raise RuntimeError('Invalid test source')
            destination = target / source.name
            shutil.copyfile(source, destination)
            if sha(source) != sha(destination):
                raise RuntimeError('Test source copy changed')
            inventory.append({'path': str(source.relative_to(root)),
                              'bytes': source.stat().st_size, 'sha256': sha(source)})
    helper_plists = {}
    for name, filename, identifier in [
            ('PicShotTextScriptHelper', 'text-script-helper-Info.plist', 'com.picshot.TextScriptHelper'),
            ('PicShotTextScriptTransportFixture', 'text-script-transport-Info.plist', 'com.picshot.TextScriptTransportFixture')]:
        plist_source = root / 'scripts' / filename
        metadata = plistlib.loads(plist_source.read_bytes())
        if metadata.get('CFBundleIdentifier') != identifier or metadata.get('CFBundleExecutable') != name:
            raise RuntimeError('Embedded helper identity source differs')
        destination = build / filename
        shutil.copyfile(plist_source, destination)
        helper_plists[name] = (destination, metadata)
        inventory.append({'path': str(plist_source.relative_to(root)),
                          'bytes': plist_source.stat().st_size, 'sha256': sha(plist_source)})
    plist_reader = root / 'scripts' / 'read-signed-helper-plist.swift'
    inventory.append({'path': str(plist_reader.relative_to(root)),
                      'bytes': plist_reader.stat().st_size, 'sha256': sha(plist_reader)})
    package = '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PicShotTextScriptDecisionGate", platforms: [.macOS(.v14)],
 products: [.executable(name: "PicShotTextScriptHelper", targets: ["PicShotTextScriptHelper"]),
            .executable(name: "PicShotTextScriptGate", targets: ["PicShotTextScriptGate"]),
            .executable(name: "PicShotTextScriptTransportFixture", targets: ["PicShotTextScriptTransportFixture"])],
 targets: [.target(name: "PicShotTextScriptCore"),
           .target(name: "PicShotTextScriptProcess", dependencies: ["PicShotTextScriptCore"],
                   swiftSettings: [.define("TEXT_SCRIPT_GATE")]),
           .executableTarget(name: "PicShotTextScriptHelper", dependencies: ["PicShotTextScriptCore"],
             linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", __HELPER_PLIST__])]),
           .executableTarget(name: "PicShotTextScriptTransportFixture", dependencies: ["PicShotTextScriptCore"],
             linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", __FIXTURE_PLIST__])]),
           .executableTarget(name: "PicShotTextScriptGate", dependencies: ["PicShotTextScriptCore", "PicShotTextScriptProcess"],
                             swiftSettings: [.define("TEXT_SCRIPT_GATE")]),
           .testTarget(name: "PicShotTextScriptCoreTests", dependencies: ["PicShotTextScriptCore"]),
           .testTarget(name: "PicShotTextScriptHelperTests", dependencies: ["PicShotTextScriptCore", "PicShotTextScriptHelper"])])
'''
    package = package.replace('__HELPER_PLIST__', json.dumps(str(helper_plists['PicShotTextScriptHelper'][0])))
    package = package.replace('__FIXTURE_PLIST__', json.dumps(str(helper_plists['PicShotTextScriptTransportFixture'][0])))
    (build / 'Package.swift').write_text(package)
    # This package has no external dependencies and cannot invoke the application's
    # codec/model build paths. Compile exactly the inventoried Swift source copies.
    compile_result = run(['swift', 'test', '-c', 'release', '--package-path', str(build)])
    (output / 'compile.stdout.log').write_text(compile_result.stdout)
    (output / 'compile.stderr.log').write_text(compile_result.stderr)
    binary = Path(run(['swift', 'build', '-c', 'release', '--package-path', str(build),
                       '--show-bin-path']).stdout.strip())
    main_directory = app / 'Contents' / 'MacOS'
    helper_directory = app / 'Contents' / 'Helpers'
    main_directory.mkdir(parents=True)
    helper_directory.mkdir()
    executable_names = ['PicShotTextScriptGate', 'PicShotTextScriptHelper',
                        'PicShotTextScriptTransportFixture']
    for name in executable_names:
        destination = (main_directory if name == 'PicShotTextScriptGate' else helper_directory) / name
        shutil.copy2(binary / name, destination)
        os.chmod(destination, 0o755)
    plist = {'CFBundleExecutable': 'PicShotTextScriptGate',
             'CFBundleIdentifier': 'com.picshot.TextScriptGate',
             'CFBundleName': 'PicShotTextScriptGate', 'CFBundlePackageType': 'APPL',
             'CFBundleShortVersionString': '1.0', 'CFBundleVersion': os.environ.get('GITHUB_RUN_NUMBER', '1'),
             'LSMinimumSystemVersion': '14.0', 'PicShotSourceCommit': args.source}
    (app / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(plist))
    resources = app / 'Contents' / 'Resources'
    resources.mkdir()
    (resources / 'text-script-gate-source.txt').write_text(args.source + '\n')
    entitlement_source = root / 'scripts' / 'text-script-helper.entitlements'
    entitlement_data = plistlib.loads(entitlement_source.read_bytes())
    if (set(entitlement_data) != {'com.apple.security.app-sandbox'} or
            entitlement_data['com.apple.security.app-sandbox'] is not True):
        raise RuntimeError('Source entitlement must contain only Boolean app-sandbox=true')
    entitlements = output / 'text-script-helper.entitlements'
    shutil.copyfile(entitlement_source, entitlements)
    inventory.append({'path': str(entitlement_source.relative_to(root)),
                      'bytes': entitlement_source.stat().st_size, 'sha256': sha(entitlement_source)})
    signing = []
    for name, identifier in [('PicShotTextScriptHelper', 'com.picshot.TextScriptHelper'),
                             ('PicShotTextScriptTransportFixture', 'com.picshot.TextScriptTransportFixture')]:
        child = helper_directory / name
        run(['codesign', '--force', '--sign', '-', '--identifier', identifier,
             '--entitlements', str(entitlements), str(child)])
        signing.append({'path': str(child.relative_to(app)), 'identifier': identifier})
    # Sign the outer bundle without --deep re-signing children and erasing their
    # independent sandbox entitlements. Deep verification remains mandatory.
    run(['codesign', '--force', '--sign', '-', '--identifier', 'com.picshot.TextScriptGate', str(app)])
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    for entry in signing:
        child = app / entry['path']
        xml = run(['codesign', '-d', '--entitlements', ':-', str(child)])
        decoded = plistlib.loads(xml.stdout.encode())
        if decoded != {'com.apple.security.app-sandbox': True}:
            raise RuntimeError('Unexpected final helper entitlements')
        actual = run(['codesign', '-d', '--verbose=4', str(child)])
        signing_text = actual.stdout + actual.stderr
        (output / (child.name + '.codesign.log')).write_text(signing_text)
        identifier = re.search(r'^Identifier=(.+)$', signing_text, re.MULTILINE)
        cdhash = re.search(r'^CDHash=([0-9a-f]+)$', signing_text, re.MULTILINE)
        if not identifier or identifier.group(1) != entry['identifier'] or not cdhash:
            raise RuntimeError('Final helper signing identity differs')
        observed_plist = json.loads(run(['xcrun', 'swift', str(plist_reader), str(child), entry['identifier']], timeout=30).stdout)
        if observed_plist != helper_plists[child.name][1]:
            raise RuntimeError('Signed embedded helper Info.plist differs after outer signing')
        entry.update({'entitlements': decoded, 'sha256': sha(child), 'bytes': child.stat().st_size,
                      'observedIdentifier': identifier.group(1), 'observedCDHash': cdhash.group(1),
                      'observedSignedInfoPlist': observed_plist,
                      'embeddedInfoPlistSHA256': sha(helper_plists[child.name][0])})
    report = {'schemaVersion': 1, 'sourceCommit': args.source,
              'scope': 'native runtime decision gate only; no app UI or distribution qualification',
              'architecture': run(['uname', '-m']).stdout.strip(),
              'swiftVersion': run(['swift', '--version']).stdout.strip(),
              'sources': inventory, 'generatedPackageSHA256': sha(build / 'Package.swift'),
              'appPath': str(app), 'executableSHA256': sha(main_directory / 'PicShotTextScriptGate'),
              'plistSHA256': sha(app / 'Contents' / 'Info.plist'), 'helpers': signing,
              'appSignatureVerified': True, 'helperEntitlementsVerifiedAfterOuterSigning': True,
              'externalPackageDependencies': []}
    archive = output / 'gate-signed-bundle.zip'
    run(['ditto', '-c', '-k', '--keepParent', str(app), str(archive)])
    if archive.stat().st_size > 18 * 1024 * 1024:
        raise RuntimeError('Signed gate evidence archive exceeds its bounded artifact allowance')
    report['gateArchive'] = {'name': archive.name, 'bytes': archive.stat().st_size, 'sha256': sha(archive)}
    (output / 'build-identity.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'app': str(app), 'sourceCommit': args.source,
                      'helperSHA256': signing[0]['sha256']}))


if __name__ == '__main__':
    main()
