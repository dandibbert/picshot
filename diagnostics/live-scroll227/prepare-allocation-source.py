#!/usr/bin/env python3
"""Bind an original227 worktree plus only the reviewed observation overlay."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

BASE = 'e5a859a82b2a7a697e51a0a4d42f34ae4f5602d0'
TREE = 'bee9ab45ee7770f2aab84565f392934f21903030'
ALLOWED = {
    'Sources/PicShot/LiveScrollResourceFixture.swift',
    'Sources/PicShot/LiveScrollAllocationDiagnostic.swift',
    'scripts/launch-smoke-app.swift',
}


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], timeout=20)


def main():
    root = Path.cwd().resolve()
    evidence = root / 'dist/allocation227'
    source = evidence / 'source'
    payload = root / 'diagnostics/live-scroll227'
    assert platform.system() == 'Darwin' and platform.machine() == 'arm64'
    assert git(root, 'rev-parse', 'HEAD').decode().strip() == os.environ['GITHUB_SHA']
    assert not source.exists(), 'Refuse existing diagnostic worktree'
    assert git(root, 'rev-parse', BASE + '^{tree}').decode().strip() == TREE
    evidence.mkdir(parents=True, exist_ok=True)
    subprocess.run(['git', 'worktree', 'add', '--detach', str(source), BASE], check=True, timeout=60)
    assert not git(source, 'status', '--porcelain', '--untracked-files=all').strip()
    manifest = json.loads((payload / 'overlay-manifest.json').read_text())
    assert manifest['productBase'] == BASE and manifest['productTree'] == TREE
    assert set(manifest['appOverlay']) == ALLOWED
    applied = {}
    for name, expected in manifest['appOverlay'].items():
        target = source / name
        before = target.read_bytes() if target.is_file() else None
        assert (hashlib.sha256(before).hexdigest() if before is not None else None) == expected['originalSHA256'], name
        if name == 'Sources/PicShot/LiveScrollResourceFixture.swift':
            (evidence / 'original-fixture.swift').write_bytes(before)
        incoming = (payload / 'overlay' / name).read_bytes()
        assert hashlib.sha256(incoming).hexdigest() == expected['overlaySHA256'], name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(incoming)
        applied[name] = expected
    changed = set(git(source, 'diff', '--name-only').decode().splitlines())
    untracked = set(git(source, 'ls-files', '--others', '--exclude-standard').decode().splitlines())
    assert changed | untracked == ALLOWED and not git(source, 'diff', '--cached').strip()
    assert not git(source, 'diff', '--summary').strip(), 'No tracked modes or deletes may change'
    (evidence / 'observation-overlay.diff').write_bytes(git(source, 'diff', '--', *sorted(changed)))
    receipt = {
        'schemaVersion': 1, 'productBase': BASE, 'productTree': TREE,
        'workflowCommit': os.environ['GITHUB_SHA'], 'runID': os.environ['GITHUB_RUN_ID'],
        'runAttempt': os.environ['GITHUB_RUN_ATTEMPT'], 'overlayManifestSHA256': hashlib.sha256((payload / 'overlay-manifest.json').read_bytes()).hexdigest(),
        'appOverlay': applied, 'changedProductBehavior': False, 'diagnosticBinaryDiffers': True,
        'diagnosticOnly': True, 'installerAcceptance': False, 'original227MemoryFailurePreserved': True,
        'originalWarmRSS': 10780672, 'warmLimit': 9830400,
        'originalLateThreeRSS': 5177344, 'lateLimit': 4915200,
        'worktreePath': str(source), 'expectedWorkload': {'warmups': 2, 'measured': 8, 'framesPerCycle': 218},
    }
    (evidence / 'source-identity.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'productBase': BASE, 'diagnosticOverlayFiles': sorted(ALLOWED), 'installerAcceptance': False}))


if __name__ == '__main__':
    main()
