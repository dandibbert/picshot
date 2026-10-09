#!/usr/bin/env python3
"""Directly own one compiled Darwin XCTest process for diagnostic isolation.

This is not the original SwiftPM full-prefix reproduction or installer acceptance.
No process discovery is performed. Only this launcher's unreaped direct children
can be sampled or signalled. Product source, tests and the 420s cap stay unchanged.
"""
import argparse
import collections
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import resource
import selectors
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


D = module('owned_diagnostic_utilities', 'native-test-diagnostics.py')
N = D.NATIVE
need, save = D.need, D.save
SOURCE = 'f991c23aaa60469db0e2dc77cb94198d0dc74c08'
TREE = '2347fb7fe45cf809e4cd6aa43fc2426a1fbff7b1'
INVENTORY_SHA = '77ab5c9cc0c4abc4524f2b7002b42a52133984d8f639cd7e27c27ce53b7a962a'
IDS_SHA = 'c7ad58f2d3b4085fe2d314585887ee81c42b45a0c51aa4a14d0a782a31036c11'
FILTER_SHA = '030e00c5fb0283882a499f742122f1a3d15c29c288a85fddcd0be278dff69f29'
PREFLIGHT_IDS = [
    'PicShotCodecCoreTests.CodecExportProtocolTests/testMalformedRequestsFailClosed',
    'PicShotCodecCoreTests.CodecExportProtocolTests/testOptionsRejectInvalidAndOverflowingDimensions',
    'PicShotCodecCoreTests.ImageDecodeTimingTraceTests/testAllTimesMustBeFiniteNonnegativeAndMonotone',
]
SETUP_SECONDS = 60
SAMPLER_SECONDS = 40  # Observer-only headroom; old observer remains at 20s.
UNRETIRED_CHILDREN = []  # Prevent Popen.__del__ from reaping before failed evidence is saved.
SCOPE = 'Direct XCTest launch isolation; not SwiftPM full-prefix reproduction or installer acceptance'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_identity(path, deadline=None):
    need(path.is_file() and not path.is_symlink(), 'Expected regular identity input: ' + str(path))
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            need(deadline is None or time.monotonic() < deadline, 'Launch setup deadline exceeded')
            digest.update(block)
    return dict(bytes=path.stat().st_size, sha256=digest.hexdigest())


def ids_digest(names):
    return sha(('\n'.join(names) + '\n').encode())


def command(executable, bundle, names):
    need(names and len(names) == len(set(names)) and all(N.SPECIFIER.fullmatch(x) for x in names),
         'Expected unique exact XCTest method IDs')
    selection = ','.join(names)
    need(len(selection.encode()) <= 96 * 1024, 'XCTest selection exceeds argv bound')
    return [str(executable), '-XCTest', selection, str(bundle)]


def checked_plan(path):
    plan = N.checked_plan(path, SOURCE)
    inventory, selected = plan['discoveredTests'], plan['shards'][3]['tests']
    need(len(inventory) == 1799 and len({x.split('/')[0] for x in inventory}) == 205
         and ids_digest(inventory) == INVENTORY_SHA and plan['selectedTests'] == inventory
         and plan['selectionRegex'] == '' and plan['processCount'] == 4
         and plan['timeoutSecondsPerProcess'] == 420
         and len(selected) == 464 and len({x.split('/')[0] for x in selected}) == 53
         and ids_digest(selected) == IDS_SHA and sha(plan['shards'][3]['filter'].encode()) == FILTER_SHA,
         'Plan differs from immutable145 group 3')
    need(set(PREFLIGHT_IDS) < set(selected), 'Applicability methods differ from exact group 3')
    return plan


def ordered_selection(plan_path, expected):
    raw = N.bounded_text(plan_path.parent / 'native-test-discovery.log', N.MAX_INVENTORY_BYTES)
    ordered = [line.strip() for line in raw.splitlines() if line.strip() in set(expected)]
    need(sorted(ordered) == sorted(expected), 'Raw discovery order differs from selected membership')
    return ordered


