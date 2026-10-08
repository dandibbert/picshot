#!/usr/bin/env python3
"""Plan disjoint XCTest processes and prove their union against native discovery.

This changes process isolation, not product deadlines. Each process keeps the
existing 420-second runner cap; the CI job remains independently bounded.
SwiftPM 6.1 supports `swift test list --skip-build` and regex test specifiers:
https://github.com/swiftlang/swift-package-manager/blob/swift-6.1.2-RELEASE/Sources/Commands/SwiftTestCommand.swift
"""

import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import sys


SPECIFIER = re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+/[A-Za-z_]\w*", re.ASCII)
CASE_EVENT = re.compile(r"Test Case '-\[([A-Za-z_][\w.]*) ([A-Za-z_]\w*)\]' "
                        r"(started|passed|failed|skipped)(?: \(([0-9.]+) seconds\))?\.", re.ASCII)
ALLOWED_SKIPS = {
    'PicShotMLHelperTests.FormulaEngineTests/testActualWeightsRecognizeFormulaFixtures',
    'PicShotTableEngineTests.RecordedModelOutputTests/testNativeHelperWithRealWeightsWhenConfigured',
    'PicShotEraseHelperTests.SmartEraseEngineTests/testRealCoreMLRemovesMarkedObjectAndPreservesOutsidePixels',
}
MAX_INVENTORY_BYTES = 2 * 1024 * 1024
MAX_LOG_BYTES = 8 * 1024 * 1024
PROCESS_SECONDS = 420
SUPPORTED_PROCESS_COUNTS = (2, 4)


def need(condition, message):
    if not condition:
        raise ValueError(message)


def bounded_text(path, limit):
    need(path.is_file() and not path.is_symlink(), f'Not a regular input: {path}')
    need(path.stat().st_size <= limit, f'Oversized input: {path}')
    return path.read_text(encoding='utf-8')


def discover(text):
    """Fail closed for unknown lines, duplicate IDs or a new test-library format."""
    need(len(text.encode('utf-8')) <= MAX_INVENTORY_BYTES, 'Inventory exceeds byte cap')
    names = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        # Observed SwiftPM 6.1 metadata in this exact project's native logs.
        # Do not ignore arbitrary diagnostics or unknown test-library output.
        if line == '[0/1] Planning build':
            continue
        need(SPECIFIER.fullmatch(line) is not None and len(line) <= 512,
             f'Unrecognized discovery line: {line[:160]}')
        names.append(line)
    need(0 < len(names) <= 20_000, 'Empty or oversized test inventory')
    need(len(names) == len(set(names)), 'Duplicate discovered test ID')
    return sorted(names)


def command_pattern(names):
    classes = collections.defaultdict(list)
    for name in names:
        cls, method = name.split('/')
        classes[cls].append(method)
    terms = [re.escape(cls) + '/(?:' + '|'.join(re.escape(x) for x in sorted(methods)) + ')'
             for cls, methods in sorted(classes.items())]
    pattern = '^(?:' + '|'.join(terms) + ')$'
    need(len(pattern.encode()) <= 96 * 1024, 'Regex exceeds bounded argv size')
    expression = re.compile(pattern)
    need(all(expression.fullmatch(x) for x in names), 'Regex omitted an assigned case')
    return pattern


def make_plan(inventory, selection, source, discovery_digest=None, process_count=2):
    need(re.fullmatch(r'[0-9a-f]{40}', source) is not None, 'Invalid source SHA')
    need(type(process_count) is int and process_count in SUPPORTED_PROCESS_COUNTS,
         'Supported process counts are exactly 2 or 4')
    selector = re.compile(selection) if selection else None
    selected = [name for name in inventory if selector is None or selector.search(name)]
    need(selected, 'Selection matches no tests')
    buckets = [[] for _ in range(process_count)]
    for name in selected:
        cls = name.split('/')[0]
        # Modulo four subdivides each modulo-two bucket without splitting classes.
        index = hashlib.sha256(cls.encode()).digest()[0] % process_count
        buckets[index].append(name)
    need(all(buckets), 'Every bounded process must contain tests')
    shards = []
    for index, names in enumerate(buckets):
        pattern = command_pattern(names)
        actual = [name for name in inventory if re.fullmatch(pattern, name)]
        need(actual == names, 'Filter differs from exact assigned inventory')
        shards.append({'index': index, 'tests': names, 'filter': pattern})
    need(sorted(x for shard in shards for x in shard['tests']) == selected,
         'Shards do not exactly cover the selection')
    discovery_digest = discovery_digest or hashlib.sha256(('\n'.join(inventory) + '\n').encode()).hexdigest()
    need(re.fullmatch(r'[0-9a-f]{64}', discovery_digest) is not None, 'Invalid discovery digest')
    return {'schemaVersion': 1, 'sourceCommit': source, 'selectionRegex': selection,
            'nativeDiscoverySHA256': discovery_digest,
            'discoveredTests': inventory, 'selectedTests': selected, 'shards': shards,
            'processCount': process_count, 'timeoutSecondsPerProcess': PROCESS_SECONDS,
            'sameProcessAsUnshardedSuite': False}


def checked_plan(path, expected_source=None):
    value = json.loads(bounded_text(path, 8 * 1024 * 1024))
    if expected_source is not None:
        need(value['sourceCommit'] == expected_source, 'Plan source differs from expected source SHA')
    inventory = value['discoveredTests']
    need(discover('\n'.join(inventory)) == inventory, 'Invalid canonical inventory')
    raw = bounded_text(path.parent / 'native-test-discovery.log', MAX_INVENTORY_BYTES)
    need(discover(raw) == inventory, 'Plan omitted or changed native discovery')
    expected = make_plan(inventory, value['selectionRegex'], value['sourceCommit'],
                         hashlib.sha256(raw.encode()).hexdigest(), value['processCount'])
    need(value == expected, 'Plan does not match deterministic complete inventory')
    return value


