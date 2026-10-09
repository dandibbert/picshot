#!/usr/bin/env python3
"""Optional macOS observations around the unchanged bounded native command.

The baseline mode preserves the inherited environment. The separate unbuffered
control adds only NSUnbufferedIO=YES. Neither mode changes inventory, filters,
native timeouts, product defaults, or the native aggregate success requirements.
"""

import argparse
import ctypes
import errno
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
MAX_DIAGNOSTIC_DEPTH = 8
TARGET_CLEANUP_SECONDS = 2


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
        self.library.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32,
                                              ctypes.c_void_p, ctypes.c_int]
        self.library.proc_listpids.restype = ctypes.c_int

    def __call__(self, pid):
        need(type(pid) is int and 0 < pid <= 2147483647, 'Invalid process ID')
        info = BSDInfo()
        ctypes.set_errno(0)
        count = self.library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        if count == 0 and ctypes.get_errno():
            raise OSError(ctypes.get_errno(), 'Cannot read process identity', pid)
        need(count == ctypes.sizeof(info) and info.pid == pid, 'Missing or changed process identity')
        path = ctypes.create_string_buffer(4096)
        ctypes.set_errno(0)
        count = self.library.proc_pidpath(pid, path, len(path))
        if count == 0 and ctypes.get_errno():
            # Path lookup can return ESRCH for a missing/recycled executable
            # vnode. It does not prove that this already-observed PID retired.
            raise ValueError(f'Cannot read executable identity (errno {ctypes.get_errno()}); retirement unproven')
        need(0 < count < len(path) and path.value.startswith(b'/'), 'Missing executable identity')
        need(info.start_seconds > 0 and info.start_microseconds < 1000000, 'Invalid process birth time')
        return {'pid': pid, 'parentPID': info.ppid, 'groupID': info.pgid, 'uid': info.uid,
                'birthSeconds': info.start_seconds, 'birthMicroseconds': info.start_microseconds,
                'executable': path.value.decode('utf-8')}


    def children(self, pid):
        """Bounded direct-child PID census; never collect arguments/environment."""
        need(type(pid) is int and 0 < pid <= 2147483647, 'Invalid parent process ID')
        buffer = (ctypes.c_int * (MAX_DIAGNOSTIC_MEMBERS + 1))()
        ctypes.set_errno(0)
        # PROC_PPID_ONLY=6. proc_listpids returns bytes (unlike proc_listchildpids).
        count = self.library.proc_listpids(6, pid, buffer, ctypes.sizeof(buffer))
        if count == 0 and ctypes.get_errno():
            raise OSError(ctypes.get_errno(), 'Cannot enumerate owned children', pid)
        need(0 <= count < ctypes.sizeof(buffer) and count % ctypes.sizeof(ctypes.c_int) == 0,
             'Child census exceeded its bound or returned an invalid size')
        values = list(buffer[:count // ctypes.sizeof(ctypes.c_int)])
        need(all(0 < child <= 2147483647 for child in values) and len(set(values)) == len(values),
             'Invalid child census')
        return values


class SelectionError(ValueError):
    def __init__(self, message, census):
        super().__init__(message)
        self.census = census


def identity_key(value):
    return tuple(value[key] for key in ('pid', 'uid', 'birthSeconds', 'birthMicroseconds', 'executable'))


def identity_differences(expected, current):
    return {key: {'expected': expected.get(key), 'current': current.get(key)}
            for key in sorted(set(expected) | set(current)) if expected.get(key) != current.get(key)}


class WrapperBinding:
    """Bind the settled interpreter after the original bounded runner handshake.

    macOS framework Python can exec its application interpreter after Popen
    returns. The unreaped direct child and its lifetime identity remain pinned
    during this startup; executable identity becomes strict at the handshake.
    """
    ANCHOR_FIELDS = ('pid', 'parentPID', 'groupID', 'uid', 'birthSeconds', 'birthMicroseconds')

    def __init__(self, process, identify, expected_executable):
        self.process, self.identify = process, identify
        self.started = time.monotonic()
        self.initial = self.stable = None
        self.record = {'status': 'pending', 'wrapperPID': process.pid, 'ownerPID': os.getpid(),
                       'ownerUID': os.getuid(), 'expectedExecutable': expected_executable,
                       'initialIdentity': None, 'stableIdentity': None}
        try:
            need(isinstance(expected_executable, str) and expected_executable.startswith('/'),
                 'Missing actual interpreter executable identity')
            need(process.poll() is None, 'Owned wrapper exited before initial identity read')
            self.initial = identify(process.pid)
            self.record['initialIdentity'] = self.initial
            expected = {'pid': process.pid, 'parentPID': os.getpid(), 'uid': os.getuid()}
            self.record['initialOwnershipDifferences'] = identity_differences(
                expected, {key: self.initial.get(key) for key in expected})
            need(not self.record['initialOwnershipDifferences'], 'Initial wrapper is not the owned direct child')
            need(all(key in self.initial for key in self.ANCHOR_FIELDS), 'Incomplete initial wrapper identity')
        except Exception as error:
            self.record.update(status='blocked', initialIdentityError=str(error), error=str(error))
            self.record.setdefault('firstError', str(error))

    def observe(self, report, expected_command, timeout_seconds):
        try:
            need(self.record['status'] != 'blocked', 'Wrapper binding is already blocked')
            if report is not None:
                need(report['command'] == expected_command and report['timeout_seconds'] == timeout_seconds,
                     'Wrapper handshake command or deadline differs from the expected bounded command')
                if report['status'] in ('exited', 'timeout', 'cancelled', 'spawn_error'):
                    need(self.stable is not None, 'Wrapper finished before stable readiness binding')
                    need(report.get('pid') == self.record['handshakeLeaderPID'],
                         'Terminal wrapper leader differs from its verified handshake')
                    code = self.process.poll()
                    self.record.update(status='completed' if code is not None else 'finishing',
                        wrapperReturnCode=code, terminalEnvelopeObserved=report['status'])
                    return None
            code = self.process.poll()
            if code is not None:
                need(self.stable is not None, 'Owned wrapper exited during readiness binding')
                self.record.update(status='completed', wrapperReturnCode=code)
                return None
            try:
                current = self.identify(self.process.pid)
            except Exception as error:
                # The child may exit after poll but before proc_pidinfo. Only
                # owned Popen completion resolves that race; never inspect a
                # reaped PID. Descendant retirement is proved separately later.
                code = self.process.poll()
                if code is not None and self.stable is not None:
                    self.record.update(status='completed', wrapperReturnCode=code,
                                       identityReadAtCompletionError=str(error),
                                       identityReadAtCompletionErrorType=type(error).__name__)
                    return None
                raise
            self.record['lastObservedIdentity'] = current
            self.record['initialToCurrentDifferences'] = identity_differences(self.initial, current)
            expected_anchor = {key: self.initial[key] for key in self.ANCHOR_FIELDS}
            self.record['anchorDifferences'] = identity_differences(
                expected_anchor, {key: current.get(key) for key in self.ANCHOR_FIELDS})
            need(not self.record['anchorDifferences'], 'Wrapper lifetime identity changed before/after readiness')
            if self.stable is not None:
                self.record['stableDifferences'] = identity_differences(self.stable, current)
                need(not self.record['stableDifferences'], 'Stable wrapper identity changed')
            if report is None:
                need(self.stable is None, 'Bounded runner envelope disappeared after binding')
                return None
            if report['status'] == 'starting':
                need(self.stable is None and report.get('pid') is None, 'Invalid starting wrapper handshake')
                return None
            if report['status'] == 'terminating':
                need(self.stable is not None and report.get('pid') == self.record['handshakeLeaderPID']
                     and report.get('termination_reason') in ('exited', 'timeout', 'cancelled'),
                     'Invalid terminating wrapper handshake')
                self.record.update(status='finishing', terminalEnvelopeObserved='terminating',
                                   terminationReason=report['termination_reason'])
                return None
            need(report['status'] == 'running' and type(report['pid']) is int and report['pid'] > 0,
                 'Invalid running wrapper handshake')
            self.record['handshakeLeaderPID'] = report['pid']
            self.record['executableDifferences'] = identity_differences(
                {'executable': self.record['expectedExecutable']}, {'executable': current.get('executable')})
            need(not self.record['executableDifferences'], 'Ready wrapper is not the exact known interpreter executable')
            if self.stable is None:
                self.stable = current.copy()
                self.record.update(status='bound', stableIdentity=self.stable,
                    boundAtSeconds=round(time.monotonic() - self.started, 6),
                    initialToStableDifferences=identity_differences(self.initial, self.stable))
            return self.stable
        except Exception as error:
            self.record.update(status='blocked', error=str(error))
            self.record.setdefault('firstError', str(error))
            raise
        finally:
            self.record['lastObservedAtSeconds'] = round(time.monotonic() - self.started, 6)


def is_xctest(value):
    return value['executable'].endswith('.app/Contents/Developer/usr/bin/xctest')


def owned_target(wrapper_pid, leader_pid, identify, children=None,
                 expected_wrapper=None, expected_leader=None):
    """Follow rechecked parent edges, including descendants in different groups.

    The census is deliberately non-atomic. Every identity and parent edge is
    rechecked before selection; any ambiguity fails closed and retains scalars.
    """
    census = {'members': [], 'candidatePIDs': [], 'atomicSnapshot': False,
              'anchorValidated': False, 'complete': False,
              'memberCap': MAX_DIAGNOSTIC_MEMBERS, 'depthCap': MAX_DIAGNOSTIC_DEPTH}
    try:
        children = children or identify.children
        wrapper = identify(wrapper_pid)
        leader = identify(leader_pid)
        census.update(wrapper=wrapper, leader=leader)
        if expected_wrapper is not None:
            census['expectedWrapper'] = expected_wrapper
            census['wrapperDifferences'] = identity_differences(expected_wrapper, wrapper)
        if expected_leader is not None:
            census['expectedLeader'] = expected_leader
            census['leaderDifferences'] = identity_differences(expected_leader, leader)
        need(expected_wrapper is None or wrapper == expected_wrapper, 'Wrapper identity changed')
        need(expected_leader is None or leader == expected_leader, 'Native leader identity changed')
        need(leader['parentPID'] == wrapper_pid and leader['groupID'] == leader_pid,
             'Native leader does not belong to the launched wrapper')
        need(wrapper['uid'] == leader['uid'] == os.getuid(), 'Unexpected native process owner')
        census['anchorValidated'] = True
        queue = [(leader, 0)]
        seen = {wrapper_pid, leader_pid}
        while queue:
            parent, depth = queue.pop(0)
            census['members'].append(parent)
            child_pids = children(parent['pid'])
            need(len(child_pids) <= MAX_DIAGNOSTIC_MEMBERS, 'Child census exceeds observation bound')
            need(not child_pids or depth < MAX_DIAGNOSTIC_DEPTH, 'Owned tree exceeds depth bound')
            for pid in child_pids:
                need(pid not in seen and len(seen) <= MAX_DIAGNOSTIC_MEMBERS,
                     'Owned tree exceeds member bound or has duplicate edges')
                member = identify(pid)
                need(member['parentPID'] == parent['pid'] and member['uid'] == wrapper['uid'],
                     'Child identity no longer matches its owned parent')
                seen.add(pid)
                queue.append((member, depth + 1))
        census['candidatePIDs'] = [member['pid'] for member in census['members'] if is_xctest(member)]
        for member in [wrapper] + census['members']:
            need(identify(member['pid']) == member, 'Process identity changed during observation')
        census['complete'] = True
        need(len(census['candidatePIDs']) == 1, 'Expected exactly one owned Xcode XCTest process')
        census['target'] = next(member for member in census['members'] if is_xctest(member))
        return census
    except Exception as error:
        census['error'] = str(error)
        raise SelectionError(str(error), census) from error


def target_state(target, identify):
    """Reparenting is allowed after launch; UID/birth/executable changes are not."""
    try:
        current = identify(target['pid'])
    except OSError as error:
        return {'state': 'retired' if error.errno == errno.ESRCH else 'unknown', 'error': str(error)}
    except Exception as error:
        return {'state': 'unknown', 'error': str(error)}
    if (current['birthSeconds'], current['birthMicroseconds']) != (
            target['birthSeconds'], target['birthMicroseconds']):
        return {'state': 'retired', 'reason': 'PID now has a different birth identity', 'current': current}
    if identity_key(current) != identity_key(target):
        return {'state': 'unknown', 'reason': 'Owned UID or executable identity changed', 'current': current}
    return {'state': 'live', 'current': current}


def retire_targets(targets, identify, budget_seconds=TARGET_CLEANUP_SECONDS):
    """Retire only proven owned XCTest PIDs after native wrapper completion.

    No name lookup, arbitrary process signal, or process-group signal is used.
    Every signal gets an immediate immutable-identity recheck; unknown is blocked.
    """
    need(0 < budget_seconds <= TARGET_CLEANUP_SECONDS, 'Invalid target cleanup budget')
    need(len(targets) <= MAX_DIAGNOSTIC_MEMBERS, 'Too many owned target identities')
    started = time.monotonic()
    records = [{'identity': target, 'signals': []} for target in targets]
    for signum in (signal.SIGTERM, signal.SIGKILL):
        for record in records:
            if time.monotonic() - started >= budget_seconds:
                break
            state = target_state(record['identity'], identify)
            record.update(state)
            if state['state'] == 'live':
                try:
                    os.kill(record['identity']['pid'], signum)
                    record['signals'].append(int(signum))
                except ProcessLookupError:
                    record.update(state='retired', reason='Process exited before signal')
                except OSError as error:
                    record.update(state='unknown', error=str(error))
        until = min(started + budget_seconds, time.monotonic() + (0.5 if signum == signal.SIGTERM else budget_seconds))
        while time.monotonic() < until:
            for record in records:
                record.update(target_state(record['identity'], identify))
            if all(record.get('state') != 'live' for record in records):
                break
            time.sleep(min(0.05, max(0, until - time.monotonic())))
    for record in records:
        record.update(target_state(record['identity'], identify))
    return {'confirmed': bool(records) and all(record['state'] == 'retired' for record in records),
            'targets': records, 'budgetSeconds': budget_seconds,
            'durationSeconds': round(time.monotonic() - started, 6),
            'scope': 'Previously parent-chain-validated XCTest identities only; not a global process census'}


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
    current = owned_target(record['wrapper']['pid'], record['leader']['pid'], identify,
                           expected_wrapper=record['wrapper'], expected_leader=record['leader'])
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


class Ownership:
    def __init__(self, wrapper, binding=None):
        self.started = time.monotonic()
        self.wrapper = wrapper
        self.binding = binding
        self.leader = None
        self.targets = []
        self.record = {'successfulCensuses': 0, 'failedCensuses': 0,
                       'uncertainCensus': False, 'observationSeconds': 0,
                       'identityScope': 'Anchored parent chain across process groups'}

    def accept(self, census):
        census['observedAtSeconds'] = round(time.monotonic() - self.started, 6)
        self.record['lastCensus'] = census
        if census.get('pending'):
            return
        if census.get('complete'):
            for member in census['members']:
                if is_xctest(member) and all(identity_key(member) != identity_key(known) for known in self.targets):
                    need(len(self.targets) < MAX_DIAGNOSTIC_MEMBERS, 'Too many observed XCTest identities')
                    self.targets.append(member)
        if census.get('target'):
            self.leader = census['leader']
            self.record.setdefault('firstSelection', census)
            self.record['successfulCensuses'] += 1
        else:
            self.record['failedCensuses'] += 1
            self.record.setdefault('firstFailedCensus', census)
            if not census.get('complete') or len(census.get('candidatePIDs', [])) > 1:
                self.record['uncertainCensus'] = True
                self.record.setdefault('firstUncertainCensus', census)

    def observe(self, native, report_path, expected_command, identify):
        started = time.monotonic()
        try:
            if self.binding is not None:
                report = (json.loads(NATIVE.bounded_text(report_path, METADATA_CAP))
                          if report_path.exists() else None)
                ready = self.binding.observe(report, expected_command, 420)
                if ready is None:
                    self.accept({'pending': 'Awaiting wrapper readiness or observing its completed envelope',
                                 'complete': False})
                    return
                self.wrapper = ready
            need(self.wrapper is not None, 'Stable wrapper identity was not established')
            if not report_path.exists():
                self.accept({'pending': 'Awaiting original bounded runner envelope', 'complete': False})
                return
            report = json.loads(NATIVE.bounded_text(report_path, METADATA_CAP))
            need(report['timeout_seconds'] == 420
                 and report['command'] == expected_command, 'Native running envelope does not match the original plan')
            if report['status'] in ('exited', 'timeout', 'cancelled', 'spawn_error'):
                self.accept({'pending': 'Original bounded runner is finishing', 'complete': False})
                return
            need(report['status'] == 'running', 'Unexpected native bounded runner status')
            need(native.poll() is None, 'Native wrapper exited before census')
            census = owned_target(native.pid, report['pid'], identify,
                                  expected_wrapper=self.wrapper, expected_leader=self.leader)
        except SelectionError as error:
            census = error.census
        except Exception as error:
            census = {'error': str(error), 'complete': False, 'anchorValidated': False}
        self.accept(census)
        self.record['observationSeconds'] = round(self.record['observationSeconds'] + time.monotonic() - started, 6)


def start_capture(args, native, report_path, slot, identify, ownership=None):
    started = time.monotonic()
    report = json.loads(NATIVE.bounded_text(report_path, METADATA_CAP))
    need(report['status'] == 'running' and report['timeout_seconds'] == 420,
         'Native bounded process is not running at the original cap')
    plan = NATIVE.checked_plan(args.plan, args.expected_source)
    need(report['command'] == NATIVE.expected_command(plan['shards'][args.index]),
         'Native command differs from the verified plan')
    need(native.poll() is None, 'Native wrapper already exited')
    need(ownership is None or ownership.wrapper is not None, 'Launch wrapper identity was not established')
    try:
        request = owned_target(native.pid, report['pid'], identify,
            expected_wrapper=ownership.wrapper if ownership is not None else None,
            expected_leader=ownership.leader if ownership is not None else None)
    except SelectionError as error:
        if ownership is not None:
            ownership.accept(error.census)
        raise
    if ownership is not None:
        ownership.accept(request)
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
    expected_interpreter = identify(os.getpid())['executable']
    plan = NATIVE.checked_plan(args.plan, args.expected_source)
    need(0 <= args.index < plan['processCount'], 'Index outside verified native plan')
    need(plan['timeoutSecondsPerProcess'] == 420, 'Native deadline changed')
    log_path, report_path = NATIVE.paths(args.directory, args.index)
    need(not log_path.exists() and not report_path.exists(), 'Refusing to reuse native results')
    args.diagnostics.mkdir(parents=True, exist_ok=False, mode=0o700)
    summary_path = args.diagnostics / 'diagnostics.json'
    summary = {'schemaVersion': 2, 'sourceCommit': args.expected_source, 'index': args.index,
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
    ownership = None
    started = time.monotonic()
    next_progress = 0
    next_census = 0
    slots = list(CAPTURE_AT)
    progress = Progress(log_path)
    try:
        native = subprocess.Popen(native_command(args), stdin=subprocess.DEVNULL,
                                  env=environment(args.output_mode, os.environ))
        summary['nativeWrapperPID'] = native.pid
        binding = WrapperBinding(native, identify, expected_interpreter)
        summary['wrapperBinding'] = binding.record
        summary['nativeWrapperIdentityAtLaunch'] = binding.record['initialIdentity']
        ownership = Ownership(None, binding=binding)
        summary['ownership'] = ownership.record
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
            if elapsed >= next_census:
                ownership.observe(native, report_path, NATIVE.expected_command(plan['shards'][args.index]), identify)
                next_census = elapsed + (0.1 if ownership.leader is None and elapsed < 10 else 1)
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
                    sampler, active = start_capture(args, native, report_path, slot, identify, ownership)
                    active['actualStartSeconds'] = round(elapsed, 6)
                    summary['captures'].append(active)
                except Exception as error:
                    record = {'slotSeconds': slot, 'error': str(error), 'samplerLaunched': False}
                    if isinstance(error, SelectionError):
                        record['selectionCensus'] = error.census
                    summary['captures'].append(record)
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
            try:
                finish_capture(active, sampler, identify)
            except Exception as error:
                active.update(status='incomplete', samplerCleanupConfirmed=False, error=str(error))
        # The original wrapper retires only its original process group. SwiftPM
        # can put XCTest in another group. Retire only identities proven earlier
        # by the parent chain, after the original wrapper has finished/cancelled.
        summary['nativeXCTestRetirement'] = retire_targets(ownership.targets if ownership else [], identify)
        summary['nativeXCTestCleanupConfirmed'] = summary['nativeXCTestRetirement']['confirmed']
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
        summary['cleanupConfirmed'] = (summary['nativeCleanupConfirmed'] and summary['nativeXCTestCleanupConfirmed']
            and ownership is not None and not ownership.record['uncertainCensus']
            and not summary['unconfirmedOwnedProcesses']
            and all(capture.get('samplerCleanupConfirmed', True) for capture in summary['captures']))
        elapsed = summary.get('nativeExitObservedAtSeconds', time.monotonic() - started)
        summary['expectedCaptureSlots'] = [slot for slot in CAPTURE_AT if slot <= elapsed]
        summary['completedCaptureSlots'] = [capture['slotSeconds'] for capture in summary['captures']
                                           if capture.get('status') == 'captured']
        summary['observationStatus'] = (
            'incomplete' if ownership is None or not ownership.record['successfulCensuses'] else
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
