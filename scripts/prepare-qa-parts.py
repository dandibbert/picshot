#!/usr/bin/env python3
"""Package existing final QA evidence for transport, never for acceptance.

Only the six existing final-upload selectors below are read. Source checkouts,
installers and unselected files are not included. File contents are unchanged;
this is not a content/secrets scanner. Run only after evidence writers stop.

Concatenate qa.tar.gz.part-NN in manifest order, verify the archive SHA256,
then read the gzip/tar. Members are relative to --input (normally dist).
Every part directory includes the same complete inventory/manifest. Missing
failure-stage evidence is recorded, not inferred to have passed. Source/build/
arch are caller-supplied labels, not independently verified provenance.

Limits are fixed at the CLI. Gzip/tar metadata and order are deterministic
for a given Python/zlib toolchain; file timestamps and modes are not preserved.
Existing output is never overwritten. A failed preparation publishes no parts.
"""
import argparse
from contextlib import contextmanager
from dataclasses import asdict, dataclass
import fnmatch
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile
import tempfile
import unicodedata


MIB = 1024 * 1024
PATTERNS = ('*.log', '*-report.json', '*-plan.json')
TREES = ('native-test-shards', 'focused-test-shards', 'evidence')
SELECTORS = PATTERNS + tuple(name + '/' for name in TREES)


@dataclass(frozen=True)
class Limits:
    part_bytes: int = 8 * MIB
    max_parts: int = 8
    input_bytes: int = 512 * MIB
    file_bytes: int = 128 * MIB
    files: int = 2048
    entries: int = 16384
    path_bytes: int = 1024
    path_depth: int = 32
    manifest_bytes: int = 4 * MIB


class PackagingError(ValueError):
    pass


def need(condition, message):
    if not condition:
        raise PackagingError(message)


def checked_relative(name, limits):
    need(isinstance(name, str) and name, 'empty member path')
    need('\\' not in name and ':' not in name and not any(ord(c) < 32 or ord(c) == 127 for c in name),
         'unsafe member path: ' + repr(name))
    parts = name.split('/')
    need(not PurePosixPath(name).is_absolute() and all(p not in ('', '.', '..') for p in parts),
         'absolute/escaping member path: ' + repr(name))
    need(not any(p.startswith('.') for p in parts), 'hidden input is outside upload scope: ' + name)
    try:
        length = len(name.encode('utf-8'))
    except UnicodeError as error:
        raise PackagingError('non-UTF-8 member path') from error
    need(length <= limits.path_bytes and len(parts) <= limits.path_depth,
         'member path limit exceeded: ' + name)
    return parts


def absolute_path(value):
    path = Path(value)
    need('..' not in path.parts and '\\' not in str(path), 'escaping filesystem path')
    return path if path.is_absolute() else Path.cwd() / path


@contextmanager
def open_directory(path):
    """Open every ancestor without following links (macOS and Linux)."""
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in absolute_path(path).parts[1:]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                              dir_fd=fd)
            os.close(fd)
            fd = next_fd
        yield fd
    finally:
        os.close(fd)


def signature(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns, info.st_nlink)


