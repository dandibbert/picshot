#!/usr/bin/env python3
"""Build-input/provenance adapter for a pinned, instrumented 0.13 control.

This never creates a baseline installer or labels the modified app as the
delivered binary. The original production checkout is verified before overlay.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

BASELINE = 'fa4cb0ad742e89c9235cfea2eef6b5d7840a78a9'
FIXTURE = 'Sources/PicShot/ScrollMemoryAttributionFixture.swift'
SMOKE = 'Sources/PicShot/SmokeVerification.swift'
ANCHOR = '            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)\n'
ROUTE = '''            if let payload = try await ScrollMemoryAttributionFixture.runIfRequested(evidenceDirectory: directory, detailRenderer: nil) {
                try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: history.directory)
                NSApp.terminate(nil); return
            }
'''


def need(value, message):
    if not value:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def regular(path):
    need(path.is_file() and not path.is_symlink(), 'expected a regular non-symlink file: '+str(path))
    return path.read_bytes()


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def inject_route(text):
    need(text.count(ANCHOR) == 1 and 'ScrollMemoryAttributionFixture' not in text,
         'baseline smoke route does not match its pinned contract')
    return text.replace(ANCHOR, ANCHOR+ROUTE)


def overlay(current, baseline, commit, manifest):
    current = current.resolve(strict=True); baseline = baseline.resolve(strict=True)
    need(current != baseline and re.fullmatch('[0-9a-f]{40}', commit), 'invalid source roots/overlay commit')
    need(git(current, 'rev-parse', 'HEAD') == commit, 'current checkout identity differs')
    need(git(baseline, 'rev-parse', 'HEAD') == BASELINE, 'baseline checkout identity differs')
    need(not git(baseline, 'status', '--porcelain'), 'baseline checkout must be pristine before overlay')
    need(not manifest.exists(), 'refusing to overwrite an existing diagnostic manifest')
    original = regular(baseline/SMOKE)
    patched = inject_route(original.decode()).encode()
    fixture = regular(current/FIXTURE)
    need(not (baseline/FIXTURE).exists(), 'fixture unexpectedly exists in baseline')
    common = ['Sources/PicShot/ScrollCaptureController.swift', 'Sources/PicShot/ScrollSequenceImageIO.swift',
              'Sources/PicShot/ImageBackingMemoryReading.swift', 'Sources/PicShotCore/ScrollCaptureSequence.swift',
              'Sources/PicShotCore/ScrollStitcher.swift']
    evidence = dict(schemaVersion=1, diagnosticOnly=True, baselineProductionCommit=BASELINE,
                    diagnosticOverlayCommit=commit, label='fa4cb0ad production code + diagnostic overlay; not the delivered binary',
                    originalSmokeSHA256=digest(original), overlaidSmokeSHA256=digest(patched),
                    addedFiles={FIXTURE:digest(fixture)},
                    unchangedProductionFiles={name:digest(regular(baseline/name)) for name in common})
    (baseline/FIXTURE).write_bytes(fixture)
    (baseline/SMOKE).write_bytes(patched)
    need(set(git(baseline, 'diff', '--name-only').splitlines()) == {SMOKE}, 'unexpected tracked baseline edit')
    need(set(git(baseline, 'ls-files', '--others', '--exclude-standard').splitlines()) == {FIXTURE},
         'unexpected untracked baseline edit')
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(evidence, indent=2)+'\n')
    print('Pinned production checkout and diagnostic overlay verified')


def stamp(app, manifest, commit):
    app = app.resolve(strict=True)
    evidence = json.loads(regular(manifest))
    need(evidence['diagnosticOnly'] is True and evidence['baselineProductionCommit'] == BASELINE
         and evidence['diagnosticOverlayCommit'] == commit, 'overlay manifest identity differs')
    plist_path = app/'Contents/Info.plist'; info = plistlib.loads(regular(plist_path))
    need(info['PicShotSourceCommit'] == BASELINE and info['CFBundleShortVersionString'] == '0.13.0',
         'baseline package provenance differs')
    info.update(PicShotSourceCommit=commit, PicShotBaselineProductionCommit=BASELINE,
                PicShotDiagnosticOverlayCommit=commit, PicShotDiagnosticOnly=True)
    plist_path.write_bytes(plistlib.dumps(info))
    build_path = app/'Contents/Resources/build-info.json'; build = json.loads(regular(build_path))
    need(build['sourceCommit'] == BASELINE, 'baseline build-info identity differs')
    build.update(sourceCommit=commit, baselineProductionCommit=BASELINE,
                 diagnosticOverlayCommit=commit, diagnosticOnly=True)
    build_path.write_text(json.dumps(build, indent=2)+'\n')
    resource = app/'Contents/Resources/scroll-baseline-overlay.json'
    need(not resource.exists(), 'refusing to overwrite baseline overlay resource')
    shutil.copyfile(manifest, resource)
    subprocess.run(['codesign','--force','--deep','--sign','-','--identifier','local.picshot.app',str(app)], check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)], check=True)
    print('Instrumented baseline app explicitly stamped and signature verified')


def main():
    parser=argparse.ArgumentParser(description=__doc__); sub=parser.add_subparsers(dest='mode',required=True)
    first=sub.add_parser('overlay');first.add_argument('current',type=Path);first.add_argument('baseline',type=Path)
    first.add_argument('commit');first.add_argument('manifest',type=Path)
    second=sub.add_parser('stamp');second.add_argument('app',type=Path);second.add_argument('manifest',type=Path);second.add_argument('commit')
    args=parser.parse_args()
    try:
        if args.mode=='overlay': overlay(args.current,args.baseline,args.commit,args.manifest)
        else: stamp(args.app,args.manifest,args.commit)
    except (ValueError,KeyError,OSError,subprocess.CalledProcessError) as error:
        parser.exit(1,'scroll baseline preparation rejected: '+str(error)+'\n')


if __name__=='__main__': main()
