#!/usr/bin/env python3
"""Optional macOS observations around the unchanged bounded native command.

The baseline mode preserves the inherited environment. The separate unbuffered
control adds only NSUnbufferedIO=YES. Neither mode changes inventory, filters,
native timeouts, product defaults, or the native aggregate success requirements.
"""

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import resource
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


NATIVE = module('native_shards', 'native-test-shards.py')
BOUNDED = module('bounded_command', 'run-bounded-command.py')
CAPTURE_AT = (180, 360)
SAMPLE_SECONDS = 2
SAMPLE_INTERVAL_MS = 10
SAMPLE_TIMEOUT = 8
SAMPLE_GRACE = 0.5
SAMPLE_FILE_CAP = 2 * 1024 * 1024
METADATA_CAP = 1024 * 1024
MAX_DIAGNOSTIC_MEMBERS = 64


def need(condition, message):
    if not condition:
        raise ValueError(message)


def save(path, value):
    data = (json.dumps(value, indent=2) + '\n').encode()
    need(len(data) <= METADATA_CAP, 'Diagnostic metadata exceeded its cap')
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_bytes(data)
    temporary.replace(path)


class BSDInfo(ctypes.Structure):
    # Apple's public proc_bsdinfo ABI, sys/proc_info.h (PROC_PIDTBSDINFO=3).
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid',
        'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'jobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_seconds', ctypes.c_uint64),
                 ('start_microseconds', ctypes.c_uint64)]


class ProcessIdentity:
    def __init__(self):
        need(sys.platform == 'darwin', 'Native diagnostics require macOS')
        need(ctypes.sizeof(BSDInfo) == 136, 'Unknown Darwin process identity ABI')
        self.library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                              ctypes.c_void_p, ctypes.c_int]
        self.library.proc_pidinfo.restype = ctypes.c_int
        self.library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.library.proc_pidpath.restype = ctypes.c_int

    def __call__(self, pid):
        need(type(pid) is int and 0 < pid <= 2147483647, 'Invalid process ID')
        info = BSDInfo()
        count = self.library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        need(count == ctypes.sizeof(info) and info.pid == pid, 'Missing or changed process identity')
        path = ctypes.create_string_buffer(4096)
        count = self.library.proc_pidpath(pid, path, len(path))
        need(0 < count < len(path) and path.value.startswith(b'/'), 'Missing executable identity')
        need(info.start_seconds > 0 and info.start_microseconds < 1000000, 'Invalid process birth time')
        return {'pid': pid, 'parentPID': info.ppid, 'groupID': info.pgid, 'uid': info.uid,
                'birthSeconds': info.start_seconds, 'birthMicroseconds': info.start_microseconds,
                'executable': path.value.decode('utf-8')}


def owned_target(wrapper_pid, group_id, identify):
    """Only inspect the live XCTest in this wrapper's anchored process group."""
    states = BOUNDED.darwin_group_snapshot(group_id)
    need(len(states) <= MAX_DIAGNOSTIC_MEMBERS, 'Owned group exceeds diagnostic observation bound')
    wrapper = identify(wrapper_pid)
    leader = identify(group_id)
    need(leader['parentPID'] == wrapper_pid and leader['groupID'] == group_id,
         'Native group leader does not belong to the launched wrapper')
    need(wrapper['uid'] == leader['uid'] == os.getuid(), 'Unexpected native process owner')
    need(not states[group_id].startswith('Z'), 'Native command has already exited')
    members = []
    for pid, state in states.items():
        if state.startswith('Z'):
            continue
        identity = identify(pid)
        need(identity['groupID'] == group_id and identity['uid'] == os.getuid(),
             'Observed member left the owned group')
        members.append(identity)
    candidates = [member for member in members if
                  member['executable'].endswith('.app/Contents/Developer/usr/bin/xctest')]
    need(len(candidates) == 1, 'Expected exactly one owned Xcode XCTest process')
    target = candidates[0]
    # Recheck after enumerating to detect exit/reuse/exec before sampling.
    need(identify(wrapper_pid) == wrapper and identify(group_id) == leader
         and identify(target['pid']) == target, 'Process identity changed during observation')
    return {'wrapper': wrapper, 'leader': leader, 'target': target, 'members': members,
            'atomicSnapshot': False}


def environment(mode, inherited):
    need(mode in ('baseline', 'unbuffered'), 'Unknown diagnostic output mode')
    value = dict(inherited)
    if mode == 'unbuffered':
        value['NSUnbufferedIO'] = 'YES'
    return value