def inventory(root_fd, limits):
    files, directories, names, inodes = {}, {}, set(), set()
    counts = {selector: {'files': 0, 'bytes': 0} for selector in SELECTORS}
    entries = 0
    total = 0

    def register(name):
        checked_relative(name, limits)
        key = unicodedata.normalize('NFC', name).casefold()
        need(key not in names, 'duplicate/ambiguous input path: ' + name)
        names.add(key)

    def visit(fd, prefix='', selector=None):
        nonlocal entries, total
        # Bound traversal before sorting; do not materialize an unbounded tree.
        children = []
        with os.scandir(fd) as scan:
            for entry in scan:
                entries += 1
                need(entries <= limits.entries, 'directory entry limit exceeded')
                children.append(entry.name)
        for child in sorted(children):
            name = prefix + child
            group = selector
            if not prefix:
                group = next((p for p in PATTERNS if fnmatch.fnmatchcase(child, p)), None)
                if child in TREES:
                    group = child + '/'
                if group is None:
                    continue
            register(name)
            info = os.stat(child, dir_fd=fd, follow_symlinks=False)
            need(not stat.S_ISLNK(info.st_mode), 'symlink input: ' + name)
            if stat.S_ISDIR(info.st_mode):
                need(bool(prefix) or child in TREES, 'file selector matched a directory: ' + name)
                directories[name] = signature(info)
                child_fd = os.open(child, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    need(signature(os.fstat(child_fd)) == signature(info), 'directory changed: ' + name)
                    visit(child_fd, name + '/', group)
                    need(signature(os.fstat(child_fd)) == signature(info), 'directory changed: ' + name)
                finally:
                    os.close(child_fd)
            else:
                need(stat.S_ISREG(info.st_mode), 'non-regular input: ' + name)
                need(bool(prefix) or child not in TREES, 'tree selector is not a directory: ' + name)
                identity = (info.st_dev, info.st_ino)
                need(identity not in inodes, 'duplicate input inode: ' + name)
                inodes.add(identity)
                need(info.st_size <= limits.file_bytes, 'single-file byte limit exceeded: ' + name)
                total += info.st_size
                need(total <= limits.input_bytes, 'total input byte limit exceeded')
                need(len(files) < limits.files, 'input file count limit exceeded')
                files[name] = signature(info)
                counts[group]['files'] += 1
                counts[group]['bytes'] += info.st_size
    visit(root_fd)
    need(files, 'no selected regular evidence files')
    return files, directories, counts


@contextmanager
def open_member(root_fd, name, expected, limits):
    parts = checked_relative(name, limits)
    parent_fd = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
            os.close(parent_fd)
            parent_fd = next_fd
        # Nonblocking avoids hanging if a file was replaced by a FIFO.
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        with os.fdopen(fd, 'rb') as source:
            need(signature(os.fstat(source.fileno())) == expected, 'file changed before read: ' + name)
            yield source
            need(signature(os.fstat(source.fileno())) == expected, 'file changed during read: ' + name)
    finally:
        os.close(parent_fd)


class HashReader:
    def __init__(self, source):
        self.source = source
        self.hash = hashlib.sha256()
        self.size = 0

    def read(self, size):
        data = self.source.read(size)
        self.hash.update(data)
        self.size += len(data)
        return data


class PartWriter:
    """Bounded streaming sink: no full uncompressed/compressed archive on disk."""
    def __init__(self, stage, limits):
        self.stage, self.limits = stage, limits
        self.parts = []
        self.stream = None
        self.part_hash = None
        self.hash = hashlib.sha256()
        self.size = 0

    def write(self, data):
        need(self.size + len(data) <= self.limits.part_bytes * self.limits.max_parts,
             'compressed archive/part count limit exceeded')
        view = memoryview(data)
        count = len(view)
        while view:
            if self.stream is None:
                index = len(self.parts)
                name = f'qa.tar.gz.part-{index:02d}'
                directory = self.stage / f'part-{index:02d}'
                directory.mkdir()
                self.stream = (directory / name).open('xb')
                self.part_hash = hashlib.sha256()
                self.parts.append({'index': index, 'file': name, 'directory': directory.name, 'size': 0})
            part = self.parts[-1]
            amount = min(len(view), self.limits.part_bytes - part['size'])
            chunk = view[:amount]
            self.stream.write(chunk)
            self.part_hash.update(chunk)
            self.hash.update(chunk)
            self.size += amount
            part['size'] += amount
            view = view[amount:]
            if part['size'] == self.limits.part_bytes:
                self.close()
        return count

    def flush(self):
        if self.stream is not None:
            self.stream.flush()

    def close(self):
        if self.stream is not None:
            self.stream.close()
            self.stream = None
            self.parts[-1]['sha256'] = self.part_hash.hexdigest()


def prepare(input_root, output, source, build, arch, limits=Limits()):
    need(re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', source), 'source must be a full lowercase Git SHA')
    need(re.fullmatch(r'[1-9][0-9]{0,19}', build), 'build must be a positive decimal run number')
    need(arch in ('arm64', 'x86_64'), 'unsupported architecture')
    need(0 < limits.part_bytes <= 8 * MIB and 0 < limits.max_parts <= 8, 'invalid part limits')
    root, output = absolute_path(input_root), absolute_path(output)
    need(output.name == 'qa-parts', 'output directory must be named qa-parts')
    try:
        relative_output = output.relative_to(root)
    except ValueError:
        relative_output = None
    if relative_output is not None:
        need(relative_output.parts == ('qa-parts',), 'output must not nest inside selected evidence')
    with open_directory(root) as root_fd, open_directory(output.parent) as parent_fd:
        need(not os.path.lexists(output), 'output already exists; refusing to overwrite')
        initial_root = os.fstat(root_fd)
        original = inventory(root_fd, limits)
        file_inventory = []
        with tempfile.TemporaryDirectory(prefix='.qa-parts-', dir=output.parent) as temporary:
            stage = Path(temporary)
            writer = PartWriter(stage, limits)
            try:
                with gzip.GzipFile(filename='', mode='wb', compresslevel=6, mtime=0, fileobj=writer) as zipped:
                    with tarfile.open(fileobj=zipped, mode='w|', format=tarfile.PAX_FORMAT) as archive:
                        for name, expected in sorted(original[0].items()):
                            with open_member(root_fd, name, expected, limits) as raw:
                                reader = HashReader(raw)
                                member = tarfile.TarInfo(name)
                                member.size, member.mode, member.mtime = expected[3], 0o644, 0
                                member.uid = member.gid = 0
                                member.uname = member.gname = ''
                                archive.addfile(member, reader)
                                need(reader.size == member.size, 'short input read: ' + name)
                                file_inventory.append({'path': name, 'size': reader.size,
                                                       'sha256': reader.hash.hexdigest()})
            finally:
                writer.close()
            need(inventory(root_fd, limits) == original, 'input inventory changed during packaging')
            # Confirm the root and output parent still refer to the original directories.
            with open_directory(root) as current_root, open_directory(output.parent) as current_parent:
                need((os.fstat(current_root).st_dev, os.fstat(current_root).st_ino) ==
                     (initial_root.st_dev, initial_root.st_ino), 'input root changed')
                need(signature(os.fstat(current_parent)) == signature(os.fstat(parent_fd)),
                     'output parent changed')
            manifest = {
                'schemaVersion': 1, 'purpose': 'transport-only; no acceptance assertion',
                'identity': {'source': source, 'build': build, 'arch': arch, 'authority': 'caller-supplied'},
                'limits': asdict(limits),
                'selection': [{'selector': p, **original[2][p]} for p in SELECTORS],
                'missingSelectors': [p for p in SELECTORS if not original[2][p]['files']],
                'files': file_inventory, 'fileCount': len(file_inventory),
                'inputBytes': sum(item['size'] for item in file_inventory),
                'archive': {'format': 'tar+gzip', 'size': writer.size, 'sha256': writer.hash.hexdigest(),
                            'memberRoot': 'input-directory', 'metadata': 'uid/gid/mtime=0, mode=0644'},
                'parts': writer.parts,
                'reconstruction': 'Concatenate parts in index order; verify part, archive and member SHA256.',
            }
            manifest_bytes = (json.dumps(manifest, sort_keys=True, indent=2, ensure_ascii=True) + '\n').encode()
            need(len(manifest_bytes) <= limits.manifest_bytes, 'manifest byte limit exceeded')
            for part in writer.parts:
                (stage / part['directory'] / 'manifest.json').write_bytes(manifest_bytes)
                # Two files plus ZIP overhead fit comfortably below the transfer cap.
                need(part['size'] + len(manifest_bytes) + 65536 < 32 * MIB, 'artifact transfer budget exceeded')
            need(not os.path.lexists(output), 'output appeared during preparation')
            os.rename(stage, output)
    return manifest


class Once(argparse.Action):
    def __call__(self, parser, namespace, values, option_string=None):
        seen = getattr(namespace, '_seen', set())
        if self.dest in seen:
            raise argparse.ArgumentError(self, 'option must not be repeated')
        seen.add(self.dest)
        namespace._seen = seen
        setattr(namespace, self.dest, values)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--input', default='dist', action=Once)
    parser.add_argument('--output', action=Once, help='new qa-parts directory; default INPUT/qa-parts')
    parser.add_argument('--source', required=True, action=Once)
    parser.add_argument('--build', required=True, action=Once)
    parser.add_argument('--arch', required=True, choices=('arm64', 'x86_64'), action=Once)
    args = parser.parse_args(argv)
    try:
        manifest = prepare(args.input, args.output or Path(args.input) / 'qa-parts',
                           args.source, args.build, args.arch)
    except (PackagingError, OSError, tarfile.TarError) as error:
        print('QA parts preparation failed: ' + str(error), file=sys.stderr)
        return 1
    print(json.dumps({'fileCount': manifest['fileCount'], 'inputBytes': manifest['inputBytes'],
                      'archiveBytes': manifest['archive']['size'], 'archiveSHA256': manifest['archive']['sha256'],
                      'partCount': len(manifest['parts']), 'missingSelectors': manifest['missingSelectors']}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
