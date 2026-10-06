#!/usr/bin/env python3
"""Copy only dynamic @rpath frameworks actually linked by our isolated helper."""
from pathlib import Path
import shutil, subprocess, sys
app = Path(sys.argv[1]); helper = app/'Contents/Helpers/PicShotMLHelper'
listing = subprocess.check_output(['otool', '-L', str(helper)], text=True)
print(listing)
frameworks = []
for line in listing.splitlines()[1:]:
    library = line.strip().split(' (', 1)[0]
    if not library.startswith('@rpath/'): continue
    relative = library[len('@rpath/'):]
    if '.framework/' not in relative: raise RuntimeError('Unbundled dynamic library: ' + library)
    name = relative.split('.framework/', 1)[0] + '.framework'
    candidates = [p for p in Path('.build/artifacts').rglob(name) if p.is_dir() and any('macos' in x for x in p.parts)]
    if len(candidates) != 1: raise RuntimeError('Cannot uniquely locate macOS framework ' + name + ': ' + str(candidates))
    destination = app/'Contents/Frameworks'/name
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists(): shutil.rmtree(destination)
    shutil.copytree(candidates[0], destination, symlinks=True)
    frameworks.append(destination)
if frameworks:
    subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(helper)], check=True)
    for framework in frameworks: subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(framework)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'local.picshot.mlhelper', str(helper)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(helper)], check=True)
