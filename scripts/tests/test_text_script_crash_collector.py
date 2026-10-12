import copy
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import uuid

script = Path(__file__).with_name('collect-text-script-crash.py')
if not script.is_file():
    script = Path(__file__).resolve().parents[1] / 'collect-text-script-crash.py'
spec = importlib.util.spec_from_file_location('collector', script)
C = importlib.util.module_from_spec(spec)
spec.loader.exec_module(C)


class OwnedCrashTests(unittest.TestCase):
    def setUp(self):
        self.binding = {
            'childPID': 321, 'parentPID': 123,
            'expectedProcPath': '/Users/runner/work/gate.app/Contents/Helpers/' + C.NAME,
            'nativeCommandStart': '2026-10-12T22:00:00+00:00',
            'nativeCommandEnd': '2026-10-12T22:00:01+00:00',
            'helperMachOUUID': '7C57278A-6FB8-3796-8200-49A6AB08BDD0',
        }
        self.body = {
            'pid': 321, 'parentPid': 123, 'procName': C.NAME,
            'procPath': self.binding['expectedProcPath'],
            'procLaunch': '2026-10-12 22:00:00.1234 +0000',
            'captureTime': '2026-10-12 22:00:00.1554 +0000',
            'exception': {'type': 'EXC_BREAKPOINT', 'signal': 'SIGTRAP'},
            'termination': {'code': 5, 'namespace': 'SIGNAL'},
            'asi': {'libswiftCore.dylib': ['Fatal error: synthetic owned message']},
            'faultingThread': 0,
            'threads': [{'frames': [{'imageIndex': 0, 'symbol': 'synthetic_function', 'imageOffset': 12}],
                         'threadState': {'registers': ['must not be copied']}}],
            'usedImages': [{'name': C.NAME, 'uuid': self.binding['helperMachOUUID'],
                            'path': self.binding['expectedProcPath'], 'arch': 'arm64', 'base': 999}],
            'userID': 999, 'hardware': 'must not be copied',
        }

    def encoded(self, body=None):
        return (json.dumps({'bug_type': '309', 'app_name': C.NAME}) + '\n' +
                json.dumps(self.body if body is None else body)).encode()

    def test_owned_exact_path_and_bounded_extraction(self):
        body = C.parse_ips(self.encoded())
        self.assertEqual(C.match(body, self.binding), 'exact-pid-process-path-and-time')
        extracted = C.extract(body)
        self.assertEqual(extracted['reasonStatus'], 'observed')
        serialized = json.dumps(extracted)
        for private in ['userID', 'hardware', 'threadState', 'registers', 'base', 'must not be copied']:
            self.assertNotIn(private, serialized)
        self.assertEqual(extracted['imageIdentities'][0]['uuid'], self.binding['helperMachOUUID'])

    def test_foreign_pid_name_parent_and_full_path_rejected(self):
        for field, value in [('pid', 322), ('pid', True), ('procName', 'Other'),
                             ('parentPid', 124), ('procPath', '/foreign/' + C.NAME)]:
            with self.subTest(field=field, value=value):
                body = dict(self.body, **{field: value})
                with self.assertRaises(ValueError):
                    C.match(body, self.binding)

    def test_redacted_path_requires_verified_uuid(self):
        body = copy.deepcopy(self.body)
        body['procPath'] = '/Users/USER/*/gate.app/Contents/Helpers/' + C.NAME
        body['usedImages'][0]['path'] = body['procPath']
        self.assertIn('signed-helper-uuid', C.match(body, self.binding))
        body['usedImages'][0]['uuid'] = str(uuid.uuid4())
        with self.assertRaisesRegex(ValueError, 'without-owned-mach-o-uuid'):
            C.match(body, self.binding)

    def test_run_time_and_bounded_capture_delay(self):
        for field, value in [('procLaunch', '2026-10-12T21:59:59+00:00'),
                             ('procLaunch', '2026-10-12T22:00:02+00:00'),
                             ('captureTime', '2026-10-12T22:00:17+00:00'),
                             ('captureTime', '2026-10-12T22:00:00+00:00'),
                             ('captureTime', '2026-10-12T22:00:01')]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                C.match(dict(self.body, **{field: value}), self.binding)
        self.assertTrue(C.match(dict(self.body, captureTime='2026-10-12T22:00:15+00:00'), self.binding))

    def test_malformed_ambiguous_and_non_crash_json(self):
        for data in [b'garbage', b'{}\n{', b'{}\n{}',
                     b'{"bug_type":"309"}\n{"pid":321,"pid":322}',
                     b'{"bug_type":"309"}\n{"pid":NaN}']:
            with self.subTest(data=data), self.assertRaises(ValueError):
                C.parse_ips(data)

    def test_oversized_and_symlink_files_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            path = root / 'report.ips'
            path.write_bytes(b'x' * 1025)
            with self.assertRaises(ValueError):
                C.read(path, 1024)
            link = root / 'link.ips'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                C.read(link, 2048)
            (root / 'linked-directory').symlink_to(root, target_is_directory=True)
            with self.assertRaises(OSError):
                C.read(root / 'linked-directory/report.ips', 2048)

    def test_signed_thin_mach_o_uuid(self):
        header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 24, 0, 0)
        data = header + struct.pack('<II', 0x1b, 24) + uuid.UUID(self.binding['helperMachOUUID']).bytes
        self.assertEqual(C.macho_uuid(data), self.binding['helperMachOUUID'])
        for malformed in [b'', data[:-1], data[:16] + struct.pack('<I', 2) + data[20:]]:
            with self.assertRaises(ValueError):
                C.macho_uuid(malformed)

    def test_missing_reason_is_explicit_and_output_is_bounded(self):
        self.assertEqual(C.extract({'threads': [], 'usedImages': []})['reasonStatus'], 'absent')
        body = copy.deepcopy(self.body)
        body['asi'] = {str(i): ['😀' * 10000] * 100 for i in range(100)}
        body['threads'][0]['frames'] *= 100
        result = C.extract(body)
        self.assertTrue(result['crashedThread']['framesTruncated'])
        self.assertEqual(len(result['crashedThread']['frames']), 32)
        self.assertLess(len(json.dumps(result).encode()), C.OUTPUT_LIMIT)


if __name__ == '__main__':
    unittest.main()
