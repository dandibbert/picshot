"""Portable tests of the exact embedded synthetic shell; not macOS acceptance.

These do not simulate GIFExportProcessService, AVFoundation, shared admission,
production request validation, or native exit observation. Native XCTest is
required separately. The expected line is input data for the fixture's text
comparison, not a second implementation of the production request encoder.
"""
import os
from pathlib import Path
import select
import subprocess
import tempfile
import textwrap
import time
import unittest


SOURCE = Path(__file__).parents[2] / 'Tests/PicShotTests/VideoTrimGIFFixture.swift'
SCRIPT = textwrap.dedent(SOURCE.read_text().split('static let script = #"""\n', 1)[1].split('    """#', 1)[0])
REQUEST = b'{"fixture":"request text only"}'
PROGRESS = b'{"version":1,"kind":"progress","fraction":0.5}\n'
PAYLOAD = bytes(range(256)) * 3


class Child:
    def __init__(self, expected=REQUEST):
        self.temp = tempfile.TemporaryDirectory(prefix="trim-gif-'quote double\" space-")
        self.root = Path(self.temp.name).resolve()
        self.marker = self.root / 'child.ready'
        self.release = self.root / 'release'
        self.readback = self.root / 'readback.mp4'
        self.source = self.root / 'source.mp4'
        self.source.write_bytes(PAYLOAD)
        self.process = subprocess.Popen(
            ['/bin/bash', '--noprofile', '--norc', '-c', SCRIPT, 'picshot-trim-gif-fixture',
             str(self.marker), str(self.release), str(self.readback), expected.decode()],
            cwd=self.root, env={'LANG': 'C', 'TMPDIR': str(self.root)},
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        os.set_blocking(self.process.stdout.fileno(), False)

    def send(self, data):
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def read(self, seconds=3, count=len(PROGRESS)):
        output = b''
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and len(output) < count:
            ready, _, _ = select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            data = os.read(self.process.stdout.fileno(), 256)
            if not data:
                break
            output += data
            if len(output) > 256:
                raise AssertionError('fixture output must remain bounded')
        return output

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=3)
        for handle in [self.process.stdin, self.process.stdout, self.process.stderr]:
            handle.close()
        self.temp.cleanup()


class VideoTrimGIFFixtureTests(unittest.TestCase):
    def child(self, expected=REQUEST):
        child = Child(expected)
        self.addCleanup(child.close)
        return child

    def ready(self, child, request=REQUEST):
        child.send(request + b'\n')
        self.assertEqual(child.read(), PROGRESS)
        fields = child.marker.read_bytes().split(b'\0')
        self.assertEqual(fields, [str(child.process.pid).encode(), os.fsencode(child.root), b''])
        self.assertIsNone(child.process.poll())

    def test_request_must_be_complete_before_marker_or_progress(self):
        child = self.child()
        child.send(REQUEST)
        self.assertEqual(child.read(seconds=0.05), b'')
        self.assertFalse(child.marker.exists())
        child.send(b'\n{"cancel":true}\n')
        self.assertEqual(child.read(), PROGRESS)
        self.assertFalse(child.readback.exists())
        self.assertEqual(child.read(seconds=0.05), b'')
        child.release.touch()
        self.assertEqual(child.process.wait(timeout=3), 0)
        self.assertEqual(child.readback.read_bytes(), PAYLOAD)

    def test_eof_truncated_empty_and_wrong_requests_fail_without_readiness(self):
        for request in [b'', REQUEST, b'\n', b'{}\n', b'not-json\n']:
            with self.subTest(request=request):
                child = self.child()
                child.send(request)
                child.process.stdin.close()
                self.assertEqual(child.process.wait(timeout=3), 2)
                self.assertEqual(child.read(), b'')
                self.assertFalse(child.marker.exists())
                self.assertFalse(child.readback.exists())

    def test_marker_collision_fails_closed_and_preserves_previous_bytes(self):
        child = self.child()
        child.marker.write_bytes(b'old unowned marker')
        child.send(REQUEST + b'\n')
        self.assertEqual(child.process.wait(timeout=3), 3)
        self.assertEqual(child.read(), b'')
        self.assertEqual(child.marker.read_bytes(), b'old unowned marker')
        self.assertFalse(child.readback.exists())

    def test_marker_directory_fails_without_readiness(self):
        child = self.child()
        child.marker.mkdir()
        child.send(REQUEST + b'\n')
        self.assertEqual(child.process.wait(timeout=3), 3)
        self.assertEqual(child.read(), b'')
        self.assertTrue(child.marker.is_dir())

    def test_matching_request_metacharacters_are_never_evaluated(self):
        expected = b'$(touch must-not-exist); `touch another`; "quoted" \\ slash'
        child = self.child(expected)
        self.ready(child, expected)
        self.assertFalse((child.root / 'must-not-exist').exists())
        self.assertFalse((child.root / 'another').exists())
        child.release.touch()
        self.assertEqual(child.process.wait(timeout=3), 0)
        self.assertEqual(child.readback.read_bytes(), PAYLOAD)

    def test_late_readback_occurs_after_release_and_does_not_replace_existing_file(self):
        child = self.child()
        self.ready(child)
        self.assertFalse(child.readback.exists())
        child.readback.write_bytes(b'old unowned destination')
        child.release.touch()
        self.assertNotEqual(child.process.wait(timeout=3), 0)
        self.assertEqual(child.readback.read_bytes(), b'old unowned destination')

    @unittest.skipUnless(Path('/proc/self/exe').exists(), 'Linux PID inspection; native XCTest covers macOS')
    def test_exec_cat_reads_independent_source_under_same_owned_pid(self):
        child = self.child()
        child.source.unlink()
        os.mkfifo(child.source, 0o600)
        self.ready(child)
        owned_pid = child.process.pid
        child.release.touch()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if Path(os.readlink(f'/proc/{owned_pid}/exe')).name == 'cat':
                break
            time.sleep(0.005)
        self.assertEqual(Path(os.readlink(f'/proc/{owned_pid}/exe')).name, 'cat')
        writer = os.open(child.source, os.O_WRONLY | os.O_NONBLOCK)
        try:
            self.assertEqual(os.write(writer, PAYLOAD), len(PAYLOAD))
        finally:
            os.close(writer)
        self.assertEqual(child.process.wait(timeout=3), 0)
        self.assertEqual(child.process.pid, owned_pid)
        self.assertEqual(child.readback.read_bytes(), PAYLOAD)

    def test_unreleased_child_exits_at_unchanged_twenty_second_bound_without_readback(self):
        started = time.monotonic()
        child = self.child()
        self.ready(child)
        self.assertEqual(child.process.wait(timeout=21), 4)
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, 19)
        self.assertLess(elapsed, 21)
        self.assertEqual(child.read(), b'')
        self.assertFalse(child.readback.exists())


if __name__ == '__main__':
    unittest.main()