def bounded_read(command, cwd=None, timeout=20):
    # Read-only toolchain queries, never the test workload. File-backed output is
    # capped by RLIMIT_FSIZE as well as read size; stdout/stderr remain separate.
    import tempfile
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        def limits():
            resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024, 64 * 1024))
        result = subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL, stdout=out,
                                stderr=err, timeout=timeout, check=False, preexec_fn=limits)
        out.seek(0); err.seek(0)
        data, errors = out.read(64 * 1024 + 1), err.read(64 * 1024 + 1)
    need(result.returncode == 0 and len(data) <= 64 * 1024 and len(errors) <= 64 * 1024,
         'Toolchain/source query failed: ' + repr(command))
    return data.decode('utf-8').strip()


def test_environment(inherited, platform, output_mode):
    env = dict(inherited)
    for name, suffixes in (
        ('DYLD_FRAMEWORK_PATH', ('Developer/Library/Frameworks', 'Developer/Library/PrivateFrameworks')),
        ('DYLD_LIBRARY_PATH', ('Developer/usr/lib',)),
    ):
        entries = ([env[name]] if env.get(name) else []) + [str(platform / suffix) for suffix in suffixes]
        env[name] = ':'.join(entries)
    env['SWIFT_TESTING_ENABLED'] = '0'
    env['NO_COLOR'] = '1'
    if output_mode == 'unbuffered':
        env['NSUnbufferedIO'] = 'YES'
    return env


def launch_inputs(args):
    need(sys.platform == 'darwin', 'Native applicability must be verified on macOS')
    deadline = time.monotonic() + SETUP_SECONDS
    def query(argv, cwd=None):
        remaining = deadline - time.monotonic()
        need(remaining > 0, 'Launch setup deadline exceeded')
        return bounded_read(argv, cwd, timeout=min(20, remaining))
    source = args.source_root.resolve(strict=True)
    need(query(['git', 'rev-parse', 'HEAD'], source) == SOURCE
         and query(['git', 'rev-parse', 'HEAD^{tree}'], source) == TREE,
         'Product checkout differs from immutable145')
    need(not query(['git', 'status', '--porcelain', '--untracked-files=no'], source),
         'Product tracked source is modified')
    need(not query(['git', 'status', '--porcelain', '--untracked-files=all', '--',
                    'Package.swift', 'Package.resolved', 'Sources', 'Tests'], source),
         'Product source contains untracked or modified build inputs')
    selected_developer = query(['/usr/bin/xcode-select', '-p'])
    developer = Path(os.environ.get('DEVELOPER_DIR') or selected_developer).resolve(strict=True)
    if developer.suffix == '.app':
        developer = developer / 'Contents/Developer'
    xcrun_entry = Path(query(['/usr/bin/xcrun', '--sdk', 'macosx', '--find', 'xctest']))
    resolved_entry = xcrun_entry.resolve(strict=True)
    need(developer in resolved_entry.parents, 'XCTest entry is outside the selected Xcode')
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
    need(bundle == bin_path / 'PicShotPackageTests.xctest' and bundle.is_dir()
         and (source / '.build').resolve() in bundle.parents, 'Unexpected compiled XCTest bundle')
    info_path = bundle / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    name = info.get('CFBundleExecutable')
    need(name == 'PicShotPackageTests', 'Unexpected compiled XCTest bundle executable')
    executable_in_bundle = bundle / 'Contents/MacOS' / name
    entries = {}
    for path in sorted(bundle.rglob('*')):
        need(not path.is_symlink(), 'Symlink inside compiled XCTest bundle')
        if path.is_file():
            entries[str(path.relative_to(bundle))] = file_identity(path, deadline)
    need(0 < len(entries) < 10000, 'Invalid compiled bundle file inventory')
    env = test_environment(os.environ, platform, args.output_mode)
    env_keys = ('DYLD_FRAMEWORK_PATH', 'DYLD_LIBRARY_PATH', 'SWIFT_TESTING_ENABLED', 'NO_COLOR', 'NSUnbufferedIO')
    identity = dict(sourceCommit=SOURCE, sourceTree=TREE, sourceRoot=str(source),
        xcodeDeveloperDirectory=str(developer), xcodeSelectDirectory=selected_developer,
        developerDirectoryOverride=os.environ.get('DEVELOPER_DIR'),
        xcrunEntryPath=str(xcrun_entry), xcrunResolvedPath=str(resolved_entry),
        xcrunEntryIsSymlink=xcrun_entry.is_symlink(), xcrunEntry=file_identity(resolved_entry, deadline),
        xctestPath=str(executable), xctest=file_identity(executable, deadline),
        bundlePath=str(bundle), bundleExecutable=file_identity(executable_in_bundle, deadline), bundleFiles=entries,
        bundleManifestSHA256=sha(json.dumps(entries, sort_keys=True).encode()),
        xcodeVersion=query(['/usr/bin/xcodebuild', '-version']),
        swiftVersion=query(['/usr/bin/xcrun', 'swift', '--version']),
        swiftPackageVersion=query(['/usr/bin/xcrun', 'swift', 'package', '--version']),
        runtimeEnvironment={key: env.get(key) for key in env_keys},
        helperFiles={filename: file_identity(Path(__file__).with_name(filename), deadline) for filename in (
            Path(__file__).name, 'native-test-diagnostics.py', 'native-test-shards.py', 'run-bounded-command.py')})
    need(time.monotonic() < deadline, 'Launch setup deadline exceeded')
    identity['limits'] = dict(setupSeconds=SETUP_SECONDS, nativeSeconds=420, samplerSeconds=SAMPLER_SECONDS,
        sampleCollectionSeconds=D.SAMPLE_SECONDS, sampleIntervalMilliseconds=D.SAMPLE_INTERVAL_MS)
    return identity, env


