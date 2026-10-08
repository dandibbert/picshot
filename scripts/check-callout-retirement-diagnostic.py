#!/usr/bin/env python3
"""Validate diagnostic capture separately from the unchanged original acceptance.

A valid failure snapshot is useful evidence, but this command still exits nonzero
when an original gate failed. Synthetic portable tests are never native proof.
"""
import argparse
import collections
import importlib.util
import json
import math
from pathlib import Path
import re
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    data = Path(path).read_bytes()
    require(0 < len(data) <= 2 * 1024 * 1024, 'missing/oversized JSON: ' + str(path))
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON key: ' + key)
            result[key] = value
        return result
    def invalid(value):
        raise ValueError('nonfinite JSON: ' + value)
    return json.loads(data, object_pairs_hook=pairs, parse_constant=invalid)


def process_passed(path):
    report = read_json(path)
    require(report['status'] == 'exited' and type(report['exit_code']) is int and report['exit_code'] == 0
            and report['log_truncated'] is False, 'bounded process incomplete: ' + str(path))
    return report


def validate_native(report_path, log_path, test_source):
    process_passed(report_path)
    expected = set(re.findall(r'\bfunc (test\w+)\(', Path(test_source).read_text()))
    require(len(expected) == 11, 'expected eleven native diagnostic tests')
    completed = []
    for label in re.findall(r"Test Case '(.*?)' passed", Path(log_path).read_text()):
        if 'NumberedCalloutRetirementDiagnosticsTests' in label:
            names = re.findall(r'\btest\w+\b', label)
            require(len(names) == 1, 'ambiguous native completion: ' + label)
            completed.extend(names)
    require(collections.Counter(completed) == collections.Counter(expected),
            'native diagnostic completions missing, duplicated or unexpected')


def finite(value, label):
    require(type(value) in (int, float) and math.isfinite(value), 'invalid clock: ' + label)
    return value


