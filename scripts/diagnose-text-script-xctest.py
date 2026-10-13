#!/usr/bin/env python3
"""Own only the failing editor XCTest, then the original70 if it passes.

Diagnostic only. Reuses the existing direct-child lifecycle and exact XCTest
selectors; the historical145 CLI and every product/runtime byte stay unchanged.
"""
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time

sys.dont_write_bytecode = True


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


O = module('text_script_owned_xctest', 'native-owned-xctest.py')
C = module('text_script_bounded_ips', 'collect-text-script-crash.py')
N = O.N
need, save = O.need, O.save
METHOD = 'PicShotTests.TextScriptControllerTests/testNewDraftIsNotAutoSavedByCloseQuitSelectionOrReopen'
IDS_SHA256 = '3e22a7bccdf8f10e80cbb8e997f2b190dfbc905f891e09653dcee700776398c3'
SOURCE_IDS_SHA256 = '1a24e427fed9858995d3cd7e4b74b660218f3746270c67f8bc2999f2b0bf62eb'
FULL_IDS_SHA256 = 'a0c689a7a9e82bbf30bee2f72bb26b574e32f66ac2edd23fafeda3ac7f89967d'
SCOPE = 'Direct owned XCTest editor-crash diagnostic; not SwiftPM reproduction, installer or runtime acceptance'
PHASES = ['fixture-before', 'fixture-after', 'first-new-before', 'first-new-after', 'first-quit-before', 'first-quit-after', 'dirty-close-before', 'dirty-close-after', 'unsaved-assertions-after', 'discard-before', 'discard-after', 'discarded-quit-before', 'discarded-quit-after', 'second-new-before', 'second-new-after', 'save-before', 'save-after', 'saved-quit-before', 'saved-quit-after', 'restored-init-before', 'restored-init-after', 'restored-assertions-after', 'restored-close-before', 'restored-close-after', 'original-close-before', 'original-close-after']
PHASE_PREFIX = 'PICSHOT_TEXT_SCRIPT_LIFECYCLE '
PHASE_PATTERN = re.compile(r'PICSHOT_TEXT_SCRIPT_LIFECYCLE phase=([a-z-]+) pid=([0-9]+) running=([01]) active=([01]) policy=(-?[0-9]+) visible=(-?[01])')


def source_guard(root, source):
    need(re.fullmatch('[0-9a-f]{40}', source), 'Expected exact current source commit')
    need(O.bounded_read(['git', 'rev-parse', 'HEAD'], root) == source, 'Current source commit differs')
    need(O.bounded_read(['git', 'status', '--porcelain', '--untracked-files=no'], root) == '',
         'Tracked source changed during diagnostic')
    build_status = O.bounded_read(['git', 'status', '--porcelain', '--untracked-files=all', '--',
                                  'Package.swift', 'Package.resolved', 'Sources', 'Tests'], root, strip=False)
    need(build_status in ('', '?? Package.resolved\n'), 'Unexpected untracked or modified build input')
    if (root/'Package.resolved').exists():
        O.resolved_pin(C.read(root/'Package.resolved', O.RESOLVED_LIMIT))
    return O.bounded_read(['git', 'rev-parse', 'HEAD^{tree}'], root)


def selection(root, inventory_path):
    raw = N.bounded_text(inventory_path, N.MAX_INVENTORY_BYTES)
    discovered = N.discover(raw)
    need(len(discovered) == 2373 and O.ids_digest(discovered) == FULL_IDS_SHA256,
         'Actual discovery differs from unchanged258 inventory')
    path = root/'scripts/text-script-integration-tests.json'
    data = C.read(path, 128*1024)
    need(C.sha(data) == SOURCE_IDS_SHA256, 'Original70 source inventory bytes changed')
    names = C.decode(data)
    need(type(names) is list and names == sorted(set(names)) and len(names) == 70
         and O.ids_digest(names) == IDS_SHA256 and METHOD in names
         and names == [name for name in discovered if '.TextScript' in name], 'Exact70 discovered script IDs differ')
    ordered = [line.strip() for line in raw.splitlines() if line.strip() in set(names)]
    need(sorted(ordered) == names, 'Original discovery order lost a script method')
    return ordered, O.file_identity(inventory_path)