class OwnedChildExited(ValueError):
    pass


class IdentityMismatch(ValueError):
    pass


class OwnedChild:
    """No poll/wait before final retirement; numeric PID cannot be recycled."""
    def __init__(self, process, executable, identify):
        self.process, self.identify = process, identify
        self.watch = D.BOUNDED.ProcessGroup(process)
        self.identity = None
        self.reaped = False
        self.record = dict(pid=process.pid, ownerPID=os.getpid(), identity=None, signals=[],
                           cleanupConfirmed=False, bindingError=None)
        try:
            need(not self.exited(), 'Owned child exited before identity binding')
            observed = identify(process.pid)
            self.record['initialIdentity'] = observed
            need(observed['pid'] == process.pid and observed['parentPID'] == os.getpid()
                 and observed['uid'] == os.getuid() and observed['groupID'] == process.pid
                 and observed['executable'] == executable, 'Direct-child executable or ownership mismatch')
            self.identity = observed
            self.record['identity'] = observed
        except Exception as error:
            self.record['bindingError'] = str(error)

    def exited(self):
        need(not self.reaped, 'Cannot observe a reaped PID')
        return self.watch.leader_exited()

    def validate(self):
        need(self.identity is not None, 'Owned target is unbound')
        if self.exited():
            raise OwnedChildExited('Owned target exited without releasing its PID')
        current = self.identify(self.process.pid)
        if current != self.identity:
            self.record['identityMismatch'] = dict(expected=self.identity, observed=current)
            raise IdentityMismatch('Owned target identity changed')
        return current

    def send(self, signum):
        if self.exited():
            return False
        if self.identity is not None:
            try:
                self.validate()
            except (OwnedChildExited, D.PIDInfoAbsent):
                need(self.exited(), 'Target identity vanished without owned exit evidence')
                return False
            basis = 'exact-libproc-identity-and-unreaped-Popen-child'
        else:
            # Even a failed initial identity read cannot turn this into a reused
            # PID: waitid/kqueue has never reaped the direct Popen child.
            basis = 'unreaped-Popen-child-binding-failed'
        try:
            os.kill(self.process.pid, signum)
        except ProcessLookupError:
            need(self.exited(), 'Signal ESRCH without owned child exit evidence')
            return False
        self.record['signals'].append(dict(signal=signum, basis=basis,
            identity=self.identity, atMonotonic=time.monotonic()))
        return True

    def reap(self):
        need(self.exited(), 'Cannot release a live owned child')
        code = self.process.wait(timeout=1)
        self.reaped = True
        self.record.update(cleanupConfirmed=True, returnCode=code,
                           retirementEvidence='unreaped-exit-observation-then-Popen-wait',
                           reapedAtMonotonic=time.monotonic())
        self.watch.close()
        return code


