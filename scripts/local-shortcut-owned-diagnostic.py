#!/usr/bin/env python3
"""Diagnose local-shortcut XCTest with at most two explicitly selected cells.

Supply verified current checkout/plan/inventory and freshly compiled executable
identities explicitly. This never builds, installs, discovers processes, changes
tests, or substitutes for native-suite or installer acceptance. Run the single
method first; group0 requires its verified pass and the same compiled bundle.
The historical
owned runner, its 420-second cap and 180/360-second sample slots are unchanged.
"""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('shortcut_owned_xctest',
    Path(__file__).with_name('native-owned-xctest.py'))
O = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(O)
D, N, need, save = O.D, O.N, O.need, O.save
METHOD = ('PicShotTests.LocalAnnotationShortcutNativeTests/'
          'testNativeSheetMenuAndOtherWindowBlockCanvasShortcutRouting')
SLOTS = (180, 360)
GROUP0_SHA256 = 'c979913e1543ab86c0483d8320a9ad6a598cdf2685957d61d1f02344cc855448'
INVENTORY_SHA256 = '926ac5674df90163b949fe461f0d4589ef72c8fc3215fa00b927564aae57cb44'
SCOPE = 'Owned local-shortcut diagnosis; not native-suite or installer acceptance'


def expectations(args):
    for name, length in (('expected_source', 40), ('expected_tree', 40),
            ('expected_plan_sha256', 64), ('expected_inventory_sha256', 64),
            ('expected_bundle_sha256', 64)):
        need(re.fullmatch('[0-9a-f]{' + str(length) + '}', getattr(args, name)) is not None,
             'Invalid explicit identity: ' + name)
    need(args.expected_inventory_sha256 == INVENTORY_SHA256,
         'Inventory differs from the verified 2,047-method candidate')


def selection_ids(plan, mode):
    need(mode in ('single', 'group0'), 'Unknown diagnostic cell')
    need(METHOD in plan['selectedTests'], 'Required method is absent from verified plan selection')
    if mode == 'single':
        return [METHOD]
    names = plan['shards'][0]['tests']
    need(plan['processCount'] == 2 and len(names) == 75 and METHOD in names
         and O.ids_digest(names) == GROUP0_SHA256, 'Group0 differs from exact 195 early 75-method selection')
    return names


def plan_inputs(args, evidence):
    plan = N.checked_plan(args.plan, args.expected_source)
    identity = O.file_identity(args.plan)
    need(identity['sha256'] == args.expected_plan_sha256, 'Plan SHA-256 differs')
    need(O.ids_digest(plan['discoveredTests']) == args.expected_inventory_sha256
         and len(plan['discoveredTests']) == 2047
         and len({name.split('/')[0] for name in plan['discoveredTests']}) == 232,
         'Complete discovered inventory SHA-256 differs')
    need(plan['timeoutSecondsPerProcess'] == 420 and METHOD in plan['selectedTests'],
         'Required method is absent from the verified plan selection or cap differs')
    # checked_plan proves canonical, unique IDs and exact agreement with the raw
    # discovery. Selection is one literal member, never a regex/class shortcut.
    (evidence / 'plan.json').write_bytes(args.plan.read_bytes())
    discovery = args.plan.parent / 'native-test-discovery.log'
    (evidence / discovery.name).write_bytes(discovery.read_bytes())
    names = selection_ids(plan, args.selection)
    return dict(plan=identity, discovery=O.file_identity(discovery), selectionMode=args.selection,
        fullInventorySHA256=args.expected_inventory_sha256,
        discoveredCount=len(plan['discoveredTests']),
        discoveredClassCount=len({name.split('/')[0] for name in plan['discoveredTests']}),
        selectedIDs=names, selectedIDsSHA256=O.ids_digest(names))


