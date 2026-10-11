import contextlib
from dataclasses import replace
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile


SCRIPT = Path(__file__).parents[1] / 'prepare-qa-parts.py'
SPEC = importlib.util.spec_from_file_location('prepare_qa_parts', SCRIPT)
P = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = P
SPEC.loader.exec_module(P)


class QAPartTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.input = self.root / 'dist'
        self.input.mkdir()
        self.output = self.input / 'qa-parts'
        self.source = 'a' * 40

    def put(self, name, data=b'test\x00\xff\n'):
        path = self.input / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def prepare(self, **kwargs):
        return P.prepare(self.input, kwargs.pop('output', self.output), self.source, '214', 'arm64', **kwargs)

    def assert_unpublished(self):
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.input.glob('.qa-parts-*')), [])

    def reconstruct(self, manifest, output=None):
        output = output or self.output
        common = None
        archive = b''
        for index, part in enumerate(manifest['parts']):
            directory = output / f'part-{index:02d}'
            self.assertEqual(part['index'], index)
            self.assertEqual(part['directory'], directory.name)
            self.assertEqual(set(p.name for p in directory.iterdir()), {'manifest.json', part['file']})
            data = (directory / part['file']).read_bytes()
            self.assertEqual(len(data), part['size'])
            self.assertLessEqual(len(data), manifest['limits']['part_bytes'])
            self.assertEqual(hashlib.sha256(data).hexdigest(), part['sha256'])
            raw_manifest = (directory / 'manifest.json').read_bytes()
            self.assertEqual(json.loads(raw_manifest), manifest)
            self.assertEqual(raw_manifest, common or raw_manifest)
            common = raw_manifest
            archive += data
        self.assertEqual(len(archive), manifest['archive']['size'])
        self.assertEqual(hashlib.sha256(archive).hexdigest(), manifest['archive']['sha256'])
        return archive

    def test_exact_reconstruction_inventory_hashes_and_upload_scope(self):
        expected = {
            'build.log': b'\x00\xff\n\r\x80',
            'test-report.json': b'{"status":"failed"}\n',
            'native-tests-plan.json': b'{}',
            'native-test-shards/shard-00.log': b'shard',
            'focused-test-shards/shard-01-report.json': b'report',
            'evidence/nested/image.rgba': bytes(range(256)) * 5,
            'evidence/' + 'long-name-' * 15 + '.json': b'pax path',
            'evidence/empty-file': b'',
        }
        for name, data in expected.items():
            self.put(name, data)
        for name in ('Sources/secret.swift', 'PicShot.dmg', 'PicShot.zip', 'credentials.txt',
                     '.env', 'ordinary.json', 'other/ignored.log'):
            self.put(name, b'excluded')
        limits = replace(P.Limits(), part_bytes=400)
        manifest = self.prepare(limits=limits)
        packed = self.reconstruct(manifest)
        self.assertGreater(len(manifest['parts']), 1)
        self.assertEqual(manifest['missingSelectors'], [])
        self.assertEqual(manifest['fileCount'], len(expected))
        self.assertEqual(manifest['inputBytes'], sum(map(len, expected.values())))
        self.assertEqual(manifest['identity'], {'source': self.source, 'build': '214', 'arch': 'arm64',
                                                'authority': 'caller-supplied'})
        self.assertEqual(manifest['purpose'], 'transport-only; no acceptance assertion')
        self.assertEqual([f['path'] for f in manifest['files']], sorted(expected))
        with tarfile.open(fileobj=io.BytesIO(packed), mode='r:gz') as archive:
            self.assertEqual(archive.getnames(), sorted(expected))
            for member, record in zip(archive.getmembers(), manifest['files']):
                self.assertTrue(member.isfile())
                self.assertEqual((member.uid, member.gid, member.mtime, member.mode), (0, 0, 0, 0o644))
                self.assertEqual(archive.extractfile(member).read(), expected[member.name])
                self.assertEqual(record['size'], len(expected[member.name]))
                self.assertEqual(record['sha256'], hashlib.sha256(expected[member.name]).hexdigest())
        # Gzip has no original filename or timestamp; bytes remain original on disk.
        self.assertEqual(packed[3:8], b'\x00' * 5)
        for name, data in expected.items():
            self.assertEqual((self.input / name).read_bytes(), data)

    def test_repeated_packaging_is_byte_deterministic_despite_modes_and_timestamps(self):
        file = self.put('build.log', b'consistent bytes')
        one = self.prepare()
        packed_one = self.reconstruct(one)
        os.chmod(file, 0o600)
        os.utime(file, (42, 42))
        external = self.root / 'second'
        external.mkdir()
        output = external / 'qa-parts'
        two = self.prepare(output=output)
        self.assertEqual(self.reconstruct(two, output), packed_one)
        self.assertEqual(one, two)

    def test_partial_failure_evidence_records_empty_and_missing_selectors(self):
        self.put('early-failure.log', b'failed before tests')
        (self.input / 'evidence').mkdir()
        manifest = self.prepare()
        self.assertEqual(manifest['missingSelectors'], list(P.SELECTORS[1:]))
        self.assertEqual(manifest['fileCount'], 1)
        self.assertEqual(manifest['selection'][0], {'selector': '*.log', 'files': 1, 'bytes': 19})

    def test_empty_input_rejected_even_with_unselected_files(self):
        self.put('PicShot.dmg')
        with self.assertRaisesRegex(P.PackagingError, 'no selected'):
            self.prepare()
        self.assert_unpublished()

    def test_split_boundaries_and_maximum_exactly_eight_parts(self):
        for size in (0, 1, 15, 16, 17, 127, 128):
            with self.subTest(size=size), tempfile.TemporaryDirectory(dir=self.root) as temporary:
                writer = P.PartWriter(Path(temporary), replace(P.Limits(), part_bytes=16))
                payload = bytes(range(size))
                for offset in range(0, size, 7):
                    writer.write(payload[offset:offset + 7])
                writer.close()
                self.assertEqual(len(writer.parts), (size + 15) // 16)
                self.assertEqual(writer.size, size)
                result = b''.join((Path(temporary) / p['directory'] / p['file']).read_bytes()
                                  for p in writer.parts)
                self.assertEqual(result, payload)
                self.assertTrue(all(0 < p['size'] <= 16 for p in writer.parts))
                if size == 128:
                    with self.assertRaisesRegex(P.PackagingError, 'archive/part count'):
                        writer.write(b'x')
                    self.assertEqual(writer.size, 128)

    def test_size_count_and_path_limits_fail_without_published_output(self):
        self.put('a.log', b'1234')
        self.put('b.log', b'12345')
        cases = [('single-file', {'file_bytes': 4}), ('total input', {'input_bytes': 8}),
                 ('file count', {'files': 1}), ('entry limit', {'entries': 1}),
                 ('path limit', {'path_bytes': 4}), ('manifest byte', {'manifest_bytes': 1}),
                 ('archive/part count', {'part_bytes': 1})]
        for message, changes in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(P.PackagingError, message):
                    self.prepare(limits=replace(P.Limits(), **changes))
                self.assert_unpublished()

    def test_limit_boundaries_are_inclusive(self):
        self.put('a.log', b'1234')
        self.put('b.log', b'12345')
        manifest = self.prepare(limits=replace(P.Limits(), file_bytes=5, input_bytes=9,
                                               files=2, path_bytes=5))
        self.assertEqual(manifest['inputBytes'], 9)

    def test_member_paths_are_relative_unambiguous_and_bounded(self):
        for name in ('', '/etc/passwd', '../secret', 'a/../b', './a.log', 'a//b', 'a/',
                     'C:/escape.log', 'C:\\escape.log', 'a\n.log', '.env', 'evidence/.git/config'):
            with self.subTest(name=name), self.assertRaises(P.PackagingError):
                P.checked_relative(name, P.Limits())
        with self.assertRaisesRegex(P.PackagingError, 'path limit'):
            P.checked_relative('evidence/a/b', replace(P.Limits(), path_depth=2))
        self.put('evidence/bad\n.log')
        with self.assertRaisesRegex(P.PackagingError, 'unsafe member'):
            self.prepare()
        self.assert_unpublished()

    def test_symlink_file_and_directory_are_rejected_without_following(self):
        secret = self.root / 'secret'
        secret.write_bytes(b'private')
        for name, target in [('read.log', secret), ('evidence', self.root), ('missing.log', self.root / 'absent')]:
            link = self.input / name
            link.symlink_to(target)
            with self.subTest(name=name), self.assertRaisesRegex(P.PackagingError, 'symlink'):
                self.prepare()
            self.assert_unpublished()
            link.unlink()

    def test_root_and_ancestor_symlinks_and_output_escape_are_rejected(self):
        self.put('a.log')
        link = self.root / 'link'
        link.symlink_to(self.input, target_is_directory=True)
        with self.assertRaises(OSError):
            P.prepare(link, self.output, self.source, '214', 'arm64')
        nested = self.input / 'nested'
        nested.mkdir()
        with self.assertRaises(OSError):
            P.prepare(link / 'nested', self.output, self.source, '214', 'arm64')
        with self.assertRaisesRegex(P.PackagingError, 'escaping filesystem'):
            P.prepare(self.input / '..' / 'dist', self.output, self.source, '214', 'arm64')
        with self.assertRaisesRegex(P.PackagingError, 'must not nest'):
            self.prepare(output=self.input / 'evidence' / 'qa-parts')
        self.assert_unpublished()

    def test_duplicates_hardlinks_and_casefold_aliases_are_rejected(self):
        file = self.put('one.log')
        os.link(file, self.input / 'two.log')
        with self.assertRaisesRegex(P.PackagingError, 'duplicate input inode'):
            self.prepare()
        (self.input / 'two.log').unlink()
        second = self.input / 'ONE.log'
        second.write_bytes(b'other')
        if os.stat(second).st_ino != os.stat(file).st_ino:
            with self.assertRaisesRegex(P.PackagingError, 'duplicate/ambiguous'):
                self.prepare()
        self.assert_unpublished()

    def test_nonregular_input_and_wrong_selector_types_are_rejected(self):
        fifo = self.input / 'fifo.log'
        os.mkfifo(fifo)
        with self.assertRaisesRegex(P.PackagingError, 'non-regular'):
            self.prepare()
        fifo.unlink()
        (self.input / 'wrong.log').mkdir()
        with self.assertRaisesRegex(P.PackagingError, 'matched a directory'):
            self.prepare()
        (self.input / 'wrong.log').rmdir()
        self.put('evidence')
        with self.assertRaisesRegex(P.PackagingError, 'not a directory'):
            self.prepare()
        self.assert_unpublished()

    def test_file_mutation_before_during_and_after_read_is_rejected(self):
        first = self.put('a.log', b'original')
        self.put('b.log', b'second')
        real_open = P.open_member
        real_read = P.HashReader.read
        for timing in ('before', 'during', 'after'):
            first.write_bytes(b'original')
            triggered = False

            @contextlib.contextmanager
            def changing_open(root_fd, name, expected, limits):
                nonlocal triggered
                if timing == 'before' and name == 'a.log':
                    first.write_bytes(b'mutated!')
                elif timing == 'after' and name == 'b.log':
                    first.write_bytes(b'mutated!')
                with real_open(root_fd, name, expected, limits) as stream:
                    yield stream

            def changing_read(reader, amount):
                nonlocal triggered
                data = real_read(reader, amount)
                if timing == 'during' and not triggered:
                    first.write_bytes(b'mutated!')
                    triggered = True
                return data

            with self.subTest(timing=timing), mock.patch.object(P, 'open_member', changing_open), \
                    mock.patch.object(P.HashReader, 'read', changing_read):
                with self.assertRaisesRegex(P.PackagingError, 'changed'):
                    self.prepare()
                self.assert_unpublished()

    def test_added_file_and_file_replaced_by_symlink_are_rejected(self):
        path = self.put('a.log')
        original = P.open_member

        @contextlib.contextmanager
        def add_after(root_fd, name, expected, limits):
            with original(root_fd, name, expected, limits) as stream:
                yield stream
            self.put('new-report.json')

        with mock.patch.object(P, 'open_member', add_after):
            with self.assertRaisesRegex(P.PackagingError, 'inventory changed'):
                self.prepare()
        self.assert_unpublished()
        (self.input / 'new-report.json').unlink()

        @contextlib.contextmanager
        def link_before(root_fd, name, expected, limits):
            path.unlink()
            path.symlink_to(self.root / 'unreadable')
            with original(root_fd, name, expected, limits) as stream:
                yield stream

        with mock.patch.object(P, 'open_member', link_before):
            with self.assertRaises(OSError):
                self.prepare()
        self.assert_unpublished()

    def test_existing_output_and_output_symlink_are_never_overwritten(self):
        self.put('a.log')
        self.output.mkdir()
        marker = self.output / 'keep'
        marker.write_bytes(b'preserved')
        with self.assertRaisesRegex(P.PackagingError, 'already exists'):
            self.prepare()
        self.assertEqual(marker.read_bytes(), b'preserved')
        marker.unlink()
        self.output.rmdir()
        self.output.symlink_to(self.root / 'absent')
        with self.assertRaisesRegex(P.PackagingError, 'already exists'):
            self.prepare()

    def test_identity_and_cli_reject_unknown_abbreviated_and_duplicate_arguments(self):
        self.put('a.log')
        for source, build, arch in [('bad', '214', 'arm64'), (self.source, '214/evil', 'arm64'),
                                    (self.source, '214', 'aarch64')]:
            with self.subTest(source=source, build=build, arch=arch), self.assertRaises(P.PackagingError):
                P.prepare(self.input, self.output, source, build, arch)
        base = [sys.executable, str(SCRIPT), '--input', str(self.input), '--source', self.source,
                '--build', '214', '--arch', 'arm64']
        for extra in (['--extra', '1'], ['--max-parts', '9'], ['--sour', self.source],
                      ['--build', '215'], ['unexpected-positional']):
            result = subprocess.run(base + extra, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assert_unpublished()
        result = subprocess.run(base, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['fileCount'], 1)

    def test_default_part_with_manifest_has_bounded_zip_transfer_size(self):
        self.put('a.log', b'\x00' * 128)
        manifest = self.prepare()
        directory = self.output / manifest['parts'][0]['directory']
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as uploaded:
            for path in sorted(directory.iterdir()):
                uploaded.writestr(path.name, path.read_bytes())
        self.assertLess(len(archive.getvalue()), 32 * P.MIB)
        self.assertLess(P.Limits().part_bytes + P.Limits().manifest_bytes + 65536, 32 * P.MIB)


if __name__ == '__main__':
    unittest.main()