def sample_contents(path, target):
    need(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= D.SAMPLE_FILE_CAP,
         'Missing, symlink or oversized raw sample')
    with path.open('rb') as stream:
        data = stream.read(D.SAMPLE_FILE_CAP + 1)
    need(0 < len(data) <= D.SAMPLE_FILE_CAP, 'Raw sample exceeds byte cap')
    raw = data.decode('utf-8')
    need(re.search(r'^Process:\s+.*\[' + str(target['pid']) + r'\]\s*$', raw, re.M),
         'Raw sample PID differs from owned root')
    need(re.search(r'^Path:\s+' + re.escape(target['executable']) + r'\s*$', raw, re.M),
         'Raw sample executable differs from owned root')
    need('Call graph:' in raw and re.search(r'^\s+\+?\s*\d+\s+Thread_', raw, re.M),
         'Raw sample has no thread call graph')
    return dict(sampleBytes=len(data), sampleSHA256=sha(data))


def start_sample(directory, slot, root, identify):
    target = root.validate()
    destination = directory / f'sample-{slot}.txt'
    request = dict(slotSeconds=slot, target=target, command=['/usr/bin/sample', str(root.process.pid),
        str(D.SAMPLE_SECONDS), str(D.SAMPLE_INTERVAL_MS), '-mayDie', '-file', str(destination)])
    save(directory / f'sample-{slot}.request.json', request)
    request_sha = file_identity(directory / f'sample-{slot}.request.json')['sha256']
    def limits():
        resource.setrlimit(resource.RLIMIT_FSIZE, (D.SAMPLE_FILE_CAP, D.SAMPLE_FILE_CAP))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    # Do not reap root while sample may use its PID. No name/PID lookup is used.
    stream = (directory / f'sample-{slot}.launch.log').open('xb')
    sampler_started = time.monotonic()
    try:
        process = subprocess.Popen(request['command'], stdin=subprocess.DEVNULL, stdout=stream,
            stderr=subprocess.STDOUT, start_new_session=True, preexec_fn=limits)
    finally:
        stream.close()
    child = OwnedChild(process, '/usr/bin/sample', identify)
    record = dict(slotSeconds=slot, target=target, request=request,
        requestSHA256=request_sha,
        startedMonotonic=sampler_started, status='running', process=child.record)
    return child, record


def terminate_child(child, grace=0.5):
    if not child.exited():
        child.send(signal.SIGTERM)
    deadline = time.monotonic() + grace
    while not child.exited() and time.monotonic() < deadline:
        time.sleep(0.02)
    if not child.exited():
        child.send(signal.SIGKILL)
    deadline = time.monotonic() + 2
    while not child.exited() and time.monotonic() < deadline:
        time.sleep(0.02)
    need(child.exited(), 'Owned child did not retire within bounded cleanup')


def stop_child(child, grace=0.5):
    terminate_child(child, grace)
    return child.reap()


def emergency_reap(child, reason):
    """Last-resort cleanup of our own unreaped child; never a valid observation."""
    need(not child.reaped, 'Emergency cleanup cannot touch a released PID')
    child.record['emergencyCleanup'] = dict(reason=reason, basis='unreaped-Popen-child-only')
    if child.process.returncode is None:
        try:
            os.kill(child.process.pid, signal.SIGKILL)
            child.record['signals'].append(dict(signal=signal.SIGKILL,
                basis='unreaped-Popen-child-emergency', atMonotonic=time.monotonic()))
        except ProcessLookupError:
            pass  # Only the following owned wait can establish retirement.
    code = child.process.wait(timeout=2)
    child.reaped = True
    child.record.update(cleanupConfirmed=True, returnCode=code,
        retirementEvidence='emergency-direct-child-kill-then-Popen-wait', reapedAtMonotonic=time.monotonic())
    child.watch.close()
    return code


