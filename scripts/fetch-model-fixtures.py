#!/usr/bin/env python3
"""Explicit CI-only fixture provisioning. The installed app never runs this script.
Only original, pinned sources; a denial/failure aborts without trying mirrors.
"""
import hashlib
from pathlib import Path
import re
import urllib.request

source = Path('Sources/PicShotFormulaCore/ModelManifest.swift').read_text()
revision = re.search(r'formulaRevision = "([0-9a-f]{40})"', source).group(1)
assets = [(name, int(size.replace('_', '')), sha) for name, size, sha in re.findall(r'asset\("([a-zA-Z0-9_.-]+)", ([0-9_]+), "([0-9a-f]{64})"\)', source)]
assert len(assets) == 7
root = Path('.build/model-fixtures')

def get(url, path, size, digest):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.stat().st_size == size and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
        return
    partial = path.with_suffix(path.suffix + '.partial')
    actual = hashlib.sha256(); count = 0
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={'Accept-Encoding': 'identity'}), timeout=120) as response, partial.open('wb') as target:
            if response.status != 200: raise RuntimeError('Original model source returned HTTP ' + str(response.status))
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk: break
                count += len(chunk)
                if count > size: raise RuntimeError('Model size exceeded manifest')
                actual.update(chunk); target.write(chunk)
        if count != size or actual.hexdigest() != digest: raise RuntimeError('Model checksum or size mismatch: ' + path.name)
        partial.replace(path)
        print('Verified', path.name, count, digest)
    finally:
        partial.unlink(missing_ok=True)

for name, size, digest in assets:
    get(f'https://huggingface.co/breezedeus/pix2text-mfr-1.5/resolve/{revision}/{name}', root/'formula'/name, size, digest)
get('https://www.modelscope.cn/models/RapidAI/RapidTable/resolve/v2.0.0/slanet-plus.onnx', root/'table'/'slanet-plus.onnx', 7758305, 'd57a942af6a2f57d6a4a0372573c696a2379bf5857c45e2ac69993f3b334514b')