def buffering_setting(mode, inherited):
    def setting(value):
        return value if value in ('YES', 'NO') else 'other-present'
    before = setting(inherited['NSUnbufferedIO']) if 'NSUnbufferedIO' in inherited else 'absent'
    return {'inheritedPresent': 'NSUnbufferedIO' in inherited, 'inheritedSetting': before,
            'effectiveSetting': 'YES' if mode == 'unbuffered' else before,
            'changesInheritedValue': mode == 'unbuffered' and inherited.get('NSUnbufferedIO') != 'YES'}


def cleanup_evidence(path, returncode, timeout):
    try:
        value = json.loads(NATIVE.bounded_text(path, METADATA_CAP))
        record = {key: value.get(key) for key in ('status', 'termination_reason', 'pid',
            'child_returncode', 'exit_code', 'timeout_seconds', 'duration_seconds', 'cleanup_errors', 'error')}
        confirmed = (returncode is not None and value['exit_code'] == returncode
            and value['timeout_seconds'] == timeout and not value.get('cleanup_errors')
            and not value.get('error') and value['status'] in ('exited', 'timeout', 'cancelled', 'spawn_error')
            and (type(value['child_returncode']) is int or value['status'] == 'spawn_error'))
        return confirmed, record
    except Exception as error:
        return False, {'error': str(error)}


def sample_exec(request, destination):
    """Invoked only inside the existing short bounded-command wrapper."""
    record = json.loads(NATIVE.bounded_text(request, METADATA_CAP))
    identify = ProcessIdentity()
    current = owned_target(record['wrapper']['pid'], record['leader']['pid'], identify)
    need(all(current[key] == record[key] for key in ('wrapper', 'leader', 'target')),
         'Sampling target changed after the request was recorded')
    need(destination.parent == request.parent and not destination.exists(), 'Invalid sample output')
    resource.setrlimit(resource.RLIMIT_FSIZE, (SAMPLE_FILE_CAP, SAMPLE_FILE_CAP))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.execv('/usr/bin/sample', ['/usr/bin/sample', str(current['target']['pid']),
             str(SAMPLE_SECONDS), str(SAMPLE_INTERVAL_MS), '-mayDie', '-file', str(destination)])


class Progress:
    def __init__(self, log):
        self.log = log
        self.offset = 0
        self.carry = ''
        self.latest = None

    def read(self, elapsed):
        if self.log.exists():
            need(not self.log.is_symlink() and self.log.stat().st_size <= NATIVE.MAX_LOG_BYTES,
                 'Invalid native progress log')
            with self.log.open('rb') as stream:
                stream.seek(self.offset)
                chunk = stream.read(64 * 1024)
            self.offset += len(chunk)
            text = self.carry + chunk.decode('utf-8', errors='replace')
            complete, separator, remaining = text.rpartition('\n')
            for match in NATIVE.CASE_EVENT.finditer(complete if separator else ''):
                self.latest = {'id': match[1] + '/' + match[2], 'event': match[3],
                               'observedAtSeconds': round(elapsed, 3)}
            self.carry = (remaining if separator else text)[-2048:]
        return {'elapsedSeconds': round(elapsed, 3), 'readLogBytes': self.offset,
                'latestCompleteEvent': self.latest,
                'scope': 'Log arrival time, not native event execution time'}


def native_command(args):
    return [sys.executable, str(Path(__file__).with_name('native-test-shards.py')),
            'run', '--plan', str(args.plan), '--expected-source', args.expected_source,
            '--index', str(args.index), '--directory', str(args.directory)]


def start_capture(args, native, report_path, slot, identify):
    started = time.monotonic()
    report = json.loads(NATIVE.bounded_text(report_path, METADATA_CAP))
    need(report['status'] == 'running' and report['timeout_seconds'] == 420,
         'Native bounded process is not running at the original cap')
    plan = NATIVE.checked_plan(args.plan, args.expected_source)
    need(report['command'] == NATIVE.expected_command(plan['shards'][args.index]),
         'Native command differs from the verified plan')
    need(native.poll() is None, 'Native wrapper already exited')
    request = owned_target(native.pid, report['pid'], identify)
    prefix = args.diagnostics / f'sample-{slot}'
    request_path = prefix.with_suffix('.request.json')
    save(request_path, request)
    command = [sys.executable, str(Path(__file__).with_name('run-bounded-command.py')),
               '--timeout-seconds', str(SAMPLE_TIMEOUT), '--grace-seconds', str(SAMPLE_GRACE),
               '--max-log-bytes', str(256 * 1024), '--log', str(prefix.with_suffix('.launch.log')),
               '--report', str(prefix.with_suffix('.runner.json')), '--', sys.executable,
               str(Path(__file__).resolve()), 'sample', '--request', str(request_path),
               '--output', str(prefix.with_suffix('.txt'))]
    # Finish fallible file/metadata work before a sampler exists. Once Popen
    # succeeds, immediately return its owned handle without another file read.
    record = {'slotSeconds': slot, 'target': request['target'],
              'requestSHA256': hashlib.sha256(request_path.read_bytes()).hexdigest(),
              'selectionSeconds': round(time.monotonic() - started, 6),
              'samplerStartedMonotonic': time.monotonic(), 'prefix': str(prefix)}
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
    return process, record