def run_owned(argv, env, cwd, directory, identify, timeout=420, slots=(180, 360)):
    directory.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    report = dict(schemaVersion=1, scope=SCOPE, diagnosticOnly=True, installerAcceptance=False,
        command=argv, timeoutSeconds=timeout, samplerTimeoutSeconds=SAMPLER_SECONDS, expectedCaptureSlots=list(slots), captures=[],
        status='starting', outputBytes=0, logBytes=0, logTruncated=False, errors=[],
        cleanupConfirmed=False, outputEOF=False, cancellationSignal=None)
    save(directory / 'process.json', report)
    root = sampler = None
    active = None
    selector = selectors.DefaultSelector()
    cancelled = []
    previous = {}
    for signum in (signal.SIGTERM, signal.SIGINT):
        previous[signum] = signal.signal(signum, lambda s, _: cancelled.append(s))
    try:
        with (directory / 'xctest.log').open('xb') as log:
            process = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, bufsize=0)
            root = OwnedChild(process, argv[0], identify)
            report['root'] = root.record
            need(root.identity is not None, root.record['bindingError'])
            os.set_blocking(process.stdout.fileno(), False)
            selector.register(process.stdout, selectors.EVENT_READ)
            report['status'] = 'running'
            save(directory / 'process.json', report)
            pending = list(slots)
            while True:
                elapsed = time.monotonic() - started
                if cancelled:
                    report.update(status='cancelled', cancellationSignal=cancelled[0]); break
                if elapsed >= timeout:
                    report['status'] = 'timeout'; break
                if root.exited():
                    report['status'] = 'exited'; break
                if sampler is not None and (sampler.exited() or time.monotonic() - active['startedMonotonic'] >= SAMPLER_SECONDS):
                    finish_sample(sampler, active, root, directory)
                    sampler = None
                if pending and elapsed >= pending[0] and sampler is None:
                    sampler, active = start_sample(directory, pending.pop(0), root, identify)
                    active['startedAtSeconds'] = time.monotonic() - started
                    report['captures'].append(active)
                    need(sampler.identity is not None, sampler.record['bindingError'])
                drain(selector, log, report, 0.05)
            report['workloadEndSeconds'] = time.monotonic() - started
            report['dueCaptureSlots'] = [slot for slot in slots if slot <= report['workloadEndSeconds']]
            # Terminate root at its own deadline, without waiting for symbolization.
            # Keep it unreaped until every sampler is retired.
            if not root.exited():
                report['terminationStartedAtSeconds'] = time.monotonic() - started
                terminate_child(root)
            if sampler is not None:
                # A natural workload exit does not interrupt bounded symbolization.
                # The exited root remains unreaped, so its PID is still reserved.
                while (report['status'] == 'exited' and not cancelled and not sampler.exited()
                       and time.monotonic() - active['startedMonotonic'] < SAMPLER_SECONDS):
                    drain(selector, log, report, 0.02)
                if cancelled:
                    report.update(status='cancelled', cancellationSignal=cancelled[0])
                finish_sample(sampler, active, root, directory, cancel=report['status'] != 'exited')
                sampler = None
            if not root.exited():
                report['rootReturnCode'] = stop_child(root)
            else:
                report['rootReturnCode'] = root.reap()
            end = time.monotonic() + 0.5
            while selector.get_map() and time.monotonic() < end:
                drain(selector, log, report, 0.02)
    except Exception as error:
        report['errors'].append(str(error)); report['status'] = 'error'
    finally:
        # Cleanup never depends on successful artifact writes. All direct child
        # handles are retained even when initial identity binding failed.
        if root is not None and not root.reaped:
            try:
                terminate_child(root)
            except Exception as error:
                report['errors'].append('Root termination: ' + str(error))
        if sampler is not None and not sampler.reaped:
            try:
                stop_child(sampler)
            except Exception as error:
                report['errors'].append('Sampler cleanup: ' + str(error))
                if not sampler.reaped:
                    try:
                        emergency_reap(sampler, str(error))
                    except Exception as emergency_error:
                        report['errors'].append('Sampler emergency cleanup: ' + str(emergency_error))
        if root is not None and not root.reaped and (sampler is None or sampler.reaped):
            try:
                report['rootReturnCode'] = stop_child(root)
            except Exception as error:
                report['errors'].append('Root cleanup: ' + str(error))
                if not root.reaped:
                    try:
                        report['rootReturnCode'] = emergency_reap(root, str(error))
                    except Exception as emergency_error:
                        report['errors'].append('Root emergency cleanup: ' + str(emergency_error))
        if sampler is not None and not sampler.reaped:
            report['errors'].append('Sampler retirement unproven; root PID held only through helper lifetime')
        for child in (sampler, root):
            if child is not None and not child.reaped:
                UNRETIRED_CHILDREN.append(child)
        report.setdefault('workloadEndSeconds', time.monotonic() - started)
        report.setdefault('dueCaptureSlots', [slot for slot in slots if slot <= report['workloadEndSeconds']])
        selector.close()
        if root is not None and root.process.stdout is not None:
            root.process.stdout.close()
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        report['cleanupConfirmed'] = bool(root and root.reaped and all(
            c['process']['cleanupConfirmed'] for c in report['captures']))
        report['durationSeconds'] = time.monotonic() - started
        report['rootCleanupScope'] = 'Exact directly owned XCTest root and sampler children only; no descendant census'
        path = directory / 'xctest.log'
        if path.exists():
            report['logIdentity'] = file_identity(path)
        save(directory / 'process.json', report)
    return report