def launch_inputs(root, directory, source):
    deadline = time.monotonic() + O.SETUP_SECONDS
    tree = source_guard(root, source)
    def query(command, cwd=None):
        remaining = deadline-time.monotonic()
        need(remaining > 0, 'Diagnostic setup deadline exceeded')
        return O.bounded_read(command, cwd, timeout=min(20, remaining))
    selected = query(['/usr/bin/xcode-select', '-p'])
    developer = Path(os.environ.get('DEVELOPER_DIR') or selected).resolve(strict=True)
    if developer.suffix == '.app':
        developer /= 'Contents/Developer'
    platform = Path(query(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'])).resolve(strict=True)
    need(platform == developer/'Platforms/MacOSX.platform', 'Selected Xcode platform differs')
    agent = (platform/'Developer/Library/Xcode/Agents/xctest').resolve(strict=True)
    need(platform in agent.parents and agent.is_file(), 'XCTest agent is outside selected Xcode')
    bin_path = Path(query(['/usr/bin/xcrun', 'swift', 'build', '--show-bin-path'], root)).resolve(strict=True)
    bundle = bin_path/'PicShotPackageTests.xctest'
    evidence = directory/'inputs'
    evidence.mkdir()
    layout = O.bundle_inputs(root, bundle, bin_path, evidence, deadline)
    binary = bundle/'Contents/MacOS/PicShotPackageTests'
    identity = dict(sourceCommit=source, sourceTree=tree, sourceRoot=str(root),
        xctestPath=str(agent), xctest=O.file_identity(agent, deadline),
        bundlePath=str(bundle), bundleLayout=layout, bundleExecutable=O.file_identity(binary, deadline),
        selectedXcode=selected, effectiveDeveloperDirectory=str(developer),
        xcodeVersion=query(['/usr/bin/xcodebuild', '-version']),
        swiftVersion=query(['/usr/bin/xcrun', 'swift', '--version']),
        osVersion=query(['/usr/bin/sw_vers']),
        testSource=O.file_identity(root/'Tests/PicShotTests/TextScriptControllerTests.swift'),
        adapterSources={name: O.file_identity(root/'scripts'/name) for name in
                       ('diagnose-text-script-xctest.py','native-owned-xctest.py','native-test-diagnostics.py',
                        'native-test-shards.py','run-bounded-command.py','collect-text-script-crash.py')})
    need(identity['testSource']['sha256'] == '3ff1b498be6878e3f1722a2d2c6e002f10b7d270b453935e82a46102835525ec', 'Test-only phase instrumentation differs')
    need(time.monotonic() < deadline, 'Diagnostic setup exceeded original60 second allowance')
    env = O.test_environment(os.environ, platform, 'baseline')
    env['PICSHOT_TEXT_SCRIPT_LIFECYCLE_DIAGNOSTIC'] = '1'
    identity['runtimeEnvironment'] = {key: env.get(key) for key in
        ('DYLD_FRAMEWORK_PATH','DYLD_LIBRARY_PATH','SWIFT_TESTING_ENABLED','NO_COLOR','NSUnbufferedIO',
         'PICSHOT_TEXT_SCRIPT_LIFECYCLE_DIAGNOSTIC')}
    save(evidence/'identity.json', identity)
    return identity, env


def match_crash(body, binding):
    root = binding['ownedIdentity']
    need(type(body.get('pid')) is int and body['pid'] == root['pid'] and body.get('procName') == 'xctest',
         'Foreign crash PID/name')
    need(body.get('procPath') == root['executable'], 'Foreign or redacted XCTest path')
    need(type(body.get('parentPid')) is int and body['parentPid'] == root['parentPID'],
         'Missing or foreign crash parent')
    start, end = C.timestamp(binding['startUTC']), C.timestamp(binding['endUTC'])
    launch, capture = C.timestamp(body.get('procLaunch')), C.timestamp(body.get('captureTime'))
    birth = dt.datetime.fromtimestamp(root['birthSeconds'] + root['birthMicroseconds']/1e6, dt.timezone.utc)
    need(start <= birth <= end and start <= launch <= end and abs((launch-birth).total_seconds()) <= .01
         and launch <= capture <= end + dt.timedelta(seconds=C.POLL_SECONDS), 'Crash is outside owned birth/run window')
    return True


def crash_details(body):
    # Exclude application-specific free text, thread state/registers, VM maps,
    # unrelated threads and raw image paths. Keep only OS cause and crash symbols.
    allowed = {key: body[key] for key in ('exception','termination','threads','usedImages','faultingThread') if key in body}
    return C.extract(allowed)


def collect_crash(binding):
    result = dict(status='absent', reason='no-exact-owned-xctest-ips-within15s',
        pollLimitSeconds=C.POLL_SECONDS, candidateLimit=C.MAX_CANDIDATES, candidateReadLimit=C.MAX_READS,
        reportByteLimit=C.REPORT_LIMIT, rawReportsCopied=False, unifiedLogsCollected=False,
        unrelatedProcessesInspected=False, legacyCrashTextInspected=False)
    start = time.monotonic()
    earliest = C.timestamp(binding['startUTC']).timestamp()
    latest = C.timestamp(binding['endUTC']).timestamp()+C.POLL_SECONDS
    seen, candidates, reads = set(), set(), 0
    roots = [('runner', Path.home()/'Library/Logs/DiagnosticReports'),
             ('system', Path('/Library/Logs/DiagnosticReports'))]
    while time.monotonic()-start < C.POLL_SECONDS:
        for scope, directory in roots:
            try:
                fd = C.open_directory(directory)
            except OSError:
                continue
            try:
                with os.scandir(fd) as entries:
                    for count, entry in enumerate(entries):
                        if count >= 512 or time.monotonic()-start >= C.POLL_SECONDS:
                            break
                        name = entry.name
                        if not name.startswith('xctest-') or not name.endswith('.ips'):
                            continue
                        key = (scope, name)
                        try:
                            info = entry.stat(follow_symlinks=False)
                            if info.st_mtime < earliest or info.st_mtime > latest:
                                continue
                            if key not in candidates and len(candidates) >= C.MAX_CANDIDATES:
                                continue
                            candidates.add(key)
                            stamp = (key, info.st_ino, info.st_size, info.st_mtime_ns)
                            if stamp in seen or reads >= C.MAX_READS:
                                continue
                            seen.add(stamp); reads += 1
                            data = C.read_at(fd, name, C.REPORT_LIMIT)
                            body = C.parse_ips(data)
                            match_crash(body, binding)
                            result.update(status='observed', reason='exact-owned-xctest-crash',
                                match='direct-owned-pid-executable-parent-birth-time-and-run-window',
                                reportIdentity=dict(directoryScope=scope, name=name, bytes=len(data), sha256=C.sha(data)),
                                procLaunch=body['procLaunch'], captureTime=body['captureTime'], details=crash_details(body))
                            need(len(json.dumps(result).encode()) <= C.OUTPUT_LIMIT, 'Crash summary exceeds existing cap')
                            return result
                        except (OSError, ValueError, TypeError, KeyError, RecursionError, OverflowError):
                            continue
            finally:
                os.close(fd)
        if reads >= C.MAX_READS:
            break
        time.sleep(min(.5, max(0, C.POLL_SECONDS-(time.monotonic()-start))))
    return result


def phase_markers(log, pid):
    rows = []
    for line in log.splitlines():
        if not line.startswith(PHASE_PREFIX):
            continue
        match = PHASE_PATTERN.fullmatch(line)
        need(match is not None, 'Malformed fixed phase marker')
        phase, observed_pid, running, active, policy, visible = match.groups()
        need(int(observed_pid) == pid and len(rows) < len(PHASES) and phase == PHASES[len(rows)],
             'Phase marker PID/order differs from directly owned test')
        rows.append(dict(phase=phase, pid=pid, running=int(running), active=int(active),
                         policy=int(policy), visible=int(visible)))
    return rows


def verify_owned(process, identity):
    root = process.get('root', {})
    target = root.get('identity')
    need(type(target) is dict and target['pid'] == target['groupID'] == root['pid']
         and target['parentPID'] == root['ownerPID'] and target['executable'] == identity['xctestPath']
         and root['bindingError'] is None and root['cleanupConfirmed'] is True
         and root.get('returnCode') == process.get('rootReturnCode'), 'Exact XCTest root binding/cleanup missing')
    need(process['timeoutSeconds'] == 420 and process['expectedCaptureSlots'] == [] and process['captures'] == []
         and process['cleanupConfirmed'] is True and process['outputEOF'] is True
         and process['logTruncated'] is False and not process['errors'], 'Incomplete owned diagnostic lifecycle')
    return target


def run_phase(phase, names, root, directory, identity, env):
    source_guard(root, identity['sourceCommit'])
    layout = O.bundle_inputs(root, Path(identity['bundlePath']), Path(identity['bundlePath']).parent, None, time.monotonic()+60)
    need(layout == identity['bundleLayout'], 'Compiled test bundle changed between cells')
    command = O.command(identity['xctestPath'], identity['bundlePath'], names)
    start = dt.datetime.now(dt.timezone.utc).isoformat()
    process = O.run_owned(command, env, str(root), directory, O.D.ProcessIdentity(), timeout=420, slots=())
    end = dt.datetime.now(dt.timezone.utc).isoformat()
    result = dict(schemaVersion=1, diagnosticOnly=True, installerAcceptance=False, runtimeAcceptance=False,
        sourceCommit=identity['sourceCommit'], phase=phase, scope=SCOPE, expectedIDs=names,
        selectedIDsSHA256=O.ids_digest(sorted(names)), process=process, startUTC=start, endUTC=end,
        crash=dict(status='not-requested', reason='no-owned-signal-exit'), status='failed')
    save(directory/'result.json', result)
    try:
        target = verify_owned(process, identity)
        if type(process.get('rootReturnCode')) is int and process['rootReturnCode'] < 0 and not process['root']['signals']:
            result['crash'] = collect_crash(dict(ownedIdentity=target, startUTC=start, endUTC=end))
        log = N.bounded_text(directory/'xctest.log', N.MAX_LOG_BYTES)
        need(O.file_identity(directory/'xctest.log') == process['logIdentity'], 'Owned raw log identity differs')
        result['phaseMarkers'] = phase_markers(log, target['pid'])
        result['cases'] = O.assess(process, log, names)
        after = O.bundle_inputs(root, Path(identity['bundlePath']), Path(identity['bundlePath']).parent, None, time.monotonic()+60)
        need(after == identity['bundleLayout'], 'Compiled bundle changed during owned cell')
        result['bundleUnchangedAfterCell'] = True
        if result['cases']['status'] == 'passed':
            need(not result['cases']['skippedIDs'], 'No selected diagnostic method may be skipped')
            need([row['phase'] for row in result['phaseMarkers']] == PHASES, 'Passing method lacked all26 fixed phases')
            need(not process['root']['signals'], 'Passing cell cannot require a signal')
            result['status'] = 'passed'
    except Exception as error:
        result['error'] = type(error).__name__ + ': ' + str(error)
    finally:
        save(directory/'result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--source-root', type=Path, default=Path.cwd())
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    need(sys.platform == 'darwin', 'Direct XCTest diagnostic requires macOS')
    root = args.source_root.resolve(strict=True)
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    names, raw_identity = selection(root, args.inventory.resolve(strict=True))
    identity, env = launch_inputs(root, directory, args.source)
    record = dict(schemaVersion=1, diagnosticOnly=True, installerAcceptance=False, runtimeAcceptance=False,
        scope=SCOPE, identity=identity, rawInventory=raw_identity, ordered70IDs=names,
        singleMethod=METHOD, cells=[], groupStatus='not-run', status='running', nativeCapPerCellSeconds=420,
        launcherDifference='Direct platform XCTest agent instead of SwiftPM; same compiled test bundle',
        onlyTestEnvironmentAddition='PICSHOT_TEXT_SCRIPT_LIFECYCLE_DIAGNOSTIC=1')
    save(directory/'diagnostic.json', record)
    single = run_phase('single', [METHOD], root, directory/'single', identity, env)
    record['cells'].append(single)
    record['status'] = single['status']
    save(directory/'diagnostic.json', record)
    if single['status'] == 'passed':
        group = run_phase('original70', names, root, directory/'original70', identity, env)
        record['cells'].append(group)
        record['status'] = group['status']
        record['groupStatus'] = group['status']
    else:
        record['groupNotRunReason'] = 'exact-single-method-did-not-pass-with-confirmed-owned-cleanup'
    source_guard(root, args.source)
    save(directory/'diagnostic.json', record)
    print(json.dumps(dict(status=record['status'], groupStatus=record['groupStatus'], diagnosticOnly=True,
                          report=str(directory/'diagnostic.json'))))
    return 0 if record['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
