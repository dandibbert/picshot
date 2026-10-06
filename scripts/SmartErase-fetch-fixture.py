#!/usr/bin/env python3
"""Explicit, approved developer/CI provisioning only; never bundled with app.
Downloads the exact author-linked original CoreMLaMa FP32 pack. The owner's
approval covers Google's large-file Download anyway warning for this model.
Any access denial or integrity failure aborts; no fallback/mirror sources.
"""
import hashlib
from pathlib import Path
import re
import sys
import urllib.parse
import urllib.request

source = Path('Sources/PicShotEraseCore/SmartEraseModelPack.swift').read_text()
block = source.split('let files:', 1)[1].split('return ModelPackManifest', 1)[0]
assets = re.findall(r'\("([a-zA-Z0-9_.-]+)", ([0-9_]+), "([0-9a-f]{64})", "([a-zA-Z0-9_-]+)"\)', block)
if len(assets) != 3:
    raise RuntimeError('Expected exactly three fixed approved assets')
root = Path(sys.argv[1] if len(sys.argv) > 1 else '.build/model-fixtures/erase')
root.mkdir(parents=True, exist_ok=True, mode=0o700)

class SameHost(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        url = urllib.parse.urlsplit(newurl)
        if url.scheme != 'https' or url.hostname != 'drive.usercontent.google.com' or url.username or url.password:
            raise RuntimeError('Refusing model redirect outside approved source')
        return super().redirect_request(req, fp, code, msg, headers, newurl)
opener = urllib.request.build_opener(SameHost)
for name, size, digest, drive_id in assets:
    size = int(size.replace('_', ''))
    target = root / name
    if target.is_file() and target.stat().st_size == size and hashlib.sha256(target.read_bytes()).hexdigest() == digest:
        print('Already verified', name); continue
    url = 'https://drive.usercontent.google.com/download?' + urllib.parse.urlencode({'id': drive_id, 'export': 'download', 'confirm': 't'})
    temporary = target.with_name(name + '.partial')
    count = 0
    actual = hashlib.sha256()
    try:
        with opener.open(urllib.request.Request(url, headers={'Accept-Encoding': 'identity'}), timeout=120) as response:
            if response.status != 200:
                raise RuntimeError('Original source returned HTTP ' + str(response.status))
            with temporary.open('xb') as output:
                temporary.chmod(0o600)
                while True:
                    chunk = response.read(1_048_576)
                    if not chunk: break
                    count += len(chunk)
                    if count > size: raise RuntimeError('Oversized model: ' + name)
                    output.write(chunk); actual.update(chunk)
        if count != size or actual.hexdigest() != digest:
            raise RuntimeError('Model size/checksum mismatch: ' + name)
        temporary.replace(target)
        print('Verified', name, size, digest)
    finally:
        temporary.unlink(missing_ok=True)
print('PICSHOT_ERASE_MODEL_DIR=' + str(root.resolve()))