def drain(selector, log, report, timeout):
    for key, _ in selector.select(timeout):
        try:
            chunk = os.read(key.fd, 64 * 1024)
        except BlockingIOError:
            continue
        if not chunk:
            selector.unregister(key.fileobj)
            report['outputEOF'] = True
            continue
        report['outputBytes'] += len(chunk)
        retained = chunk[:max(0, N.MAX_LOG_BYTES - report['logBytes'])]
        log.write(retained); log.flush()
        report['logBytes'] += len(retained)
        report['logTruncated'] = report['outputBytes'] > report['logBytes']


def finish_sample(sampler, record, root, directory, cancel=False):
    try:
        expired = time.monotonic() - record['startedMonotonic'] >= SAMPLER_SECONDS
        natural_exit = sampler.exited()
        record['completion'] = 'cancelled' if cancel else 'timeout' if expired or not natural_exit else 'exited'
        code = sampler.reap() if natural_exit else stop_child(sampler)
        record['returnCode'] = code
        need(not root.reaped, 'Sample target PID was released before sampler retirement')
        record['targetUnreapedAtCompletion'] = True
        record['targetExitObservedAtCompletion'] = root.exited()
        record['targetIdentityAfter'] = None
        if not record['targetExitObservedAtCompletion']:
            try:
                record['targetIdentityAfter'] = root.validate()
            except (OwnedChildExited, D.PIDInfoAbsent):
                # Only a typed exit/absence race can establish this transition.
                # A positively observed identity mismatch remains a failed sample.
                need(root.exited(), 'Live sample target identity could not be verified')
                record['targetExitObservedAtCompletion'] = True
        need(code == 0 and not cancel and not expired, 'Sample was incomplete, late or cancelled')
        record.update(sample_contents(directory / f"sample-{record['slotSeconds']}.txt", root.identity))
        record['status'] = 'captured'
    except Exception as error:
        record.update(status='incomplete', error=str(error))
    record['durationSeconds'] = time.monotonic() - record['startedMonotonic']
    save(directory / f"sample-{record['slotSeconds']}.json", record)
    need(sampler.reaped, 'Sampler is not retired; retain root PID and sampler handle')


def validate_capture(directory, capture, root):
    target = root['identity']
    slot = capture['slotSeconds']
    need(slot in (180, 360) and capture['status'] == 'captured'
         and capture['completion'] == 'exited' and capture['returnCode'] == 0
         and capture['target'] == target and capture['targetUnreapedAtCompletion'] is True
         and ((capture['targetExitObservedAtCompletion'] is False and capture['targetIdentityAfter'] == target)
              or (capture['targetExitObservedAtCompletion'] is True and capture['targetIdentityAfter'] is None)),
         'Capture identity/completion differs from owned root')
    process = capture['process']
    identity = process['identity']
    need(process['cleanupConfirmed'] is True and process['returnCode'] == 0 and not process['bindingError']
         and identity['pid'] == identity['groupID'] == process['pid']
         and identity['parentPID'] == process['ownerPID'] == target['parentPID']
         and identity['uid'] == target['uid'] and identity['executable'] == '/usr/bin/sample'
         and not process['signals']
         and root['reapedAtMonotonic'] >= process['reapedAtMonotonic'],
         'Sampler ownership/retirement differs')
    request_path = directory / f'sample-{slot}.request.json'
    request = json.loads(N.bounded_text(request_path, D.METADATA_CAP))
    need(file_identity(request_path)['sha256'] == capture['requestSHA256']
         and request == capture['request'] and request['target'] == target
         and request['slotSeconds'] == slot, 'Sample request identity/hash differs')
    argv = request['command']
    need(argv[:-1] == ['/usr/bin/sample', str(target['pid']), str(D.SAMPLE_SECONDS),
         str(D.SAMPLE_INTERVAL_MS), '-mayDie', '-file']
         and Path(argv[-1]).is_absolute() and Path(argv[-1]).name == f'sample-{slot}.txt',
         'Sample request argv differs')
    need(json.loads(N.bounded_text(directory / f'sample-{slot}.json', D.METADATA_CAP)) == capture,
         'Sample terminal sidecar differs')
    need(sample_contents(directory / f'sample-{slot}.txt', target)
         == {key: capture[key] for key in ('sampleBytes', 'sampleSHA256')},
         'Raw sample bytes differ')


