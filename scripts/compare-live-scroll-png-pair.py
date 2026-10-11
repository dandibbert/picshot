#!/usr/bin/env python3
"""Observe exactly one Foundation/POSIX pair; this never grants installer acceptance."""
import hashlib
import json
from pathlib import Path
import re
import sys

FIXED_GATES = dict(coldFinalGrowth=26607616, coldSampledGrowth=129171456,
                   lateIntervalAndSum=4915200, measuredGrowth=9830400)

def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 16 * 1024 * 1024,
            f'Invalid bounded report: {path.name}')
    return json.loads(path.read_text())


def cell(root, backend, source):
    directory = root / backend
    wrapper = read(directory / 'resource-wrapper.json')
    path = directory / 'measure/live-scroll-resource-measurement.json'
    measurement = read(path)
    validation = read(directory / 'measure/live-scroll-resource-validation.json')
    certificate = read(directory / 'input/certificate.json')
    code = int((root / f'{backend}-exit-code.txt').read_text())
    require(wrapper['sourceCommit'] == measurement['sourceCommit'] == validation['sourceCommit'] == certificate['sourceCommit'] == source,
            f'{backend}: source mismatch')
    for key in ['executableSHA256', 'pngWriterBackend', 'inputSHA256']:
        require(measurement[key] == validation[key] == certificate[key] == wrapper[key], f'{backend}: {key} mismatch')
    require(measurement['pngWriterBackend'] == backend, f'{backend}: wrong writer')
    certificate_sha = hashlib.sha256((directory / 'input/certificate.json').read_bytes()).hexdigest()
    require(measurement['certificateSHA256'] == validation['certificateSHA256'] == wrapper['certificateSHA256'] == certificate_sha,
            f'{backend}: certificate identity mismatch')
    require(wrapper['exactInstalledApp'] == measurement['bundlePath'], f'{backend}: exact installed app mismatch')
    require(measurement['predeclaredTargetsAndGatesBytes'] == FIXED_GATES, f'{backend}: fixed gates changed')
    require(measurement['workload'] == 'live-scroll-owned-1280-v1' and measurement['sourceFramesPerCycle'] == 218
            and (measurement['viewportWidth'], measurement['viewportHeight']) == (1280, 960)
            and (measurement['outputWidth'], measurement['outputHeight'], measurement['preparedRawBytes']) == (1280, 7136, 36536320),
            f'{backend}: fixed workload changed')
    require(validation['measurementReportSHA256'] == hashlib.sha256(path.read_bytes()).hexdigest(),
            f'{backend}: validation does not bind measured report')
    require(measurement['measurementComplete'] is True and measurement['measurementStatus'] == 'complete'
            and measurement['completedWarmupCycles'] == 2 and measurement['completedMeasuredCycles'] == 8,
            f'{backend}: incomplete workload')
    require(validation['validationCompleted'] is True and validation['pixelValidationStatus'] == 'passed',
            f'{backend}: independent pixel validation failed or missing')
    cycles = measurement['cycles']
    proofs = validation['outputCertificates']
    require(len(cycles) == len(proofs) == 10, f'{backend}: ten cycles and proofs required')
    for ordinal, (cycle, proof) in enumerate(zip(cycles, proofs), 1):
        require(cycle['ordinal'] == proof['ordinal'] == ordinal and cycle['status'] == 'passed'
                and cycle['warmup'] is (ordinal <= 2) and cycle['finishCallbacks'] == 1 and cycle['pngWriterBackend'] == backend,
                f'{backend}: cycle {ordinal} incomplete')
        output = cycle['output']
        require(output['file'] == f'cycle-{ordinal:02d}.png'
                and (output['width'], output['height'], output['layoutBytes']) == (1280, 7136, 36536320),
                f'{backend}: output geometry or filename changed')
        require(proof['passed'] is True and proof['pixelEquality'] is True and proof['comparedBytes'] == 36536320
                and proof['file'] == output['file'] and proof['encodedBytes'] == proof['expectedEncodedBytes'] == output['encodedBytes']
                and re.fullmatch(r'[0-9a-f]{64}', proof['sha256']), f'{backend}: output {ordinal} mismatch')
        require(cycle['ownedSpoolParentRemoved'] is True and cycle['remainingSpoolEntries'] == []
                and cycle['sourceAfterStop']['successfulFrames'] == 218 and cycle['sourceAfterStop']['activeReads'] == 0
                and cycle['sourceAfterStop']['descriptorCloseConfirmed'] is True
                and cycle['lastProductState']['acceptedObservations'] == 218, f'{backend}: source cleanup mismatch')
        for phase in ['ownership150ms', 'ownership1000ms']:
            owners = cycle[phase]
            require(all(owners[key] is True for key in ['controlsReleased', 'sessionReleased', 'sourceReleased', 'thumbnailReleased'])
                    and owners['attachedWindowGraphs'] == owners['retainedWindowShells'] == 0,
                    f'{backend}: retained owner at {phase}')
        require(cycle['provider150ms']['liveBytes'] == cycle['providerAfterClose']['liveBytes'] == 0,
                f'{backend}: retained source pixels')
    memory = measurement['budgetAssessment']['warmAndLateGatesPassed']
    require(type(memory) is bool, f'{backend}: invalid memory gate')
    expected = 'passed' if memory else 'failed'
    require(measurement['memoryGateStatus'] == validation['memoryGateStatus'] == wrapper['memoryGateStatus'] == expected,
            f'{backend}: memory failure obscured')
    require(validation['status'] == wrapper['qualificationStatus'] == expected and code == (0 if memory else 1),
            f'{backend}: exit or qualification mismatch')
    require(measurement['status'] == ('measured-awaiting-pixel-validation' if memory else 'failed'),
            f'{backend}: measurement status mismatch')
    if not memory:
        require(measurement['failureKind'] == 'memory-gates', f'{backend}: not a complete memory failure')
    return {'backend': backend, 'qualificationStatus': expected, 'exitCode': code,
            'exactInstalledApp': wrapper['exactInstalledApp'],
            'sourceCommit': source, 'executableSHA256': measurement['executableSHA256'],
            'inputSHA256': measurement['inputSHA256'], 'workload': measurement['workload'],
            'predeclaredTargetsAndGatesBytes': measurement['predeclaredTargetsAndGatesBytes'],
            'budgetAssessment': measurement['budgetAssessment'], 'entry': measurement['entry'],
            'afterInputValidation': measurement['afterInputValidation'], 'final': measurement['final'],
            'elapsedSeconds': measurement['elapsedSeconds'],
            'cycleElapsedSeconds': [c['elapsedSeconds'] for c in cycles],
            'cycleMemory': [c['memory'] for c in cycles],
            'cycleBoundaries': [c['boundaries'] for c in cycles],
            'outputCertificates': proofs, 'completeCycles': 10, 'independentPixelCertificates': 10,
            'measurementSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'installerAcceptance': False}


def compare(root, source):
    require(re.fullmatch(r'[0-9a-f]{40}', source), 'Invalid source SHA')
    result = {'schemaVersion': 1, 'status': 'incomplete', 'sourceCommit': source, 'installerAcceptance': False,
              'productionDefault': 'foundation', 'order': ['foundation', 'posix'], 'cells': {},
              'allMemoryGatesPassed': False, 'candidatePromoted': False}
    errors = []
    for backend in result['order']:
        try:
            result['cells'][backend] = cell(root, backend, source)
        except (ValueError, KeyError, TypeError, OSError) as error:
            errors.append(f'{backend}: {error}')
    if errors:
        result['errors'] = errors
        return result
    control, candidate = (result['cells'][name] for name in result['order'])
    for key in ['sourceCommit', 'executableSHA256', 'exactInstalledApp', 'inputSHA256', 'workload', 'predeclaredTargetsAndGatesBytes']:
        require(control[key] == candidate[key], f'Pair differs in {key}')
    for index, (a, b) in enumerate(zip(control['outputCertificates'], candidate['outputCertificates']), 1):
        require(a['sha256'] == b['sha256'] and a['encodedBytes'] == b['encodedBytes'],
                f'Encoded bytes differ at cycle {index}')
    result.update(status='observed', exactEncodedOutputsMatch=True, completeCycles=20,
                  independentPixelCertificates=20,
                  allMemoryGatesPassed=all(c['qualificationStatus'] == 'passed' for c in result['cells'].values()))
    result['measuredGrowthDifferenceCandidateMinusControl'] = {
        key: candidate['budgetAssessment'][key]['measuredGrowth'] - control['budgetAssessment'][key]['measuredGrowth']
        for key in ['residentBytes', 'physicalFootprintBytes', 'combinedVolatileLedger']}
    result['candidateDecision'] = ('requires-full-trace-review' if candidate['qualificationStatus'] == 'passed'
        and result['measuredGrowthDifferenceCandidateMinusControl']['physicalFootprintBytes'] < 0
        else 'reject-no-qualified-footprint-improvement')
    return result


def main():
    root, source = Path(sys.argv[1]), sys.argv[2]
    try:
        result = compare(root, source)
    except (ValueError, KeyError, TypeError, OSError) as error:
        result = {'status': 'incomplete', 'error': str(error), 'installerAcceptance': False, 'candidatePromoted': False}
    (root / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result.get(key) for key in ['status', 'candidateDecision', 'allMemoryGatesPassed', 'installerAcceptance']}))
    return 0 if result['status'] == 'observed' else 1


if __name__ == '__main__':
    sys.exit(main())