def source_inputs(args, source, evidence, query):
    """Current-source guard; immutable145's source constants stay untouched."""
    record = dict(sourceCommit=query(['git', 'rev-parse', 'HEAD'], source),
        sourceTree=query(['git', 'rev-parse', 'HEAD^{tree}'], source),
        trackedStatus=query(['git', 'status', '--porcelain', '--untracked-files=no'], source, raw=True),
        buildInputStatus=query(['git', 'status', '--porcelain', '--untracked-files=all', '--',
            'Package.swift', 'Package.resolved', 'Sources', 'Tests'], source, raw=True),
        packageResolved=dict(status='absent'))
    for key, name in (('trackedStatus', 'tracked-status.txt'), ('buildInputStatus', 'build-input-status.txt')):
        (evidence / name).write_text(record[key], encoding='utf-8')
    save(evidence / 'source-inputs.json', record)
    need(record['sourceCommit'] == args.expected_source and record['sourceTree'] == args.expected_tree,
         'Current source commit/tree differs from explicit identity')
    need(record['trackedStatus'] == '', 'Tracked source is modified')
    need(record['buildInputStatus'] in ('', '?? Package.resolved\n'),
         'Untracked or modified build inputs beyond generated Package.resolved')
    lock = source / 'Package.resolved'
    if lock.exists() or lock.is_symlink():
        need(not lock.is_symlink() and lock.is_file(), 'Package.resolved is not a regular file')
        descriptor = os.open(lock, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'rb') as stream:
            need(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), 'Package.resolved is not regular')
            data = stream.read(O.RESOLVED_LIMIT + 1)
        need(0 < len(data) <= O.RESOLVED_LIMIT, 'Package.resolved exceeds bounded file size')
        (evidence / 'Package.resolved').write_bytes(data)
        need(record['buildInputStatus'] == '?? Package.resolved\n', 'Generated lock status differs')
        record['packageResolved'] = dict(status='verified-generated', bytes=len(data),
            sha256=O.sha(data), resolved=O.resolved_pin(data))
    else:
        need(record['buildInputStatus'] == '', 'Generated lock is missing')
    save(evidence / 'source-inputs.json', record)
    return record