def assess(report, log, expected):
    events = collections.defaultdict(list)
    for match in N.CASE_EVENT.finditer(log):
        events[match[1] + '/' + match[2]].append(match[3])
    result = dict(expectedIDs=expected, observedEvents=dict(events),
        missingIDs=sorted(set(expected) - set(events)), unexpectedIDs=sorted(set(events) - set(expected)),
        passedIDs=sorted(x for x, values in events.items() if values == ['started', 'passed']),
        selectedIDsSHA256=ids_digest(sorted(expected)),
        observedStartOrder=[match[1] + '/' + match[2] for match in N.CASE_EVENT.finditer(log)
                            if match[3] == 'started'], status='incomplete')
    if report['status'] == 'exited' and report.get('rootReturnCode') == 0:
        passed, skipped = N.case_results(log, expected)
        need(report['cleanupConfirmed'] is True and report['outputEOF'] is True and not report['errors']
             and report['logTruncated'] is False
             and [c['slotSeconds'] for c in report['captures']] == report['dueCaptureSlots']
             and all(c['status'] == 'captured' for c in report['captures']),
             'Direct run lacked complete cleanup/output/sample evidence')
        result.update(status='passed', passedIDs=passed, skippedIDs=skipped)
    return result


def read_report(directory):
    return json.loads(N.bounded_text(directory / 'result.json', 8 * 1024 * 1024))


