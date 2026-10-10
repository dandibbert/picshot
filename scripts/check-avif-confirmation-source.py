#!/usr/bin/env python3
"""Pin the existing native implementation for this shell-only AVIF observation."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

BASE = 'c625e309d39326541db1c4c4756e16fcd7e1eb6b'
TREE = '009df062cd6439f967f1ce33ac6eef7dfd014f05'
ROOTS = ['Sources', 'Tests', 'Package.swift', 'scripts']
# Only observation orchestration changes; existing thirteen tests stay byte-identical.
ALLOWED = {'scripts/codec-staging-comparison.sh', 'scripts/check-codec-staging-comparison.py',
           'scripts/check-avif-confirmation-source.py', 'scripts/tests/test_avif_confirmation.py'}

def verify(root):
    def git(*args):return subprocess.check_output(['git','-C',str(root),*args])
    if git('rev-parse',BASE+'^{tree}').decode().strip()!=TREE:
        raise ValueError('Pinned native source commit/tree is unavailable or differs')
    records=[]
    for line in git('ls-tree','-rz','--full-tree',BASE,'--',*ROOTS).split(b'\0'):
        if not line:continue
        metadata,name=line.split(b'\t',1);mode,kind,expected=metadata.decode().split();name=name.decode()
        if name in ALLOWED:continue
        file=root/name
        if kind!='blob' or file.is_symlink() or not file.is_file():raise ValueError('Missing/nonregular protected source: '+name)
        data=file.read_bytes()
        actual=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
        if actual!=expected:raise ValueError('Protected native/build/test bytes changed: '+name)
        records.append({'path':name,'gitBlob':actual,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)})
    expected_names={r['path'] for r in records}
    current_names=set(git('ls-files','--cached','--others','--exclude-standard','--',*ROOTS).decode().splitlines())-ALLOWED
    # SwiftPM sees native files even if a Git ignore pattern hides them.
    for directory in ['Sources','Tests']:
        current_names.update(str(p.relative_to(root)) for p in (root/directory).rglob('*') if p.is_file() or p.is_symlink())
    if current_names!=expected_names:raise ValueError('Protected native/build/test path set differs from the pinned base')
    return {'status':'verified','baseCommit':BASE,'baseTree':TREE,'headCommit':git('rev-parse','HEAD').decode().strip(),
        'protectedFiles':records,'protectedFileCount':len(records),'nativeSourceBytesUnchanged':True,
        'scope':'All Sources, native Tests, package manifest and build/launcher scripts match the pinned base. Only declared shell/checker confirmation files may differ. Previously passing 79 native tests are not rerun by this observation.'}

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,default=Path.cwd());parser.add_argument('--report',type=Path,required=True);args=parser.parse_args()
    try:report=verify(args.root.resolve(strict=True))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:report={'status':'failed','baseCommit':BASE,'error':str(error),'nativeSourceBytesUnchanged':False}
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='protectedFiles'}));raise SystemExit(0 if report['status']=='verified' else 1)