def launch_inputs(args):
    need(sys.platform == 'darwin', 'Owned native diagnostic requires macOS')
    expectations(args)
    deadline = time.monotonic() + O.SETUP_SECONDS
    def query(argv, cwd=None, raw=False):
        remaining = deadline - time.monotonic()
        need(remaining > 0, 'Launch setup deadline exceeded')
        return O.bounded_read(argv, cwd, timeout=min(20, remaining), strip=not raw)
    source = args.source_root.resolve(strict=True)
    evidence = args.directory.with_name(args.directory.name + '-inputs')
    need(not args.directory.exists() and not args.directory.is_symlink(), 'Output directory already exists')
    evidence.mkdir(parents=True, exist_ok=False)
    plan = plan_inputs(args, evidence)
    source_evidence = source_inputs(args, source, evidence, query)
    # Same selected-Xcode, platform, Mach-O and canonical-bundle checks as the
    # historical launch_inputs, without rebinding its immutable source globals.
    selected = query(['/usr/bin/xcode-select', '-p'])
    developer = Path(os.environ.get('DEVELOPER_DIR') or selected).resolve(strict=True)
    if developer.suffix == '.app':
        developer = developer / 'Contents/Developer'
    entry = Path(query(['/usr/bin/xcrun', '--sdk', 'macosx', '--find', 'xctest']))
    resolved_entry = entry.resolve(strict=True)
    need(developer in resolved_entry.parents, 'XCTest entry is outside selected Xcode')
    platform = Path(os.environ.get('SWIFTPM_PLATFORM_PATH_macosx') or query(
        ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'])).resolve(strict=True)
    need(platform == developer / 'Platforms/MacOSX.platform', 'Unexpected selected macOS platform')
    executable = (platform / 'Developer/Library/Xcode/Agents/xctest').resolve(strict=True)
    need(platform in executable.parents, 'Direct XCTest agent escaped selected platform')
    with executable.open('rb') as stream:
        need(stream.read(4) in (b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xce',
             b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'),
             'Direct XCTest agent is not a Mach-O executable')
    bin_path = Path(query(['/usr/bin/xcrun', 'swift', 'build', '--show-bin-path'], source)).resolve(strict=True)
    bundle = args.bundle.resolve(strict=True)
    layout = O.bundle_inputs(source, bundle, bin_path, evidence, deadline)
    entries = {name: {key: row[key] for key in ('bytes', 'sha256')}
        for name, row in layout['inventory'].items() if row['kind'] == 'file'}
    binary = entries['Contents/MacOS/PicShotPackageTests']
    need(binary['sha256'] == args.expected_bundle_sha256, 'Compiled bundle executable SHA-256 differs')
    env = O.test_environment(os.environ, platform, 'baseline')
    identity = dict(sourceCommit=args.expected_source, sourceTree=args.expected_tree,
        sourceRoot=str(source), sourceInputEvidence=source_evidence, planEvidence=plan,
        xcodeDeveloperDirectory=str(developer), xcodeSelectDirectory=selected,
        developerDirectoryOverride=os.environ.get('DEVELOPER_DIR'),
        xcrunEntryPath=str(entry), xcrunResolvedPath=str(resolved_entry),
        xcrunEntry=O.file_identity(resolved_entry, deadline), xctestPath=str(executable),
        xctest=O.file_identity(executable, deadline), bundlePath=str(bundle),
        bundleLayoutEvidence=layout, bundleExecutable=binary, bundleFiles=entries,
        bundleManifestSHA256=O.sha(json.dumps(entries, sort_keys=True).encode()),
        xcodeVersion=query(['/usr/bin/xcodebuild', '-version']),
        swiftVersion=query(['/usr/bin/xcrun', 'swift', '--version']),
        swiftPackageVersion=query(['/usr/bin/xcrun', 'swift', 'package', '--version']),
        runtimeEnvironment={key: env.get(key) for key in ('DYLD_FRAMEWORK_PATH', 'DYLD_LIBRARY_PATH',
            'SWIFT_TESTING_ENABLED', 'NO_COLOR', 'NSUnbufferedIO')},
        helperFiles={name: O.file_identity(Path(__file__).with_name(name), deadline) for name in (
            Path(__file__).name, 'native-owned-xctest.py', 'native-test-diagnostics.py',
            'native-test-shards.py', 'run-bounded-command.py')},
        limits=dict(setupSeconds=O.SETUP_SECONDS, nativeSeconds=420, samplerSeconds=O.SAMPLER_SECONDS,
            sampleCollectionSeconds=D.SAMPLE_SECONDS, sampleIntervalMilliseconds=D.SAMPLE_INTERVAL_MS))
    need(time.monotonic() < deadline, 'Launch setup deadline exceeded')
    save(evidence / 'launch-inputs.json', identity)
    return identity, env


def validate_process(directory, report, identity):
    evidence = directory.with_name(directory.name + '-inputs')
    need(json.loads(N.bounded_text(evidence / 'launch-inputs.json', D.METADATA_CAP)) == identity,
         'Raw launch inputs differ')
    source = identity['sourceInputEvidence']
    need(json.loads(N.bounded_text(evidence / 'source-inputs.json', D.METADATA_CAP)) == source
         and source['sourceCommit'] == identity['sourceCommit']
         and source['sourceTree'] == identity['sourceTree'] and source['trackedStatus'] == '',
         'Raw source identity differs')
    for key, name in (('trackedStatus', 'tracked-status.txt'), ('buildInputStatus', 'build-input-status.txt')):
        need(N.bounded_text(evidence / name, 64 * 1024) == source[key], 'Raw source status differs')
    lock = source['packageResolved']
    if lock['status'] == 'verified-generated':
        path = evidence / 'Package.resolved'
        need(O.file_identity(path) == {key: lock[key] for key in ('bytes', 'sha256')}
             and path.stat().st_size <= O.RESOLVED_LIMIT
             and O.resolved_pin(path.read_bytes()) == lock['resolved'], 'Raw generated lock differs')
    else:
        need(lock['status'] == 'absent' and source['buildInputStatus'] == ''
             and not (evidence / 'Package.resolved').exists(), 'Absent generated lock differs')
    plan = N.checked_plan(evidence / 'plan.json', identity['sourceCommit'])
    bound = identity['planEvidence']
    names = selection_ids(plan, bound['selectionMode'])
    need(O.file_identity(evidence / 'plan.json') == bound['plan']
         and O.file_identity(evidence / 'native-test-discovery.log') == bound['discovery']
         and O.ids_digest(plan['discoveredTests']) == bound['fullInventorySHA256']
         and bound['selectedIDs'] == names
         and bound['selectedIDsSHA256'] == O.ids_digest(names), 'Raw plan or selected ID differs')
    need(json.loads(N.bounded_text(directory / 'process.json', D.METADATA_CAP)) == report,
         'Raw process report differs')
    need(report['command'] == O.command(identity['xctestPath'], identity['bundlePath'], names)
         and report['timeoutSeconds'] == 420 and report['samplerTimeoutSeconds'] == O.SAMPLER_SECONDS
         and report['expectedCaptureSlots'] == list(SLOTS), 'Command or native/sample limits differ')
    need(report['diagnosticOnly'] is True and report['installerAcceptance'] is False
         and report['cleanupConfirmed'] is True and report['outputEOF'] is True
         and not report['errors'] and report['logTruncated'] is False
         and report['cancellationSignal'] is None and report['status'] in ('exited', 'timeout'),
         'Incomplete native output, observation or cleanup')
    need(O.file_identity(directory / 'xctest.log') == report['logIdentity'], 'Raw XCTest log differs')
    root = report['root']
    target = root['identity']
    need(target is not None and not root['bindingError'] and not root.get('emergencyCleanup')
         and not root.get('identityMismatch') and root['cleanupConfirmed'] is True
         and target['pid'] == target['groupID'] == root['pid']
         and target['parentPID'] == root['ownerPID']
         and target['executable'] == identity['xctestPath']
         and root['returnCode'] == report['rootReturnCode']
         and root['retirementEvidence'] == 'unreaped-exit-observation-then-Popen-wait',
         'Root process ownership or retirement differs')
    elapsed = report['workloadEndSeconds']
    need(type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 0,
         'Invalid workload duration')
    due = [slot for slot in SLOTS if slot <= elapsed]
    need(report['dueCaptureSlots'] == due and [c['slotSeconds'] for c in report['captures']] == due,
         'Required stack samples are missing or duplicated')
    if report['status'] == 'timeout':
        need(elapsed >= 420 and report['terminationStartedAtSeconds'] >= 420 and due == list(SLOTS),
             'Timeout did not preserve the 420-second workload cap')
    for capture in report['captures']:
        need(capture['slotSeconds'] <= capture['startedAtSeconds'] <= elapsed,
             'Sample launch time differs from workload interval')
        O.validate_capture(directory, capture, root)
    O.verify_bundle_inputs(directory, identity)
    log = N.bounded_text(directory / 'xctest.log', N.MAX_LOG_BYTES)
    cases = O.assess(report, log, names)
    need(not cases['unexpectedIDs'], 'Unexpected native methods ran')
    need(all(sequence in (['started'], ['started', 'passed'], ['started', 'failed'])
             for sequence in cases['observedEvents'].values()), 'Duplicate, skipped or invalid method events')
    return cases


def verify_single_pass(directory, identity):
    previous = json.loads(N.bounded_text(directory / 'result.json', D.METADATA_CAP))
    expected = {**identity, 'planEvidence': {**identity['planEvidence'], 'selectionMode': 'single',
        'selectedIDs': [METHOD], 'selectedIDsSHA256': O.ids_digest([METHOD])}}
    need(previous['schemaVersion'] == 1 and previous['scope'] == SCOPE
         and previous['diagnosticOnly'] is True and previous['installerAcceptance'] is False
         and previous['evidenceStatus'] == 'verified' and previous['inputs'] == expected,
         'Single-pass receipt or same source/toolchain/environment/bundle identity differs')
    cases = validate_process(directory, previous['process'], previous['inputs'])
    need(cases == previous['cases'] and cases['status'] == 'passed'
         and previous['process']['status'] == 'exited' and previous['process']['rootReturnCode'] == 0,
         'Single-method diagnostic did not pass with verified evidence')
    return dict(directory=str(directory), result=O.file_identity(directory / 'result.json'))


def run(args):
    args.directory = args.directory.resolve()
    need((args.selection == 'group0') is (args.single_pass is not None),
         'Group0 requires --single-pass; the single cell cannot reuse a receipt')
    identity, env = launch_inputs(args)
    prior = verify_single_pass(args.single_pass.resolve(strict=True), identity) if args.single_pass else None
    report = O.run_owned(O.command(identity['xctestPath'], identity['bundlePath'],
        identity['planEvidence']['selectedIDs']),
        env, identity['sourceRoot'], args.directory, D.ProcessIdentity(), timeout=420, slots=SLOTS)
    result = dict(schemaVersion=1, scope=SCOPE, diagnosticOnly=True, installerAcceptance=False,
        inputs=identity, singlePassReceipt=prior, process=report, evidenceStatus='rejected', cases=None)
    try:
        result['cases'] = validate_process(args.directory, report, identity)
        result['evidenceStatus'] = 'verified'
    except (ValueError, OSError, KeyError, TypeError) as error:
        result['evidenceError'] = str(error)
    save(args.directory / 'result.json', result)
    print(json.dumps(dict(evidenceStatus=result['evidenceStatus'], processStatus=report['status'],
        caseStatus=result['cases']['status'] if result['cases'] else 'unverified',
        cleanupConfirmed=report['cleanupConfirmed'], diagnosticOnly=True, installerAcceptance=False)))
    if result['evidenceStatus'] != 'verified':
        return 1
    return 0 if result['cases']['status'] == 'passed' else 124 if report['status'] == 'timeout' else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--selection', choices=('single', 'group0'), required=True)
    parser.add_argument('--single-pass', type=Path)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    for name in ('source', 'tree', 'plan-sha256', 'inventory-sha256', 'bundle-sha256'):
        parser.add_argument('--expected-' + name, required=True)
    return run(parser.parse_args(argv))


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('Local-shortcut diagnostic rejected: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
