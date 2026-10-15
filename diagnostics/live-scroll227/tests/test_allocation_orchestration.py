"""Failure-path controls for diagnostic orchestration, with no native probes."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
if not (HERE / 'check-allocation-run.py').is_file():
    raise RuntimeError('Missing diagnostic checker')

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

C = load('allocation_checker', 'check-allocation-run.py')
A = load('allocation_artifacts', 'prepare-allocation-artifacts.py')

class OrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.prior_root, C.ROOT = C.ROOT, self.root
    def tearDown(self):
        C.ROOT = self.prior_root
        self.temp.cleanup()
    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data))
        return path
    def retired(self, **changes):
        data = dict(memoryAcceptance=False, appRetirementConfirmed=True,
            launcherCleanupConfirmed=True, volumeCleanupConfirmed=True,
            nativeCommands=[dict(cleanupConfirmed=True)], appLaunched=True)
        data.update(changes)
        self.write('observer-report.json', data)
        return data
    def test_detach_failure_keeps_output_checks_available_but_blocks_diagnostic_completion(self):
        self.retired(volumeCleanupConfirmed=False)
        C.retired()
        with self.assertRaises(AssertionError):
            C.retired(require_volume_cleanup=True)
    def test_unknown_or_live_owned_process_blocks_decoding(self):
        for mutation in [dict(appLaunched=None), dict(appLaunched=1),
                         dict(appRetirementConfirmed=False), dict(launcherCleanupConfirmed=False),
                         dict(nativeCommands=[dict(cleanupConfirmed=False)]), dict(memoryAcceptance=True)]:
            with self.subTest(mutation=mutation):
                self.retired(**mutation)
                with self.assertRaises(AssertionError): C.retired()
    def test_incomplete_workload_cannot_invoke_complete_native_verifier(self):
        self.retired()
        self.write('resource/measure/live-scroll-resource-measurement.json', dict(measurementComplete=False))
        with patch.object(C.subprocess, 'run', side_effect=AssertionError('Must not launch')):
            C.validate_if_complete()
        scope = C.read(self.root / 'native-validation-scope.json')
        self.assertEqual(scope['status'], 'not-run')
        self.assertTrue(scope['original227MemoryFailurePreserved'])
    def test_instrumented_failure_and_raw_step_outcome_are_preserved(self):
        self.write('resource/measure/live-scroll-resource-measurement.json',
            dict(status='failed', memoryGateStatus='failed', measurementComplete=True,
                 budgetAssessment={'warmRSS': 123456789}))
        with patch.dict(os.environ, {'PICSHOT_ALLOCATION_STEP_OUTCOMES': json.dumps({'measure': {'outcome': 'failure', 'conclusion': 'success'}})}, clear=False):
            C.summarize()
        report = C.read(self.root / 'outcomes.json')
        self.assertEqual(report['steps']['measure'], 'failure')
        self.assertEqual(report['original227MemoryGateStatus'], 'failed')
        self.assertEqual(report['originalWarmRSS'], 10780672)
        self.assertEqual(report['originalLateThreeRSS'], 5177344)
        self.assertFalse(report['memoryAcceptance'])
        self.assertFalse(report['installerAcceptance'])
        with self.assertRaises(AssertionError): C.require_complete()
    def test_incomplete_archival_cannot_be_reported_as_complete_diagnostic(self):
        self.retired(status='evidence-collected')
        self.write('outcomes.json', dict(steps={key:'success' for key in
            ['provenance','contracts','build','certify','measure','outputs','native_validation']},
            original227MemoryGateStatus='failed', installerAcceptance=False))
        self.write('available-output-verification.json', dict(status='all-ten-exact', verifiedOutputCount=10))
        self.write('native-validation-scope.json', dict(status='all-ten-exact'))
        self.write('artifact-manifest.json', dict(status='incomplete-evidence', errors=['bounded exclusion'], producedOutputs=[{}]*10))
        with self.assertRaises(AssertionError): C.require_complete()
    def test_certification_requires_exact_current_binary_input_source_and_gate_binding(self):
        app = self.root / 'source/dist/PicShot.app/Contents/MacOS/PicShot'
        app.parent.mkdir(parents=True); app.write_bytes(b'owned instrumented executable')
        oracle = self.root / 'resource/input/fixture.bgra'
        oracle.parent.mkdir(parents=True); oracle.write_bytes(b'generated oracle bytes')
        data = dict(status='passed', mode='certify', sourceCommit=C.PRODUCT, pngWriterBackend='foundation',
            executableSHA256=C.sha(app), processIdentifier=12, predeclaredTargetsAndGatesBytes=C.GATES,
            outputCertificate={'pixelEquality': True}, inputSHA256=C.sha(oracle), elapsedSeconds=3.2)
        def install(value):
            self.write('resource/certify/summary.json', value)
            self.write('resource/input/certificate.json', {k: v for k,v in value.items() if k != 'elapsedSeconds'})
        with patch.object(C, 'launcher', return_value={'processIdentifier': 12}):
            install(data); C.certify()
            for key, wrong in [('sourceCommit', 'a'*40), ('executableSHA256','b'*64),
                               ('inputSHA256','c'*64), ('pngWriterBackend','posix'),
                               ('predeclaredTargetsAndGatesBytes', dict(C.GATES, measuredGrowth=1))]:
                with self.subTest(key=key), self.assertRaises(AssertionError):
                    install(dict(data, **{key:wrong})); C.certify()
            install(data)
            certificate = C.read(self.root/'resource/input/certificate.json')
            certificate['status']='failed'; self.write('resource/input/certificate.json',certificate)
            with self.assertRaises(AssertionError): C.certify()
    def test_bounded_pngs_survive_oversized_text_failure_and_links_never_stage(self):
        output = self.root/'resource/measure'; output.mkdir(parents=True)
        (output/'cycle-01.png').write_bytes(b'generated image evidence')
        (output/'cycle-02.png').symlink_to(output/'cycle-01.png')
        (output/'cycle-11.png').write_bytes(b'unexpected')
        with (self.root/'overflow.log').open('wb') as stream: stream.truncate(A.TEXT_PART_BYTES + 1)
        self.write('owned.json', {'source':C.PRODUCT})
        report = A.prepare(self.root)
        self.assertEqual(report['status'],'incomplete-evidence')
        self.assertEqual([row['file'] for row in report['producedOutputs']], ['cycle-01.png'])
        self.assertEqual((self.root/'artifacts/outputs/cycle-01.png').read_bytes(), b'generated image evidence')
        self.assertFalse((self.root/'artifacts/outputs/cycle-02.png').exists())
        self.assertEqual(len(report['errors']),3)
    def test_exact_image_limit_is_rejected_and_artifact_members_are_identical(self):
        output=self.root/'resource/measure';output.mkdir(parents=True)
        with (output/'cycle-01.png').open('wb') as stream: stream.truncate(A.IMAGE_BYTES)
        payload=self.write('record.json', {'source':C.PRODUCT})
        (self.root/'source').mkdir();(self.root/'source/private.log').write_text('excluded source worktree')
        report=A.prepare(self.root)
        self.assertFalse(report['producedOutputs'])
        self.assertEqual(len(report['recordParts']),1)
        import zipfile
        with zipfile.ZipFile(self.root/'artifacts'/report['recordParts'][0]['file']) as archive:
            self.assertEqual(archive.namelist(),['record.json'])
            self.assertEqual(archive.read('record.json'),payload.read_bytes())
        self.assertFalse(report['installerAcceptance'])
        self.assertTrue(report['original227MemoryFailurePreserved'])

if __name__ == '__main__': unittest.main()
