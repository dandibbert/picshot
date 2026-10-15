#!/usr/bin/env python3
"""Bind the one diagnostic's outcomes, retaining original227's failed gates."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path('dist/allocation227').resolve()
PRODUCT = 'e5a859a82b2a7a697e51a0a4d42f34ae4f5602d0'
GATES = dict(coldFinalGrowth=26607616, coldSampledGrowth=129171456,
             lateIntervalAndSum=4915200, measuredGrowth=9830400)


def read(path):
    assert path.is_file() and not path.is_symlink() and path.stat().st_size <= 16 * 1024 * 1024, path.name
    return json.loads(path.read_text())


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(1 << 20):
            digest.update(block)
    return digest.hexdigest()


def write(name, value):
    ROOT.mkdir(parents=True, exist_ok=True)
    (ROOT / name).write_text(json.dumps(value, indent=2) + '\n')


def launcher(summary):
    result = read(Path(str(summary) + '.launcher.json'))
    assert result.get('status') == 'exited' and result.get('launcherExitCode') == 0, result
    assert result.get('ownedExitConfirmed') is True and result.get('callbackReceived') is True, result
    assert result.get('createsNewApplicationInstance') is True and result.get('launchedIdentityMatches') is True, result
    app = ROOT / 'source/dist/PicShot.app'
    assert result.get('selectedAppPath') == result.get('launchedAppPath') == str(app), result
    assert result.get('launchedExecutablePath') == str(app / 'Contents/MacOS/PicShot'), result
    assert result.get('timeoutSeconds') == 600, result
    return result


def certify():
    summary = ROOT / 'resource/certify/summary.json'
    receipt = launcher(summary)
    data = read(summary)
    assert data.get('status') == 'passed' and data.get('mode') == 'certify'
    assert data.get('sourceCommit') == PRODUCT and data.get('pngWriterBackend') == 'foundation'
    assert data.get('executableSHA256') == sha(ROOT / 'source/dist/PicShot.app/Contents/MacOS/PicShot')
    assert data.get('processIdentifier') == receipt.get('processIdentifier')
    assert data.get('predeclaredTargetsAndGatesBytes') == GATES
    assert data.get('outputCertificate', {}).get('pixelEquality') is True
    assert data.get('inputSHA256') == sha(ROOT / 'resource/input/fixture.bgra')
    certificate = read(ROOT / 'resource/input/certificate.json')
    # Original227 publishes its input certificate before adding the final elapsed field.
    assert {key: value for key, value in data.items() if key != 'elapsedSeconds'} == certificate
    write('certification-binding.json', dict(status='passed', executableSHA256=data['executableSHA256'],
        inputSHA256=data['inputSHA256'], sourceCommit=PRODUCT, diagnosticOnly=True, installerAcceptance=False))


def retired(require_volume_cleanup=False):
    data = read(ROOT / 'observer-report.json')
    assert data.get('memoryAcceptance') is False
    assert data.get('appRetirementConfirmed') is True and data.get('launcherCleanupConfirmed') is True
    if require_volume_cleanup:
        assert data.get('volumeCleanupConfirmed') is True
    assert all(row.get('cleanupConfirmed') is True for row in data.get('nativeCommands', []))
    assert type(data.get('appLaunched')) is bool, 'Unknown owned app state'
    return data


def validate_if_complete():
    retired()
    path = ROOT / 'resource/measure/live-scroll-resource-measurement.json'
    measurement = read(path) if path.is_file() else {}
    if measurement.get('measurementComplete') is not True:
        write('native-validation-scope.json', dict(status='not-run', reason='Original complete verifier requires all ten completed cycles',
            availableOutputProof='available-output-verification.json', original227MemoryFailurePreserved=True, installerAcceptance=False))
        return
    assert measurement.get('completedWarmupCycles') == 2 and measurement.get('completedMeasuredCycles') == 8
    assert len(measurement.get('cycles', [])) == 10 and measurement.get('sourceFramesPerCycle') == 218
    assert measurement.get('predeclaredTargetsAndGatesBytes') == GATES
    environment = {key: value for key, value in os.environ.items() if not key.startswith(('Malloc', 'PICSHOT_'))}
    environment.update(PICSHOT_LIVE_SCROLL_RESOURCE_MODE='validate', PICSHOT_LIVE_SCROLL_RESOURCE_INPUT=str(ROOT / 'resource/input'), PICSHOT_LIVE_SCROLL_PNG_WRITER='foundation')
    command = ['python3', 'scripts/run-bounded-command.py', '--timeout-seconds', '620', '--max-log-bytes', '8388608',
        '--log', str(ROOT / 'native-validation.log'), '--report', str(ROOT / 'native-validation-command.json'),
        '--', '/usr/bin/swift', str(ROOT / 'source/scripts/launch-smoke-app.swift'), str(ROOT / 'source/dist/PicShot.app'),
        str(ROOT / 'resource/measure/validation-summary.json')]
    result = subprocess.run(command, env=environment, timeout=640)
    assert result.returncode == 0, 'Original native verifier launch did not complete'
    launched = launcher(ROOT / 'resource/measure/validation-summary.json')
    validation = read(ROOT / 'resource/measure/validation-summary.json')
    assert validation.get('processIdentifier') == launched.get('processIdentifier') != measurement.get('processIdentifier')
    assert validation.get('validationCompleted') is True and validation.get('pixelValidationStatus') == 'passed'
    assert validation.get('measurementReportSHA256') == sha(path)
    assert validation.get('memoryGateStatus') == measurement.get('memoryGateStatus')
    for key in ['sourceCommit', 'executableSHA256', 'inputSHA256', 'certificateSHA256', 'pngWriterBackend']:
        assert validation.get(key) == measurement.get(key), key
    proofs = validation.get('outputCertificates', [])
    assert len(proofs) == 10 and all(proof.get('passed') is True and proof.get('pixelEquality') is True and proof.get('comparedBytes') == 36536320 for proof in proofs)
    write('native-validation-scope.json', dict(status='all-ten-exact', outputCertificates=10,
        instrumentedMemoryGateStatus=measurement['memoryGateStatus'], original227MemoryFailurePreserved=True, installerAcceptance=False))


def summarize():
    stages = json.loads(os.environ.get('PICSHOT_ALLOCATION_STEP_OUTCOMES', '{}'))
    report = dict(schemaVersion=1, status='diagnostic-outcomes-recorded', diagnosticOnly=True,
        productBase=PRODUCT, workflowCommit=os.environ.get('GITHUB_SHA'), runID=os.environ.get('GITHUB_RUN_ID'),
        steps={key: value.get('outcome') for key, value in stages.items()}, installerAcceptance=False,
        memoryAcceptance=False, original227MemoryGateStatus='failed', original227MemoryFailurePreserved=True,
        originalWarmRSS=10780672, originalWarmLimit=9830400, originalLateThreeRSS=5177344, originalLateLimit=4915200)
    for filename, key in [('observer-report.json', 'observer'), ('available-output-verification.json', 'availableOutputs'), ('native-validation-scope.json', 'nativeValidation')]:
        path = ROOT / filename
        if path.is_file():
            data = read(path)
            report[key] = dict(status=data.get('status'), sha256=sha(path), file=filename)
    measurement = ROOT / 'resource/measure/live-scroll-resource-measurement.json'
    if measurement.is_file():
        data = read(measurement)
        report['instrumentedMeasurement'] = dict(status=data.get('status'), memoryGateStatus=data.get('memoryGateStatus'),
            measurementComplete=data.get('measurementComplete'), sha256=sha(measurement),
            budgetAssessment=data.get('budgetAssessment'), neverReplacesOriginalQualification=True)
    write('outcomes.json', report)


def require_complete():
    outcomes = read(ROOT / 'outcomes.json')
    for key in ['provenance', 'contracts', 'build', 'certify', 'measure', 'outputs', 'native_validation']:
        assert outcomes['steps'].get(key) == 'success', (key, outcomes['steps'])
    observer = retired(require_volume_cleanup=True)
    assert observer.get('status') == 'evidence-collected'
    images = read(ROOT / 'available-output-verification.json')
    assert images.get('status') == 'all-ten-exact' and images.get('verifiedOutputCount') == 10
    assert read(ROOT / 'native-validation-scope.json').get('status') == 'all-ten-exact'
    archives = read(ROOT / 'artifact-manifest.json')
    assert archives.get('status') == 'bounded-evidence-prepared' and archives.get('errors') == []
    assert len(archives.get('producedOutputs', [])) == 10
    assert outcomes['original227MemoryGateStatus'] == 'failed' and outcomes['installerAcceptance'] is False
    print('Diagnostic evidence collected; allocation attribution requires raw review. Original227 remains failed.')


if __name__ == '__main__':
    commands = {'certify': certify, 'retired': retired, 'validate-if-complete': validate_if_complete,
                'summarize': summarize, 'require-complete': require_complete}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        raise SystemExit('Expected one declared diagnostic stage')
    commands[sys.argv[1]]()
