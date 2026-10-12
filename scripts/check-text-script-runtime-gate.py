#!/usr/bin/env python3
"""Rebind the narrow text runtime's native receipts to exact signed source bytes."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re

CASES = {
    'signed-source-identity', 'unicode-normalization', 'regex-body-deduplication',
    'input-is-argument-not-source', 'function-body-breakout-is-syntax',
    'syntax-fixed-diagnostic', 'throw-fixed-diagnostic', 'throw-does-not-coerce-object',
    'object-result-rejected', 'boxed-string-rejected', 'promise-result-rejected',
    'empty-result-rejected', 'oversized-result-rejected', 'unpaired-surrogate-rejected',
    'no-host-or-native-probe-apis', 'maximum-utf16-output',
    'partial-nonblocking-request-and-response', 'exact-source-byte-bound',
    'source-bound-before-launch', 'input-bound-before-launch', 'empty-input-before-launch',
    'native-sandbox-read-write-open-and-network-denials', 'cancel-before-launch',
    'single-global-admission', 'cancel-during-evaluation', 'infinite-loop-bounded-exit',
    'actual-main-runloop-heartbeat', 'allocation-rss-watchdog', 'abrupt-owned-helper-exit',
    'rss-observation-fails-closed', 'unknown-exit-retains-admission',
    'retained-admission-discards-response', 'retained-admission-recovers-only-after-observation',
    'subsequent-run-after-cleanup', 'parent-loss-five-second-alarm', 'final-admission-empty',
    *('transport-' + mode for mode in ['malformed', 'oversized', 'wrong-identity',
       'duplicate-key', 'missing-newline', 'multiple-response', 'late-response', 'ignore-terminate', 'valid-before-hang', 'stderr-flood']),
}


def need(value, message):
    if not value:
        raise ValueError(message)


def read(path, limit):
    need(path.is_file() and not path.is_symlink() and path.stat().st_size <= limit,
         'Missing, unsafe or oversized evidence: ' + str(path))
    return path.read_bytes()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def check(directory, source, root):
    build_path = directory / 'build-identity.json'
    report_path = directory / 'evidence' / 'text-script-gate-report.json'
    build = json.loads(read(build_path, 1024 * 1024))
    report = json.loads(read(report_path, 512 * 1024))
    need(build['schemaVersion'] == 1 and report['schemaVersion'] == 1, 'Unsupported evidence schema')
    need(build['sourceCommit'] == source == report['sourceSHA'], 'Source identity mismatch')
    need(build['architecture'] == 'arm64' and build['externalPackageDependencies'] == [], 'Unexpected build scope')
    need(build['appSignatureVerified'] is True and build['helperEntitlementsVerifiedAfterOuterSigning'] is True,
         'Final signature/entitlement check missing')
    archive = build['gateArchive']
    need(archive['name'] == 'gate-signed-bundle.zip', 'Unexpected gate archive name')
    archive_bytes = read(directory / archive['name'], 18 * 1024 * 1024)
    need(len(archive_bytes) == archive['bytes'] and digest(archive_bytes) == archive['sha256'], 'Signed gate archive changed')
    need(report['generatedInputsOnly'] is True and report['ordinaryAcceptanceSeconds'] == 3 and report['passed'] is True,
         'Native gate failed or scope changed')
    checks = report['checks']
    need(len(checks) == len(CASES) and {row['name'] for row in checks} == CASES,
         'Native cases missing, duplicated or unexpected')
    need(all(row['passed'] is True for row in checks), 'A native assertion failed')
    cases = {row['name']: row for row in checks}
    seen = set()
    for entry in build['sources']:
        path = entry['path']
        need(path not in seen and not Path(path).is_absolute() and '..' not in Path(path).parts, 'Invalid source inventory')
        seen.add(path)
        data = read(root / path, 256 * 1024)
        need(len(data) == entry['bytes'] and digest(data) == entry['sha256'], 'Built source inventory differs: ' + path)
    need('scripts/text-script-helper.entitlements' in seen, 'Signed entitlement source not inventoried')
    app = directory / 'PicShotTextScriptGate.app'
    need(Path(build['appPath']) == app, 'Gate bundle path mismatch')
    need(digest(read(app / 'Contents/MacOS/PicShotTextScriptGate', 32 * 1024 * 1024)) == build['executableSHA256'],
         'Gate executable changed')
    need(digest(read(app / 'Contents/Info.plist', 64 * 1024)) == build['plistSHA256'], 'Gate plist changed')
    need(read(app / 'Contents/Resources/text-script-gate-source.txt', 100) == (source + '\n').encode(),
         'Signed source resource changed')
    helpers = {row['identifier']: row for row in build['helpers']}
    need(set(helpers) == {'com.picshot.TextScriptHelper', 'com.picshot.TextScriptTransportFixture'}, 'Unexpected helpers')
    for identifier, helper in helpers.items():
        need(helper['observedIdentifier'] == identifier and helper['entitlements'] == {'com.apple.security.app-sandbox': True},
             'Final helper privileges differ')
        need(digest(read(app / helper['path'], 32 * 1024 * 1024)) == helper['sha256'], 'Signed helper bytes changed')
    for row in checks:
        metrics = row.get('metrics')
        if not metrics or not metrics['childLaunched']:
            continue
        signature = metrics['signature']
        helper = helpers[signature['helperIdentifier']]
        need(signature['appIdentifier'] == 'com.picshot.TextScriptGate' and
             signature['helperCDHash'] == helper['observedCDHash'] and
             signature['helperEntitlements'] == ['com.apple.security.app-sandbox'] and
             signature['appAndHelperStrictlyValidated'] is True, 'Native launch signature identity differs')
        need(metrics['acceptanceDeadlineSeconds'] == 3 and metrics['rssLimitBytes'] == 256 * 1024 * 1024 and
             metrics['rssSampleIntervalSeconds'] == 0.05 and metrics['terminateGraceSeconds'] == 0.25 and
             metrics['killedObservationSeconds'] == 0.75, 'Runtime limit changed')
        need(metrics['pipeDescriptorsCloseOnExec'] is True and metrics['parentEndpointsNonblocking'] is True and
             metrics['inputSuppressesSIGPIPE'] is True, 'Descriptor contract missing')
        need(metrics['retainedResponseBytesAfterFinish'] == 0, 'Retired supervisor retains response bytes')
        if row['name'] != 'unknown-exit-retains-admission':
            need(metrics['childExitConfirmed'] is True and metrics['pipesDrained'] is True and
                 metrics['admissionReleased'] is True, 'Owned cleanup missing')
        else:
            need(metrics['outcome'] == 'exitUnconfirmed' and metrics['admissionReleased'] is False,
                 'Unconfirmed child did not retain admission')
    probe = cases['native-sandbox-read-write-open-and-network-denials']['probe']
    baseline = cases['native-sandbox-read-write-open-and-network-denials']['probeBaseline']
    need(set(baseline) == {'parentReadOpenSucceeded', 'parentWriteOpenSucceeded',
                          'parentLoopbackConnectAndAcceptSucceeded', 'bothSentinelsUnchanged',
                          'noHelperConnectionAccepted'} and all(value is True for value in baseline.values()),
         'Positive capability baselines or sentinel preservation missing')
    need(probe['readDenied'] is True and probe['writeDenied'] is True and probe['networkDenied'] is True,
         'Sandbox capability denied results missing')
    need(all(probe[key] in (1, 13) for key in ('readErrno', 'writeErrno', 'networkErrno')), 'Denial errno is not permission denial')
    alarm = cases['parent-loss-five-second-alarm']
    need(alarm['observedExitStatus'] & 0x7f == 14 and 4.5 <= alarm['elapsedSeconds'] < 6.5,
         'Independent alarm exit was not observed')
    heartbeat = cases['actual-main-runloop-heartbeat']
    need(heartbeat['heartbeatCount'] >= 20 and heartbeat['maximumHeartbeatGapSeconds'] < 0.25,
         'Main runloop response bound failed')
    expected = []
    for module in ('PicShotTextScriptCoreTests', 'PicShotTextScriptHelperTests'):
        for path in sorted((root / 'Tests' / module).glob('*.swift')):
            text = read(path, 256 * 1024).decode()
            classes = re.findall(r'final class (\w+): XCTestCase', text)
            need(len(classes) == 1, 'Unrecognized narrow test layout')
            expected.extend(module + '.' + classes[0] + '/' + name for name in re.findall(r'func (test\w+)\(', text))
    spec = importlib.util.spec_from_file_location('native_cases', root / 'scripts/native-test-shards.py')
    native = importlib.util.module_from_spec(spec); spec.loader.exec_module(native)
    log = read(directory / 'compile.stdout.log', 8 * 1024 * 1024).decode() + read(directory / 'compile.stderr.log', 8 * 1024 * 1024).decode()
    passed, skipped = native.case_results(log, sorted(expected))
    need(len(expected) == 14 and not skipped and len(passed) == 14,
         'Core/helper unit coverage changed or incomplete')
    result = {'status': 'passed', 'sourceCommit': source, 'nativeDecisionCases': len(checks),
              'unitMethodsPassed': len(passed), 'unitMethods': passed,
              'buildIdentitySHA256': digest(read(build_path, 1024 * 1024)),
              'nativeReportSHA256': digest(read(report_path, 512 * 1024)),
              'scope': 'standalone native runtime decision only; app integration and distribution remain unqualified'}
    (directory / 'evidence' / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--source', required=True)
    args = parser.parse_args()
    print(json.dumps(check(args.directory.resolve(), args.source, Path(__file__).resolve().parents[1]), sort_keys=True))