def finish_capture(active, sampler, identify):
    active['exitCode'] = sampler.returncode
    active['observerWallSeconds'] = round(time.monotonic() - active.pop('samplerStartedMonotonic'), 6)
    try:
        active['targetIdentityAfter'] = identify(active['target']['pid'])
        active['identityUnchangedAfter'] = active['targetIdentityAfter'] == active['target']
    except Exception as error:
        active['identityAfterError'] = str(error)
    path = Path(active['prefix']).with_suffix('.txt')
    if path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= SAMPLE_FILE_CAP:
        active['sampleBytes'] = path.stat().st_size
        active['sampleSHA256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    active['status'] = ('captured' if sampler.returncode == 0 and active.get('sampleBytes')
                        and active.get('identityUnchangedAfter') else 'incomplete')
    active['samplerCleanupConfirmed'], active['samplerEnvelope'] = cleanup_evidence(
        Path(active['prefix']).with_suffix('.runner.json'), sampler.returncode, SAMPLE_TIMEOUT)


def run(args):
    identify = ProcessIdentity()
    plan = NATIVE.checked_plan(args.plan, args.expected_source)
    need(0 <= args.index < plan['processCount'], 'Index outside verified native plan')
    need(plan['timeoutSecondsPerProcess'] == 420, 'Native deadline changed')
    log_path, report_path = NATIVE.paths(args.directory, args.index)
    need(not log_path.exists() and not report_path.exists(), 'Refusing to reuse native results')
    args.diagnostics.mkdir(parents=True, exist_ok=False, mode=0o700)
    summary_path = args.diagnostics / 'diagnostics.json'
    summary = {'schemaVersion': 1, 'sourceCommit': args.expected_source, 'index': args.index,
               'outputMode': args.output_mode, 'environmentScope': 'Inherited unchanged' if
               args.output_mode == 'baseline' else 'Inherited with NSUnbufferedIO=YES only',
               'NSUnbufferedIO': buffering_setting(args.output_mode, os.environ),
               'selectedTests': plan['shards'][args.index]['tests'], 'nativeTimeoutSeconds': 420,
               'captureAtSeconds': list(CAPTURE_AT), 'sampleSeconds': SAMPLE_SECONDS,
               'sampleIntervalMilliseconds': SAMPLE_INTERVAL_MS, 'samplerTimeoutSeconds': SAMPLE_TIMEOUT,
               'samplerGraceSeconds': SAMPLE_GRACE, 'sampleFileCapBytes': SAMPLE_FILE_CAP,
               'captures': [], 'progress': [], 'errors': [], 'nativeExitCode': None,
               'scope': 'Diagnostic observation may perturb timing; native aggregation is still required'}
    save(summary_path, summary)
    received = []
    previous = {sig: signal.signal(sig, lambda number, frame: received.append(number))
                for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    native = None
    sampler = None
    active = None
    started = time.monotonic()
    next_progress = 0
    slots = list(CAPTURE_AT)
    progress = Progress(log_path)
    try:
        native = subprocess.Popen(native_command(args), stdin=subprocess.DEVNULL,
                                  env=environment(args.output_mode, os.environ))
        summary['nativeWrapperPID'] = native.pid
        try:
            summary['nativeWrapperIdentityAtLaunch'] = identify(native.pid)
        except Exception as error:
            summary['nativeWrapperIdentityAtLaunchError'] = str(error)
        while native.poll() is None:
            now = time.monotonic()
            elapsed = now - started
            while received:
                signum = received.pop(0)
                if native.poll() is None:
                    native.send_signal(signum)
                if sampler is not None and sampler.poll() is None:
                    sampler.send_signal(signum)
            if sampler is not None and sampler.poll() is not None:
                finish_capture(active, sampler, identify)
                sampler = None
            if elapsed >= next_progress and len(summary['progress']) < 440:
                before = time.monotonic()
                try:
                    summary['progress'].append(progress.read(elapsed))
                except Exception as error:
                    if len(summary['errors']) < 8:
                        summary['errors'].append('Progress: ' + str(error))
                summary['progressObservationSeconds'] = round(summary.get('progressObservationSeconds', 0)
                    + time.monotonic() - before, 6)
                save(summary_path, summary)
                next_progress = elapsed + 1
            if slots and elapsed >= slots[0]:
                slot = slots.pop(0)
                try:
                    need(elapsed < 390 and sampler is None, 'Late or overlapping capture skipped')
                    sampler, active = start_capture(args, native, report_path, slot, identify)
                    active['actualStartSeconds'] = round(elapsed, 6)
                    summary['captures'].append(active)
                except Exception as error:
                    summary['captures'].append({'slotSeconds': slot, 'error': str(error)})
                save(summary_path, summary)
            time.sleep(0.05)
        summary['nativeExitCode'] = native.returncode
        summary['nativeExitObservedAtSeconds'] = round(time.monotonic() - started, 6)
    finally:
        # Cancelling this observer forwards to the owned bounded wrapper. Its
        # independent original 420s deadline/cleanup still controls native tests.
        if native is not None and native.poll() is None:
            native.terminate()
            try:
                native.wait(timeout=7)
            except subprocess.TimeoutExpired:
                summary['errors'].append('Native wrapper did not finish after forwarded cancellation')
        if sampler is not None and sampler.poll() is None:
            sampler.terminate()
            try:
                sampler.wait(timeout=2)
            except subprocess.TimeoutExpired:
                summary['errors'].append('Sampler wrapper did not finish within cleanup observation')
        if sampler is not None and active is not None:
            finish_capture(active, sampler, identify)
        summary['unconfirmedOwnedProcesses'] = []
        for role, process in (('native-wrapper', native), ('sampler-wrapper', sampler)):
            if process is not None and process.poll() is None:
                record = {'role': role, 'pid': process.pid, 'state': 'still live after bounded cleanup wait'}
                try:
                    record['identity'] = identify(process.pid)
                except Exception as error:
                    record['identityError'] = str(error)
                summary['unconfirmedOwnedProcesses'].append(record)
        summary['nativeCleanupConfirmed'], summary['nativeEnvelope'] = cleanup_evidence(
            report_path, native.returncode if native is not None else None, 420)
        summary['cleanupConfirmed'] = (summary['nativeCleanupConfirmed']
            and not summary['unconfirmedOwnedProcesses']
            and all(capture.get('samplerCleanupConfirmed', True) for capture in summary['captures']))
        elapsed = summary.get('nativeExitObservedAtSeconds', time.monotonic() - started)
        summary['expectedCaptureSlots'] = [slot for slot in CAPTURE_AT if slot <= elapsed]
        summary['completedCaptureSlots'] = [capture['slotSeconds'] for capture in summary['captures']
                                           if capture.get('status') == 'captured']
        summary['observationStatus'] = (
            'not-needed-before-first-sample' if not summary['expectedCaptureSlots'] else
            'complete' if summary['expectedCaptureSlots'] == summary['completedCaptureSlots']
            and not summary['errors'] else 'incomplete')
        summary['observerDurationSeconds'] = round(time.monotonic() - started, 6)
        if native is not None:
            summary['nativeExitCode'] = native.returncode
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        save(summary_path, summary)
    code = native.returncode if native.returncode >= 0 else 128 - native.returncode
    return code if code != 0 or summary['cleanupConfirmed'] else 125


def observe_process(command):
    """Forward suite cancellation without starting a later native process."""
    received = []
    def receive(number, _frame):
        if len(received) < 2:
            received.append(number)
    previous = {sig: signal.signal(sig, receive) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    process = None
    cancelled_at = None
    result = {'cancelled': False, 'cleanupWaitExpired': False}
    try:
        process = subprocess.Popen(command)
        while process.poll() is None:
            while received:
                signum = received.pop(0)
                result['cancelled'] = True
                cancelled_at = cancelled_at or time.monotonic()
                if process.poll() is None:
                    process.send_signal(signum)
            if cancelled_at is not None and time.monotonic() - cancelled_at >= 10:
                result.update(cleanupWaitExpired=True, observerPID=process.pid)
                try:
                    result['observerIdentity'] = ProcessIdentity()(process.pid)
                except Exception as error:
                    result['identityError'] = str(error)
                break
            time.sleep(0.05)
        result['returncode'] = process.returncode
        return result
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def suite(args):
    """Keep the complete four-process order; do not silently isolate process 3."""
    plan = NATIVE.checked_plan(args.plan, args.expected_source)
    need(plan['processCount'] == 4 and plan['selectionRegex'] == ''
         and plan['selectedTests'] == plan['discoveredTests'],
         'Diagnostic suite requires the complete four-process native plan')
    need(not args.output.exists(), 'Refusing to replace an aggregate result')
    status_path = args.output.with_name(args.output.stem + '-diagnostic-status.json')
    need(not status_path.exists(), 'Refusing to replace diagnostic suite status')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    status = {'schemaVersion': 1, 'sourceCommit': args.expected_source, 'outputMode': args.output_mode,
              'status': 'running', 'cleanupConfirmed': False, 'completedIndices': [],
              'nativeTimedOutIndices': [], 'returnCodes': [], 'processObservations': [],
              'observationComplete': False, 'nativeOutcome': 'pending'}
    save(status_path, status)
    codes = []
    for index in range(4):
        outcome = observe_process([sys.executable, str(Path(__file__).resolve()), 'run',
            '--plan', str(args.plan), '--expected-source', args.expected_source,
            '--index', str(index), '--directory', str(args.directory),
            '--diagnostics', str(args.diagnostics / f'shard-{index}'),
            '--output-mode', args.output_mode])
        codes.append(outcome['returncode'])
        status['returnCodes'] = codes
        if outcome['cleanupWaitExpired']:
            status.update(status='blocked-uncertain-cleanup', blockedIndex=index, observer=outcome)
            save(status_path, status)
            raise ValueError('Observer cleanup was not confirmed; do not start another cell')
        try:
            observed = json.loads(NATIVE.bounded_text(args.diagnostics / f'shard-{index}/diagnostics.json', METADATA_CAP))
            need(observed['sourceCommit'] == args.expected_source and observed['index'] == index
                 and observed['selectedTests'] == plan['shards'][index]['tests']
                 and observed['outputMode'] == args.output_mode and observed['cleanupConfirmed'] is True,
                 'Owned native/sampler cleanup was not confirmed')
        except Exception as error:
            status.update(status='blocked-uncertain-cleanup', blockedIndex=index, error=str(error))
            save(status_path, status)
            raise ValueError('Diagnostic suite stopped; do not start another cell with uncertain cleanup') from error
        status['completedIndices'].append(index)
        status['processObservations'].append({'index': index, 'status': observed['observationStatus']})
        if observed['nativeEnvelope'].get('status') == 'timeout':
            status['nativeTimedOutIndices'].append(index)
        if outcome['cancelled']:
            status['status'] = 'cancelled'
            save(status_path, status)
            return 143
        save(status_path, status)
    status['cleanupConfirmed'] = True
    status['observationComplete'] = all(record['status'] in ('complete', 'not-needed-before-first-sample')
                                        for record in status['processObservations'])
    try:
        result = NATIVE.aggregate(plan, args.directory)
    except Exception as error:
        status.update(status='native-failed', nativeOutcome='failed', error=str(error))
        save(status_path, status)
        raise
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    status['nativeOutcome'] = 'passed' if all(code == 0 for code in codes) else 'failed'
    status['status'] = ('native-failed' if status['nativeOutcome'] == 'failed' else
                        'passed' if status['observationComplete'] else 'observation-incomplete')
    save(status_path, status)
    return 0 if status['status'] == 'passed' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    for name in ('run', 'suite'):
        observe = actions.add_parser(name)
        observe.add_argument('--plan', type=Path, required=True)
        observe.add_argument('--expected-source', required=True)
        observe.add_argument('--directory', type=Path, required=True)
        observe.add_argument('--diagnostics', type=Path, required=True)
        observe.add_argument('--output-mode', choices=('baseline', 'unbuffered'), default='baseline')
        if name == 'run':
            observe.add_argument('--index', type=int, required=True)
        else:
            observe.add_argument('--output', type=Path, required=True)
    sample = actions.add_parser('sample')
    sample.add_argument('--request', type=Path, required=True)
    sample.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'sample':
        sample_exec(args.request, args.output)
        return 125
    return run(args) if args.action == 'run' else suite(args)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, OSError, TypeError) as error:
        print(f'Native diagnostic failed: {error}', file=sys.stderr)
        raise SystemExit(1)