def verify_result(directory, identity, expected, phase, output_mode='baseline'):
    prior = read_report(directory)
    need(prior['phase'] == phase and prior['outputMode'] == output_mode
         and prior['inputs'] == identity
         and identity['sourceCommit'] == SOURCE and identity['sourceTree'] == TREE
         and identity['limits'] == dict(setupSeconds=SETUP_SECONDS, nativeSeconds=420,
             samplerSeconds=SAMPLER_SECONDS, sampleCollectionSeconds=D.SAMPLE_SECONDS,
             sampleIntervalMilliseconds=D.SAMPLE_INTERVAL_MS), 'Prior launch identity/mode differs')
    need(prior['schemaVersion'] == 1 and prior['scope'] == SCOPE
         and prior['diagnosticOnly'] is True and prior['installerAcceptance'] is False
         and prior['fullInventorySHA256'] == INVENTORY_SHA
         and prior['group3IDsSHA256'] == IDS_SHA
         and prior['historicalSwiftPMFilterSHA256'] == FILTER_SHA
         and sha(prior['historicalSwiftPMFilter'].encode()) == FILTER_SHA, 'Prior scope/inventory differs')
    process = json.loads(N.bounded_text(directory / 'process.json', D.METADATA_CAP))
    need(process['timeoutSeconds'] == (30 if phase == 'preflight' else 420)
         and process['samplerTimeoutSeconds'] == SAMPLER_SECONDS
         and process['expectedCaptureSlots'] == ([] if phase == 'preflight' else [180, 360]),
         'Prior deadline/sample schedule differs')
    need(prior['process'] == process and process['command'] == command(
        identity['xctestPath'], identity['bundlePath'], prior['orderedSelectedIDs']), 'Prior process/argv evidence differs')
    need(sorted(prior['orderedSelectedIDs']) == sorted(expected)
         and prior['orderedSelectedIDsSHA256'] == ids_digest(prior['orderedSelectedIDs'])
         and prior['commaSelectorSHA256'] == sha(','.join(prior['orderedSelectedIDs']).encode()),
         'Prior ordered membership differs')
    need(file_identity(directory / 'xctest.log') == process['logIdentity'], 'Prior log identity differs')
    root = process['root']
    target = root['identity']
    need(target is not None and not root['bindingError']
         and target['pid'] == target['groupID'] == root['pid']
         and target['parentPID'] == root['ownerPID']
         and target['executable'] == identity['xctestPath']
         and root['cleanupConfirmed'] is True and root['returnCode'] == process['rootReturnCode'],
         'Prior root binding/retirement differs')
    for capture in process['captures']:
        validate_capture(directory, capture, root)
    cases = assess(process, N.bounded_text(directory / 'xctest.log', N.MAX_LOG_BYTES), expected)
    need(cases == prior['cases'], 'Prior case evidence differs')
    return prior


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('preflight', 'run'))
    parser.add_argument('--source-root', type=Path, default=Path.cwd())
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--preflight', type=Path)
    parser.add_argument('--output-mode', choices=('baseline', 'unbuffered'), default='baseline')
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    args.directory = args.directory.resolve()
    plan = checked_plan(args.plan)
    identity, env = launch_inputs(args)
    names = PREFLIGHT_IDS if args.phase == 'preflight' else plan['shards'][3]['tests']
    ordered = ordered_selection(args.plan, names)
    if args.phase == 'preflight':
        need(args.output_mode == 'baseline' and args.preflight is None and args.baseline is None,
             'Preflight uses only the inherited buffering mode')
    else:
        need(args.preflight is not None, 'A successful native applicability preflight is required')
        baseline_identity = dict(identity)
        if args.output_mode == 'unbuffered':
            need(args.baseline is not None, 'Unbuffered control requires exact baseline timeout')
            baseline_identity = read_report(args.baseline)['inputs']
            baseline_env = dict(baseline_identity['runtimeEnvironment'])
            baseline_env['NSUnbufferedIO'] = 'YES'
            need({**baseline_identity, 'runtimeEnvironment': baseline_env} == identity,
                 'Unbuffered control changes more than NSUnbufferedIO')
        preflight = verify_result(args.preflight, baseline_identity, PREFLIGHT_IDS, 'preflight')
        need(preflight['cases']['status'] == 'passed', 'Native applicability preflight did not pass')
        if args.output_mode == 'unbuffered':
            baseline = verify_result(args.baseline, baseline_identity, names, 'run')
            p = baseline['process']
            need(p['status'] == 'timeout' and p['timeoutSeconds'] == 420
                 and p['cleanupConfirmed'] is True and not p['errors'] and p['logTruncated'] is False
                 and p['outputEOF'] is True and [c['slotSeconds'] for c in p['captures']] == [180, 360],
                 'Baseline lacks exact timeout and cleanup evidence')
            need(p['dueCaptureSlots'] == [180, 360] and p['samplerTimeoutSeconds'] == SAMPLER_SECONDS,
                 'Baseline sample allowance or due slots differ')
        else:
            need(args.baseline is None, 'Baseline evidence is only an unbuffered control input')
    report = run_owned(command(identity['xctestPath'], identity['bundlePath'], ordered), env,
        str(args.source_root.resolve()), args.directory, D.ProcessIdentity(),
        timeout=30 if args.phase == 'preflight' else 420,
        slots=() if args.phase == 'preflight' else (180, 360))
    try:
        for capture in report['captures']:
            validate_capture(args.directory, capture, report['root'])
        cases = assess(report, N.bounded_text(args.directory / 'xctest.log', N.MAX_LOG_BYTES), names)
    except Exception as error:
        cases = dict(status='failed', error=str(error), expectedIDs=names)
    result = dict(schemaVersion=1, phase=args.phase, outputMode=args.output_mode, scope=SCOPE,
        diagnosticOnly=True, installerAcceptance=False, inputs=identity, process=report, cases=cases,
        planIdentity=file_identity(args.plan), fullInventorySHA256=INVENTORY_SHA,
        orderedSelectedIDs=ordered, orderedSelectedIDsSHA256=ids_digest(ordered),
        commaSelectorSHA256=sha(','.join(ordered).encode()),
        launcherDifferences=['Direct platform agent, no SwiftPM parent or separate Swift Testing phase'],
        preflightUnselectedNeighborIDs=[x for x in plan['discoveredTests']
            if x.split('/')[0] in {p.split('/')[0] for p in PREFLIGHT_IDS} and x not in PREFLIGHT_IDS],
        group3IDsSHA256=IDS_SHA, historicalSwiftPMFilter=plan['shards'][3]['filter'],
        historicalSwiftPMFilterSHA256=FILTER_SHA)
    save(args.directory / 'result.json', result)
    print(json.dumps(dict(status=cases['status'], processStatus=report['status'], scope=SCOPE,
                          cleanupConfirmed=report['cleanupConfirmed'])))
    return 0 if cases['status'] == 'passed' else 124 if report['status'] == 'timeout' else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('Owned XCTest diagnostic rejected: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