def validate_capture(root, source, processes):
    root = Path(root)
    require(re.fullmatch(r'[0-9a-f]{40}', source) is not None, 'invalid source SHA')
    require(len(processes) == 3, 'expected native, package and launch process reports')
    for path, expected_timeout in zip(processes, (540, 1800, 630)):
        process = process_passed(path)
        require(finite(process['timeout_seconds'], 'process timeout') == expected_timeout, 'process timeout changed')
    identity = read_json(root / 'identity.json')
    require(identity['sourceCommit'] == source and identity['architecture'] == 'x86_64', 'diagnostic identity mismatch')
    require(re.fullmatch(r'[0-9a-f]{64}', identity['executableSHA256']) is not None, 'missing executable digest')
    require(all(type(identity[key]) is int for key in ('expectedCycles', 'nativeDeadlineMilliseconds', 'maximumSamples', 'launcherDeadlineSeconds', 'executionsRequested')), 'invalid identity bounds')
    require(identity['expectedCycles'] == 6 and identity['nativeDeadlineMilliseconds'] == 2000
            and identity['maximumSamples'] == 256 and identity['launcherDeadlineSeconds'] == 600
            and identity['executionsRequested'] == 1, 'diagnostic bounds or invocation count changed')
    require(identity['fixtureEnvironment'] == {
        'PICSHOT_UI_PREVIEW_ONLY': '1',
        'PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTIC_PATH': str((root / 'retirement-sidecar.json').resolve())
    }, 'fixture ordering/environment changed')
    require(read_json(root / 'launcher-exit.json')['launcherExitCode'] == 0, 'launcher did not exit normally')
    preview = read_json(root / 'ui/preview.json')
    combined = read_json(root / 'ui/annotation-details/annotation-details.json')
    callout = read_json(root / 'ui/annotation-details/callouts/annotation-callouts.json')
    life = callout['commentLifecycle']
    sidecar = read_json(root / 'retirement-sidecar.json')
    require(combined['sourceCommit'] == source and combined['includeResourceCycles'] is False, 'wrong annotation source or route')
    require(Path(combined['bundlePath']).resolve() == Path(identity['appPath']).resolve(), 'bundle identity mismatch')
    require(sidecar['schema'] == 'callout-associated-token-diagnostic-v1', 'sidecar schema changed')
    require(sidecar['acceptanceStatus'] == callout['status'] and sidecar['observedLifecycle'] == life,
            'sidecar must preserve original lifecycle/status exactly')
    statuses = {'earlyUINativeFixture': preview['status'], 'combinedAnnotation': combined['status'],
                'callout': callout['status'], 'lifecycle': life['status']}
    require(all(value in ('passed', 'failed') for value in statuses.values()), 'original gate not terminal')
    require(life['contract'] == 'owned-graph-prompt_native-input-deadline-v2', 'original contract changed')
    require(all(type(life[key]) is int for key in ('expectedCycles', 'promptOwnershipCheckMilliseconds', 'pollIntervalMilliseconds', 'deferredInputDeadlineMilliseconds', 'maximumSamples')), 'invalid original bounds')
    require(life['expectedCycles'] == 6 and life['promptOwnershipCheckMilliseconds'] == 10
            and life['pollIntervalMilliseconds'] == 10 and life['deferredInputDeadlineMilliseconds'] == 2000
            and life['maximumSamples'] == 256 and life['zeroLeakClaim'] is False
            and life['frameworkRetirementOnly'] is True, 'original bounds/claim changed')
    require(1 <= len(life['cycles']) <= 6 and 1 <= len(life['samples']) <= 256, 'original sample/cycle bound')
    require(len(sidecar['cycles']) == len(life['cycles']), 'sidecar lost or added cycles')
    previous_created = 0
    for sample in life['samples']:
        created = sample['createdCycles']
        require(type(created) is int and previous_created <= created <= previous_created + 1
                and 1 <= created <= len(life['cycles']), 'invalid partial sample cycle count')
        for key in ('pendingInputCycles', 'pendingContextCycles'):
            pending = sample[key]
            require(type(pending) is list and all(type(value) is int and 1 <= value <= created for value in pending)
                    and pending == sorted(set(pending)), 'invalid partial pending IDs')
        previous_created = created
    require(previous_created == len(life['cycles']), 'partial sample inventory mismatch')
    began = finite(sidecar['monitorBeganAtUptime'], 'monitor began')
    start = finite(sidecar['snapshotStartedAtUptime'], 'snapshot start')
    finish = finite(sidecar['snapshotFinishedAtUptime'], 'snapshot finish')
    require(0 <= began <= start <= finish, 'snapshot clock order')
    timing = []
    for index, (row, observed) in enumerate(zip(sidecar['cycles'], life['cycles']), 1):
        require(type(row['cycle']) is int and type(observed['cycle']) is int and row['cycle'] == observed['cycle'] == index, 'cycle identity mismatch')
        close = finite(row['closedAtUptime'], 'close')
        require(began <= close <= start, 'close/snapshot order')
        require(math.isclose((close - began) * 1000, finite(observed['closedAtMilliseconds'], 'relative close'),
                             rel_tol=0, abs_tol=0.00001), 'close clocks differ')
        require(type(row['contextWasTracked']) is bool and type(observed['contextWasTracked']) is bool and row['contextWasTracked'] == observed['contextWasTracked'],
                'context tracking mismatch')
        item = {'cycle': index, 'firstJointNilObservationAfterMilliseconds': observed.get('releasedAfterMilliseconds')}
        confirmed = []
        for kind in ('input', 'context'):
            event = row.get(kind)
            if kind == 'context' and not row['contextWasTracked']:
                require(event is None, 'untracked context has event')
                item[kind] = {'timing': 'not-tracked'}
                continue
            result = {'timing': 'inconclusive'}
            if event is not None:
                callback = finite(event['tokenDeinitUptime'], 'token callback')
                checked = finite(event['weakCheckFinishedUptime'], 'weak check')
                require(0 <= callback <= checked <= finish, 'callback/snapshot clock order')
                require(type(event['sourceWasWeakNil']) is bool and type(event['callbackWasOnMainThread']) is bool,
                        'invalid callback flags')
                elapsed = (checked - close) * 1000
                result.update(weakCheckAfterCloseMilliseconds=elapsed, sourceWasWeakNil=event['sourceWasWeakNil'])
                # No epsilon is added to the actual 2000 ms requirement.
                if event['sourceWasWeakNil'] and elapsed <= 2000:
                    result['timing'] = 'weak-nil-confirmed-by-deadline'
            item[kind] = result
            confirmed.append(result['timing'] == 'weak-nil-confirmed-by-deadline')
        item['trackedPairTiming'] = 'weak-nil-confirmed-by-deadline' if all(confirmed) else 'inconclusive'
        timing.append(item)
    # Invoke the unchanged acceptance validator only on a reported pass. Failed
    # evidence is retained as failure, never filled in or relaxed for diagnostics.
    if callout['status'] == 'passed' or life['status'] == 'passed':
        spec = importlib.util.spec_from_file_location('original_annotation_checker', Path(__file__).with_name('check-annotation-details-report.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if callout['status'] == 'passed':
            module.validate_callouts(callout)
        else:
            module.validate_comment_lifecycle(life)
    original_passed = all(status == 'passed' for status in statuses.values())
    return {'status': 'observed' if original_passed else 'original-acceptance-failed',
            'diagnosticCompleteness': 'captured', 'originalAcceptance': statuses,
            'originalNativeFixturesPassed': original_passed,
            'fullInstallerAcceptanceClaimed': False, 'createdCycles': len(life['cycles']), 'expectedCycles': 6,
            'timing': timing, 'originalError': callout.get('error') or combined.get('error') or preview.get('error'),
            'limitations': ['Late/missing callbacks do not prove late last release',
                'Earlier weak-nil evidence describes this instrumented execution only',
                'The ordinary outer ui-preview.sh checker pipeline and full installer acceptance are not replaced by this diagnostic']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    native = commands.add_parser('native')
    native.add_argument('report'); native.add_argument('log'); native.add_argument('test_source')
    process = commands.add_parser('process'); process.add_argument('report')
    capture = commands.add_parser('capture')
    capture.add_argument('directory'); capture.add_argument('source'); capture.add_argument('output')
    capture.add_argument('--process-report', action='append', default=[])
    args = parser.parse_args()
    if args.command == 'native':
        validate_native(args.report, args.log, args.test_source); return 0
    if args.command == 'process':
        process_passed(args.report); return 0
    result = {'status': 'diagnostic-incomplete', 'diagnosticCompleteness': 'incomplete',
              'originalAcceptance': 'not-established', 'originalNativeFixturesPassed': False,
              'fullInstallerAcceptanceClaimed': False}
    try:
        result = validate_capture(args.directory, args.source, args.process_report)
    except (OSError, ValueError, KeyError, TypeError) as error:
        result['error'] = str(error)
        # Preserve raw gate status even if the diagnostic itself is invalid.
        for name, relative in [('earlyUINativeFixture', 'ui/preview.json'),
                               ('callout', 'ui/annotation-details/callouts/annotation-callouts.json')]:
            try:
                result.setdefault('reportedOriginalStatus', {})[name] = read_json(Path(args.directory) / relative).get('status', 'missing')
            except (OSError, ValueError, TypeError):
                pass
    output = Path(args.output); output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['diagnosticCompleteness'] == 'captured' and result['originalNativeFixturesPassed'] else 1


if __name__ == '__main__':
    sys.exit(main())