def case_results(log, expected):
    events = collections.defaultdict(list)
    for match in CASE_EVENT.finditer(log):
        events[match[1] + '/' + match[2]].append(match[3])
    need(set(events) == set(expected),
         f'Native results differ: missing={sorted(set(expected)-set(events))[:8]}, '
         f'extra={sorted(set(events)-set(expected))[:8]}')
    passed, skipped = [], []
    for name in expected:
        sequence = events[name]
        need(sequence in (['started', 'passed'], ['started', 'skipped']),
             f'Failed, repeated or unfinished case: {name}: {sequence}')
        if sequence[-1] == 'skipped':
            need(name in ALLOWED_SKIPS, f'Unapproved native skip: {name}')
            skipped.append(name)
        else:
            passed.append(name)
    return passed, skipped


def paths(directory, index):
    return directory / f'shard-{index}.log', directory / f'shard-{index}-runner.json'


def expected_command(shard):
    return ['swift', 'test', '--skip-build', '--filter', shard['filter']]


def aggregate(plan, directory):
    passed, skipped, records = [], [], []
    for shard in plan['shards']:
        log_path, report_path = paths(directory, shard['index'])
        wrapper = json.loads(bounded_text(report_path, 1024 * 1024))
        need(wrapper['status'] == 'exited' and wrapper['termination_reason'] == 'exited'
             and wrapper['child_returncode'] == wrapper['exit_code'] == 0,
             'Native bounded process did not exit successfully')
        need(wrapper['timeout_seconds'] == PROCESS_SECONDS and not wrapper['log_truncated'],
             'Changed native deadline or truncated log')
        need(wrapper['command'] == expected_command(shard), 'Executed filter differs from plan')
        log = bounded_text(log_path, MAX_LOG_BYTES)
        need(wrapper['log_bytes'] == len(log.encode('utf-8')), 'Native log length mismatch')
        p, s = case_results(log, shard['tests'])
        passed += p; skipped += s
        records.append({'index': shard['index'], 'total': len(p) + len(s), 'passed': len(p),
                        'skipped': s, 'durationSeconds': wrapper['duration_seconds'],
                        'logSHA256': hashlib.sha256(log.encode()).hexdigest()})
    seen = passed + skipped
    need(len(seen) == len(set(seen)) and sorted(seen) == plan['selectedTests'],
         'Missing or duplicate aggregate native cases')
    return {'schemaVersion': 1, 'status': 'passed', 'sourceCommit': plan['sourceCommit'],
            'discoveredCount': len(plan['discoveredTests']), 'selectedCount': len(seen),
            'passedCount': len(passed), 'skippedCount': len(skipped), 'skippedTests': sorted(skipped),
            'selectionRegex': plan['selectionRegex'], 'shards': records,
            'processCount': plan['processCount'], 'timeoutSecondsPerProcess': PROCESS_SECONDS,
            'sameProcessAsUnshardedSuite': False,
            'scope': 'Every selected discovered XCTest ran once across '
                     + {2: 'two', 4: 'four'}[plan['processCount']] + ' disjoint native processes; '
                     'not one shared-process suite or a product performance-threshold change'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    p = sub.add_parser('plan'); p.add_argument('--inventory', type=Path, required=True)
    p.add_argument('--source', required=True); p.add_argument('--selection-regex', default='')
    p.add_argument('--process-count', type=int, choices=SUPPORTED_PROCESS_COUNTS, default=2)
    p.add_argument('--output', type=Path, required=True)
    r = sub.add_parser('run'); r.add_argument('--plan', type=Path, required=True)
    r.add_argument('--index', type=int, choices=range(max(SUPPORTED_PROCESS_COUNTS)), required=True)
    r.add_argument('--expected-source')
    r.add_argument('--directory', type=Path, required=True)
    c = sub.add_parser('check'); c.add_argument('--plan', type=Path, required=True)
    c.add_argument('--expected-source')
    c.add_argument('--directory', type=Path, required=True); c.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'plan':
        raw = bounded_text(args.inventory, MAX_INVENTORY_BYTES)
        need(args.inventory.resolve() == (args.output.parent / 'native-test-discovery.log').resolve(),
             'Keep original native discovery beside its plan')
        plan = make_plan(discover(raw), args.selection_regex, args.source,
                         hashlib.sha256(raw.encode()).hexdigest(), args.process_count)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(plan, indent=2) + '\n')
        print(json.dumps({'discovered': len(plan['discoveredTests']), 'selected': len(plan['selectedTests']),
                          'shardCounts': [len(s['tests']) for s in plan['shards']]}))
    elif args.action == 'run':
        plan = checked_plan(args.plan, args.expected_source)
        need(args.index < plan['processCount'], 'Process index is outside the verified plan')
        shard = plan['shards'][args.index]
        args.directory.mkdir(parents=True, exist_ok=True)
        log, report = paths(args.directory, args.index)
        wrapper = Path(__file__).with_name('run-bounded-command.py').resolve()
        argv = [sys.executable, str(wrapper), '--timeout-seconds', str(PROCESS_SECONDS),
                '--log', str(log), '--report', str(report), '--', *expected_command(shard)]
        os.execv(sys.executable, argv)
    else:
        report = aggregate(checked_plan(args.plan, args.expected_source), args.directory)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, TypeError) as error:
        print(f'Native shard verification failed: {error}', file=sys.stderr)
        raise SystemExit(1)
