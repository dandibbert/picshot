"""Synthetic checker unit inputs, never native renderings or release evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

SCRIPT = Path(__file__).resolve().parents[1] / 'check-recording-transport-report.py'
SPEC = importlib.util.spec_from_file_location('transport_check', SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def rect(x, y, width, height):
    return dict(x=x, y=y, width=width, height=height)


def ownership(probes):
    return dict(status='passed', weakProbeCount=probes, retainedObjects=0, releaseMilliseconds=2, deadlineMilliseconds=3000)


def unit_png(value, width=300, height=40):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    raster = (b'\0' + bytes([value, value, value, 255]) * width) * height
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raster)) + chunk(b'IEND', b''))


class RecordingTransportCheckerTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix='transport-check-unit-')
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.report = dict(status='passed', phase='complete', interactionRoute='NSButton.performClick',
            hitTestRoute='NSView.hitTest', dragRoute='local NSView mouseDown/mouseDragged/mouseUp',
            recordingStarted=False, permissionRequested=False, globalInputPosted=False,
            nativeMonitorRegistrations=0, productionTimers=0, productionObservers=0,
            captureExclusion='sharingType.none asserted; physical ScreenCaptureKit exclusion not tested',
            snapshotPixelsPerPoint=1, contentWidthPoints=300, contentHeightPoints=40,
            appearances=[], placement=[], retirementCycles=8, repeatedRetirement=ownership(64))
        for theme, color in [('light', 250), ('dark', 44)]:
            before = rect(300, 300, 300, 40)
            appearance = dict(status='passed', appearance=theme, states=[], ownership=ownership(9),
                initialPauseCalls=2, initialStopCalls=1, replacementStopCalls=1, replacementExpandCalls=1,
                busyStopVerified=True, replacementActionsVerified=True, shortcutUpdatesVerified=True,
                expandHideRestoreVerified=True, retiredActionsVerified=True,
                drag=dict(status='passed', visibleFrame=rect(0, 24, 1280, 776), before=before,
                    afterGrip=rect(337, 279, 300, 40), afterClamp=rect(980, 24, 300, 40),
                    buttonDragDidNotMove=True, hideCancelledDrag=True, regionMutationAvailable=False))
            for state in ['recording', 'paused', 'saving', 'error']:
                stem = f'recording-transport-{state}-{theme}'
                appearance['states'].append(dict(state=state, file=stem + '.png', geometryFile=stem + '-geometry.json',
                    layoutStatus='passed', hitTestStatus='passed', pauseEnabled=state in ['recording', 'paused'], stopEnabled=state != 'saving'))
                (self.root / (stem + '.png')).write_bytes(unit_png(color))
                controls = [('grip', rect(4, 4, 20, 32)), ('elapsed', rect(47, 20, 141, 16)),
                    ('status', rect(47, 5, 141, 14)), ('pauseResume', rect(192, 4, 32, 32)),
                    ('stopSave', rect(228, 4, 32, 32)), ('expand', rect(264, 4, 32, 32))]
                raw = dict(status='measured-before-validation', windowFrame=before, contentBounds=rect(0, 0, 300, 40),
                    coordinateSystem='AppKit bottom-left', controls=[dict(identifier='recording.transport.' + name, frame=frame, hidden=False)
                    for name, frame in controls])
                (self.root / (stem + '-geometry.json')).write_text(json.dumps(raw))
            self.report['appearances'].append(appearance)
        for x, y, w, h in [(0, 24, 1280, 776), (-1920, -480, 1920, 1056), (-600, 900, 180, 400)]:
            anchors = [rect(x, y, w, h), rect(x, y, 40, 40), rect(x + w - 10, y + h - 10, 10, 10)]
            initial_frames = [rect(x + (w - min(300, w)) / 2, y, min(300, w), 40),
                              rect(x, y + 48, min(300, w), 40), rect(x + w - min(300, w), y + h - 58, min(300, w), 40)]
            for anchor, initial in zip(anchors, initial_frames):
                self.report['placement'].append(dict(visibleFrame=rect(x, y, w, h), anchor=anchor,
                    initial=initial, clamped=rect(x, y + h - 40, min(300, w), 40)))

    def check(self, report=None):
        return CHECK.validate(self.report if report is None else report, self.root)

    def test_complete_synthetic_contract_and_reordered_cases_pass(self):
        self.assertIs(self.check(), self.report)
        self.report['appearances'].reverse()
        self.report['placement'].reverse()
        self.report['appearances'][0]['states'].reverse()
        self.check()

    def test_missing_pending_routes_permissions_and_boolean_counts_rejected(self):
        changes = [('status', 'pending'), ('phase', 'running'), ('interactionRoute', 'model-only'),
                   ('hitTestRoute', ''), ('dragRoute', 'synthetic displacement'), ('recordingStarted', True),
                   ('permissionRequested', True), ('globalInputPosted', True), ('nativeMonitorRegistrations', 1),
                   ('productionTimers', False), ('productionObservers', 1), ('snapshotPixelsPerPoint', 2),
                   ('contentWidthPoints', 301), ('retirementCycles', 7), ('captureExclusion', 'physically verified')]
        for key, value in changes:
            candidate = copy.deepcopy(self.report); candidate[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.check(candidate)
        for key in self.report:
            candidate = copy.deepcopy(self.report); del candidate[key]
            with self.subTest(missing=key), self.assertRaises(ValueError): self.check(candidate)

    def test_missing_duplicate_themes_and_states_rejected(self):
        for scope in ('appearances', 'states', 'placement'):
            for duplicate in (False, True):
                candidate = copy.deepcopy(self.report)
                entries = candidate['appearances'][0]['states'] if scope == 'states' else candidate[scope]
                if duplicate: entries[-1] = copy.deepcopy(entries[0])
                else: entries.pop()
                with self.subTest(scope=scope, duplicate=duplicate), self.assertRaises(ValueError): self.check(candidate)

    def test_stale_binding_wrong_action_counts_missing_hits_and_disable_state_rejected(self):
        for key in ['busyStopVerified', 'replacementActionsVerified', 'shortcutUpdatesVerified', 'expandHideRestoreVerified', 'retiredActionsVerified']:
            candidate = copy.deepcopy(self.report); candidate['appearances'][0][key] = False
            with self.subTest(key=key), self.assertRaises(ValueError): self.check(candidate)
        for key in ['initialPauseCalls', 'initialStopCalls', 'replacementStopCalls', 'replacementExpandCalls']:
            candidate = copy.deepcopy(self.report); candidate['appearances'][0][key] += 1
            with self.subTest(key=key), self.assertRaises(ValueError): self.check(candidate)
        for key, value in [('layoutStatus', 'pending'), ('hitTestStatus', 'layout-only'), ('pauseEnabled', False),
                           ('stopEnabled', False), ('file', '../outside.png'), ('geometryFile', '/outside.json')]:
            candidate = copy.deepcopy(self.report); candidate['appearances'][0]['states'][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.check(candidate)
        candidate = copy.deepcopy(self.report); candidate['appearances'][0]['states'][2]['stopEnabled'] = True
        with self.assertRaises(ValueError): self.check(candidate)

    def test_drag_button_motion_uncancelled_gesture_and_clamp_escape_rejected(self):
        changes = [('buttonDragDidNotMove', False), ('hideCancelledDrag', False), ('regionMutationAvailable', True),
            ('status', 'pending'), ('afterGrip', rect(300, 300, 300, 40)), ('afterClamp', rect(980, 23, 300, 40)),
            ('visibleFrame', rect(0, 40, 1280, 776))]
        for key, value in changes:
            candidate = copy.deepcopy(self.report); candidate['appearances'][0]['drag'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.check(candidate)

    def test_retained_objects_incomplete_probes_and_deadline_overrun_rejected(self):
        for scope in ('appearance', 'repeated'):
            for key, value in [('status', 'pending'), ('weakProbeCount', 8), ('retainedObjects', 1),
                               ('releaseMilliseconds', 3000.1), ('releaseMilliseconds', float('nan')), ('deadlineMilliseconds', 4000)]:
                candidate = copy.deepcopy(self.report)
                target = candidate['appearances'][0]['ownership'] if scope == 'appearance' else candidate['repeatedRetirement']
                target[key] = value
                with self.subTest(scope=scope, key=key, value=value), self.assertRaises(ValueError): self.check(candidate)

    def test_raw_overlap_clipping_hidden_duplicate_targets_and_changed_anchor_rejected(self):
        path = self.root / self.report['appearances'][0]['states'][0]['geometryFile']
        original = json.loads(path.read_text())
        for change in ['overlap', 'clipping', 'hidden', 'duplicate', 'size', 'window', 'nonfinite', 'coordinate']:
            raw = copy.deepcopy(original)
            if change == 'overlap': raw['controls'][4]['frame']['x'] = 200
            elif change == 'clipping': raw['controls'][4]['frame']['y'] = -1
            elif change == 'hidden': raw['controls'][4]['hidden'] = True
            elif change == 'duplicate': raw['controls'][4]['identifier'] = raw['controls'][3]['identifier']
            elif change == 'size': raw['controls'][4]['frame']['width'] = 30
            elif change == 'window': raw['windowFrame']['x'] += 1
            elif change == 'nonfinite': raw['controls'][4]['frame']['x'] = float('nan')
            else: raw['coordinateSystem'] = 'top-left'
            path.write_text(json.dumps(raw))
            with self.subTest(change=change), self.assertRaises(ValueError): self.check()
        path.write_text(json.dumps(original))

    def test_png_missing_wrong_dimensions_truncated_crc_and_identical_themes_rejected(self):
        path = self.root / 'recording-transport-recording-light.png'
        original = path.read_bytes()
        for data in [unit_png(250, width=299), original[:24], original[:-1], original + b'extra',
                     original[:29] + b'bad!' + original[33:], unit_png(44)]:
            path.write_bytes(data)
            with self.subTest(length=len(data)), self.assertRaises((ValueError, zlib.error)): self.check()
        path.unlink()
        with self.assertRaises(ValueError): self.check()
        path.write_bytes(original)

    def test_placement_negative_origin_cases_must_remain_bounded(self):
        for key, value in [('initial', rect(-2000, -480, 300, 40)), ('clamped', rect(-1920, 576, 300, 40)),
                           ('visibleFrame', rect(0, 0, 1920, 1056)), ('initial', rect(-1900, -480, 300, 40))]:
            candidate = copy.deepcopy(self.report); candidate['placement'][3][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.check(candidate)

    def test_cli_rejects_mutations_under_optimized_python(self):
        path = self.root / 'recording-transport.json'
        path.write_text(json.dumps(self.report))
        success = subprocess.run([sys.executable, '-O', str(SCRIPT), str(path)], capture_output=True, text=True, timeout=10)
        self.assertEqual(success.returncode, 0, success.stderr)
        self.report['appearances'][0]['busyStopVerified'] = False
        path.write_text(json.dumps(self.report))
        failure = subprocess.run([sys.executable, '-O', str(SCRIPT), str(path)], capture_output=True, text=True, timeout=10)
        self.assertEqual(failure.returncode, 1)
        self.assertIn('busyStopVerified', failure.stderr)

    def test_duplicate_json_keys_nonfinite_values_and_symlink_files_rejected(self):
        path = self.root / 'bad.json'
        for data in ['{"status":"passed","status":"failed"}', '{"value":NaN}']:
            path.write_text(data)
            with self.assertRaises(ValueError): CHECK.read_json(path)
        path.unlink(); path.symlink_to(self.root / 'recording-transport-recording-light.png')
        with self.assertRaises(ValueError): CHECK.png(path)


if __name__ == '__main__':
    unittest.main()
