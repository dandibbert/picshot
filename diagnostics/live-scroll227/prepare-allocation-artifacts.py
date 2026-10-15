#!/usr/bin/env python3
"""Preserve bounded diagnostic records; this never classifies memory eligibility."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import zipfile

TEXT_PART_BYTES = 20 * 1024 * 1024
IMAGE_BYTES = 32 * 1024 * 1024


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(1 << 20):
            value.update(block)
    return value.hexdigest()


def prepare(root):
    root = root.resolve()
    destination = root / 'artifacts'
    destination.mkdir(parents=True, exist_ok=False)
    images, errors, parts = [], [], []
    image_destination = destination / 'outputs'
    image_destination.mkdir()
    # Stage bounded regular files first, so a later text-record failure does not
    # hide already produced output evidence. The workflow uploads only this set.
    for path in sorted((root / 'resource/measure').glob('cycle-*.png')):
        if not re.fullmatch(r'cycle-(?:0[1-9]|10)\.png', path.name):
            errors.append('Unexpected output identity: ' + path.name)
            continue
        if path.is_symlink() or not path.is_file():
            errors.append('Non-regular output: ' + path.name)
            continue
        size = path.stat().st_size
        if size <= 0 or size >= IMAGE_BYTES:
            errors.append('Output exceeds bounded artifact size: ' + path.name)
            continue
        digest = sha(path)
        staged = image_destination / path.name
        shutil.copyfile(path, staged)
        assert staged.stat().st_size == size and sha(staged) == digest
        images.append({'file': path.name, 'bytes': size, 'sha256': digest, 'under32MiB': True})
    files = []
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if relative.parts[0] in {'source', 'artifacts'} or not path.is_file() or path.is_symlink():
            continue
        if path.suffix.lower() not in {'.json', '.log', '.txt', '.md', '.diff', '.yaml', '.yml'}:
            continue
        size = path.stat().st_size
        if size > TEXT_PART_BYTES:
            errors.append('Unexpected individual diagnostic text bound: ' + str(relative))
            continue
        files.append((path, relative, size))
    groups, current, size = [], [], 0
    for item in files:
        if current and size + item[2] > TEXT_PART_BYTES:
            groups.append(current); current, size = [], 0
        current.append(item); size += item[2]
    if current:
        groups.append(current)
    if len(groups) > 8:
        errors.append('Diagnostic records exceeded eight bounded parts')
        groups = groups[:8]
    for index, group in enumerate(groups, 1):
        archive = destination / f'records-{index:02d}.zip'
        with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as output:
            for path, relative, _ in group:
                output.write(path, str(relative))
        assert archive.stat().st_size < 24 * 1024 * 1024
        parts.append({'file': archive.name, 'bytes': archive.stat().st_size, 'sha256': sha(archive),
                      'members': [{'path': str(relative), 'bytes': size, 'sha256': sha(path)} for path, relative, size in group]})
    report = {'schemaVersion': 1, 'diagnosticOnly': True, 'installerAcceptance': False,
        'status': 'bounded-evidence-prepared' if not errors else 'incomplete-evidence', 'errors': errors,
        'original227MemoryFailurePreserved': True, 'recordParts': parts, 'producedOutputs': images,
        'rawJournalUploaded': False, 'rawJournalScope': 'Full history queried while owned process lives; original journal is confined to owned fixed-capacity volume, not a portable offline proof',
        'imageVerificationScope': 'All available complete outputs are decoded separately after measured process exit; missing cycles remain missing'}
    (root / 'artifact-manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    report = prepare(Path('dist/allocation227'))
    print(json.dumps({'parts': len(report['recordParts']), 'producedOutputs': len(report['producedOutputs']),
                      'status': report['status'], 'installerAcceptance': False}))
    raise SystemExit(0 if not report['errors'] else 1)
