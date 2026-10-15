#!/usr/bin/env python3
"""Deterministic negative checks; no macOS app or native memory tool is invoked."""
import copy
import ctypes
import errno
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('original227_observer', ROOT / 'observe-original227-allocations.py')
O = importlib.util.module_from_spec(spec)
spec.loader.exec_module(O)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.token = '71dfbb14-76ac-458f-bb57-19c9a92b430d'
        self.launch = dict(appPID=1234, appLaunchEpochSeconds=100.5,
            executablePath='/owned/PicShot.app/Contents/MacOS/PicShot', executableSHA256='a' * 64)
        self.environment = {'MallocStackLogging': 'full', 'MallocStackLoggingNoCompact': '1',
                            'MallocStackLoggingDirectory': '/owned-volume/stack-logs'}
        self.request = dict(schemaVersion=1, protocol=O.PROTOCOL, runToken=self.token, sequence=1,
            requestID='6cda1d82-7a31-4da7-98c7-e06a7a3facb5', kind='calibration-live', cycleOrdinal=0,
            phase='calibration-owned-allocation-live', identity=dict(pid=1234,
                processStartEpochSeconds=100.5, processStartUptimeSeconds=1.0,
                executablePath=self.launch['executablePath'], executableSHA256='a' * 64),
            publishedUptimeSeconds=10.0, replyDeadlineUptimeSeconds=25.0, maximumHoldSeconds=15,
            fixtureDeadlineUptimeSeconds=580.0, mainActorBlocked=True,
            perturbationLabel='Diagnostic main actor hold', mallocEnvironment=self.environment,
            calibration=dict(address='0x10000', requestedBytes=65537, usableBytes=65552))

    def validate(self, request=None, now=11.0):
        return O.validate_request(request or self.request, 1, self.token, self.launch, self.environment, now)

    def test_accepts_exact_protocol_and_rejects_wrong_pid_or_token_before_probe(self):
        self.assertAlmostEqual(self.validate(), 24.88)
        for field, value in [('pid', 1235), ('executableSHA256', 'b' * 64),
                             ('processStartEpochSeconds', 101.0)]:
            request = copy.deepcopy(self.request)
            request['identity'][field] = value
            with self.subTest(field=field), self.assertRaises(O.ProbeError):
                self.validate(request)
        request = copy.deepcopy(self.request)
        request['runToken'] = 'different-run'
        with self.assertRaises(O.ProbeError):
            self.validate(request)

    def test_rejects_unknown_fields_bool_pid_future_and_late_request(self):
        mutations = [('unknown', 1), ('maximumHoldSeconds', 16),
                     ('publishedUptimeSeconds', float('nan')), ('mainActorBlocked', 1),
                     ('sequence', True)]
        for key, value in mutations:
            request = copy.deepcopy(self.request)
            request[key] = value
            with self.subTest(key=key), self.assertRaises(O.ProbeError):
                self.validate(request)
        with self.assertRaises(O.ProbeError):
            self.validate(now=25)
        request = copy.deepcopy(self.request)
        request['identity']['pid'] = True
        with self.assertRaises(O.ProbeError):
            self.validate(request)

    def test_reply_is_exact_bound_and_safe_error_only(self):
        reply = O.reply_for(self.request, 'ok')
        self.assertEqual(reply['identity'], self.request['identity'])
        self.assertEqual(reply['runToken'], self.token)
        self.assertEqual(reply['errorCode'], '')
        for status, error in [('continue', ''), ('ok', 'failed'), ('failed', '/private/path'), ('failed', '')]:
            with self.subTest(status=status, error=error), self.assertRaises(O.ProbeError):
                O.reply_for(self.request, status, error)

    def test_private_json_rejects_symlink_hardlink_duplicate_and_nonfinite(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            path = root / 'request.json'
            O.atomic_json(path, self.request)
            self.assertEqual(path.stat().st_nlink, 1)
            self.assertEqual(O.read_json(path), self.request)
            alias = root / 'alias'
            alias.symlink_to(path)
            with self.assertRaises(OSError):
                O.read_json(alias)
            alias.unlink()
            os.link(path, alias)
            with self.assertRaises(O.ProbeError):
                O.read_json(path)
            alias.unlink()
            for data in ['{"a":1,"a":2}', '{"a":NaN}']:
                path.write_text(data)
                with self.assertRaises(O.ProbeError):
                    O.read_json(path)

    def test_stale_no_app_lifecycle_cannot_authorize_volume_detach(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'measure').mkdir()
            observer = O.Observer.__new__(O.Observer)
            observer.native = None
            observer.launcher = object()
            observer.token = self.token
            observer.args = SimpleNamespace(resource_root=root, app=Path('/owned/PicShot.app'),
                executable=Path(self.launch['executablePath']))
            report = dict(status='launch-failed', callbackReceived=True,
                selectedAppPath=str(observer.args.app), expectedExecutablePath=str(observer.args.executable),
                allocationDiagnostic=dict(enabled=True, protocol=O.PROTOCOL, runToken='stale-token'))
            path = root / 'measure' / 'summary.json.launcher.json'
            path.write_text(json.dumps(report))
            self.assertFalse(observer.app_retired())
            report['allocationDiagnostic']['runToken'] = self.token
            path.write_text(json.dumps(report))
            self.assertTrue(observer.app_retired())
            report['selectedAppPath'] = '/another/PicShot.app'
            path.write_text(json.dumps(report))
            self.assertFalse(observer.app_retired())

    def test_native_permission_denial_is_terminal_without_retry(self):
        calls = []
        def denied(*args):
            calls.append(args[0])
            ctypes.set_errno(errno.EPERM)
            return 0
        identity = O.DarwinIdentity.__new__(O.DarwinIdentity)
        identity.denied_pids = set()
        identity.lib = SimpleNamespace(proc_pidinfo=denied)
        for _ in range(2):
            with self.assertRaisesRegex(O.ProbeError, 'native-identity-access-denied'):
                identity(1234)
        self.assertEqual(calls, [1234])

    def test_native_birth_and_executable_mismatch_reject_launch(self):
        native = dict(pid=1234, parentPID=1, uid=os.getuid(), groupID=1234,
            birthSeconds=100, birthMicroseconds=500000, executablePath=self.launch['executablePath'])
        launcher_native = dict(pid=4321, parentPID=os.getpid(), uid=os.getuid(), groupID=4321,
            birthSeconds=99, birthMicroseconds=0, executablePath='/usr/bin/swift')
        launch = dict(schemaVersion=1, protocol=O.PROTOCOL, runToken=self.token, launcherPID=4321,
            launcherStartEpochSeconds=99, selectedAppPath='/owned/PicShot.app', **self.launch)
        args = [launch, self.token, 4321, Path('/owned/PicShot.app'),
                Path(self.launch['executablePath']), 'a' * 64, native, launcher_native]
        O.validate_launch(*args)
        for key, value in [('birthMicroseconds', 1), ('executablePath', '/elsewhere/PicShot'), ('uid', -1)]:
            bad = copy.deepcopy(native)
            bad[key] = value
            if key == 'birthMicroseconds':
                bad['birthSeconds'] = 102
            with self.subTest(key=key), self.assertRaises(O.ProbeError):
                O.validate_launch(*(args[:6] + [bad, launcher_native]))


class EvidenceTests(unittest.TestCase):
    def test_capacity_cannot_be_claimed_from_logical_image_size_or_wrong_device(self):
        good = [SimpleNamespace(st_dev=3), SimpleNamespace(st_dev=2), SimpleNamespace(st_dev=1),
                SimpleNamespace(f_blocks=65536, f_frsize=4096), 250 * O.MIB, True, 249 * O.MIB]
        self.assertEqual(O.capacity_receipt(*good)['statfsTotalBytes'], 256 * O.MIB)
        replacements = [(0, SimpleNamespace(st_dev=1)), (0, SimpleNamespace(st_dev=2)),
            (3, SimpleNamespace(f_blocks=65537, f_frsize=4096)), (5, False), (4, 0), (6, 0)]
        for index, value in replacements:
            args = good.copy()
            args[index] = value
            with self.subTest(index=index), self.assertRaises(O.ProbeError):
                O.capacity_receipt(*args)

    def test_heap_candidates_cover_different_sizes_and_disappeared_addresses(self):
        allocations = O.heap_allocations('0x10000: malloc in atexit_register (1280 bytes)\n'
            '0x20000 (size = 4177920): unknown\n0x30000 (73728 bytes): unknown\n')
        self.assertEqual(allocations[0x10000], 1280)
        selected = O.select_candidates(allocations, {0x40000: 98304}, set())
        self.assertEqual(selected[0]['selection'], 'disappeared-large-address')
        self.assertEqual(selected[0]['address'], '0x40000')
        self.assertEqual(selected[1]['bytes'], 4177920)
        selected = O.select_candidates(allocations, {}, set())
        self.assertEqual({item['bytes'] for item in selected}, {4177920, 73728})
        with self.assertRaises(O.ProbeError):
            O.heap_allocations('0x10000: pointer but no size\n')
        with self.assertRaises(O.ProbeError):
            O.heap_allocations('0x10000: pointer but no size\n0x20000 (size = 65537): malloc\n')

    def test_history_requires_alloc_and_free_for_same_pointer_size_and_real_stack(self):
        frame = '\n    0 PicShot 0x100001000 allocationCalibration + 80\n    1 libsystem_malloc.dylib 0x100002000 malloc + 32\n'
        alloc = 'ALLOC 0x10000-0x20000 [size=65537]: thread 0x1' + frame
        free = 'FREE 0x10000-0x20000 [size=65537]: thread 0x1' + frame
        self.assertEqual(len(O.validate_history(alloc + free, 0x10000, freed=True, calibration=True)), 2)
        self.assertEqual(len(O.validate_history(alloc + free.replace('size=65537', 'size=0'), 0x10000, freed=True, calibration=True)), 2)
        for invalid in [alloc, free + alloc, alloc + alloc.replace('size=65537', 'size=70000') + free, alloc + free.replace('0x10000-', '0x30000-'),
                        (alloc + free).replace('size=65537', 'size=65536'),
                        (alloc + free).replace('PicShot', 'UnknownBinary'),
                        (alloc + free).replace(frame, '\n')]:
            with self.subTest(text=invalid[:80]), self.assertRaises(O.ProbeError):
                O.validate_history(invalid, 0x10000, freed=True, calibration=True)

    def test_vmmap_must_locate_calibration_address(self):
        O.validate_vmmap('MALLOC 0000000000010000-0000000000021000', 0x10000)
        with self.assertRaises(O.ProbeError):
            O.validate_vmmap('MALLOC 0000000000030000-0000000000041000', 0x10000)

    def test_vmmap_process_summary_does_not_prove_per_region_pages(self):
        summary = 'REGION TYPE START - END [ VSIZE ]\nPhysical footprint: 100 MB\nReusable: 40 MB\n'
        self.assertEqual(O.vmmap_page_columns(summary)['perRegionReusableAttribution'], 'unsupported-inconclusive')
        columns = 'REGION TYPE START - END [ VSIZE RSDNT DIRTY SWAP REUSABLE ]'
        self.assertEqual(O.vmmap_page_columns(columns)['perRegionReusableAttribution'], 'requires-analysis')

    def test_malloc_settings_are_never_inherited_by_probes_or_interpreter(self):
        clean = O.clean_environment({'MallocStackLogging': 'full', 'MallocFoo': 'x', 'PATH': '/bin'})
        self.assertFalse(any(key.startswith('Malloc') for key in clean))
        self.assertEqual(clean['PATH'], '/bin')

    def test_lsof_owned_path_device_and_pid_are_all_required(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            logs = root / 'stack-logs'
            logs.mkdir()
            path = logs / 'stack-logs.1234.index'
            path.write_bytes(b'x')
            device = path.stat().st_dev
            valid = f'p1234\0\nf3\0tREG\0D{hex(device)}\0n{path}\0\n'
            result = O.stack_log_descriptors(valid, 1234, logs, device)
            self.assertEqual(result[0]['fileDescriptor'], 3)
            other = root / 'stack-logs.1234.outside'
            other.write_bytes(b'x')
            invalid = [valid.replace('p1234', 'p1235'), valid.replace(str(path), str(other)),
                       valid.replace(hex(device), hex(device + 1)), valid.replace('f3', 'fmem'),
                       valid.replace('tREG\0', ''), valid.replace('D' + hex(device), 'D' + hex(device) + '\0D' + hex(device)), valid + valid]
            for data in invalid:
                with self.subTest(data=data[:60]), self.assertRaises(O.ProbeError):
                    O.stack_log_descriptors(data, 1234, logs, device)
            private = valid + 'f4\0tREG\0D0x1\0n/private/unrelated-customer-file\0\n'
            self.assertNotIn('unrelated-customer', json.dumps(O.stack_log_descriptors(private, 1234, logs, device)))



class BoundedChildTests(unittest.TestCase):
    def run_child(self, code, cap=4096, seconds=2):
        with tempfile.TemporaryDirectory() as root:
            budget = O.TextBudget(Path(root))
            runner = O.NativeCommands(budget)
            started = time.monotonic()
            error = None
            try:
                runner.run([sys.executable, '-c', code], started + seconds, 'child.txt', cap=cap)
            except O.ProbeError as caught:
                error = str(caught)
            return error, runner.records, time.monotonic() - started, budget.retained

    def test_noisy_child_is_killed_with_cap_not_unbounded_capture(self):
        error, records, elapsed, retained = self.run_child('import os\nwhile True: os.write(1,b"x"*65536)')
        self.assertEqual(error, 'native-tool-output-cap')
        self.assertTrue(records[0]['cleanupConfirmed'])
        self.assertLessEqual(records[0]['observedBytes'], 4097)
        self.assertEqual(retained, 0)
        self.assertLess(elapsed, 3)

    def test_term_resistant_child_and_pipe_holding_descendant_are_retired(self):
        error, records, elapsed, _ = self.run_child('import signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(30)', seconds=1.2)
        self.assertEqual(error, 'native-tool-timeout')
        self.assertTrue(records[0]['cleanupConfirmed'])
        self.assertLess(elapsed, 2.2)
        child = 'import os,time\npid=os.fork()\nif pid: os._exit(0)\ntime.sleep(30)'
        error, records, elapsed, _ = self.run_child(child, seconds=1.2)
        self.assertEqual(error, 'native-tool-timeout')
        self.assertTrue(records[0]['cleanupConfirmed'])
        self.assertLess(elapsed, 2.2)

    def test_cleanup_observation_failure_retains_failed_child_record(self):
        real = O.bounded_module()
        class FailedObservation(real.ProcessGroup):
            def alive(self):
                raise RuntimeError('simulated descendant observation failure')
        with tempfile.TemporaryDirectory() as root:
            runner = O.NativeCommands(O.TextBudget(Path(root)),
                                      SimpleNamespace(ProcessGroup=FailedObservation))
            with self.assertRaises((RuntimeError, O.ProbeError)):
                runner.run([sys.executable, '-c', 'print("owned")'],
                           time.monotonic() + 2, 'child.txt')
            self.assertEqual(len(runner.records), 1)
            self.assertFalse(runner.records[0]['cleanupConfirmed'])
            self.assertEqual(runner.records[0]['failure'], 'native-tool-cleanup-observation-failed')

    def test_launcher_cleanup_cannot_grow_overflowed_buffer(self):
        launcher = O.OwnedLauncher.__new__(O.OwnedLauncher)
        launcher.data = bytearray(b'x' * (O.MIB + 1))
        launcher.eof = False
        launcher.process = SimpleNamespace(stdout=SimpleNamespace(fileno=lambda: 7))
        with patch.object(O.os, 'read', return_value=b'y' * 65536):
            for _ in range(20):
                with self.assertRaises(O.ProbeError):
                    launcher.drain()
        self.assertEqual(len(launcher.data), O.MIB + 1)

    def test_permission_denied_text_is_never_success(self):
        error, records, _, retained = self.run_child('print("Operation not permitted")')
        self.assertEqual(error, 'native-tool-access-or-logging-failure')
        self.assertTrue(records[0]['cleanupConfirmed'])
        self.assertGreater(retained, 0)


if __name__ == '__main__':
    unittest.main()
