#!/usr/bin/env python3
"""One original227 NSWorkspace replay; native allocation evidence, never acceptance.

This is deliberately not a general process observer. It starts the selected Swift
launcher once, accepts only its token-bound launch receipt and ten fixed requests,
and runs vmmap/heap/malloc_history against that exact app identity. No dumps,
process-name lookup, sudo, fallback log destination, or security-setting changes.
"""
import argparse
import ctypes
import errno
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
MIB = 1024 * 1024
VOLUME_BYTES = 256 * MIB
TEXT_BYTES = 64 * MIB
PROTOCOL = 'picshot-live-scroll-allocation-diagnostic-v1'
DIAG_DIR = 'PICSHOT_LIVE_SCROLL_ALLOCATION_DIAGNOSTIC'
DIAG_TOKEN = 'PICSHOT_LIVE_SCROLL_ALLOCATION_DIAGNOSTIC_TOKEN'
CHECKPOINTS = [(4, 'released-plus-1000ms'), (5, 'pre-finish-pending-edge'),
    (5, 'released-plus-1000ms'), (8, 'released-plus-1000ms'),
    (9, 'finish-image-alive-before-png'), (9, 'png-finalized-image-alive'),
    (9, 'released-plus-1000ms'), (10, 'released-plus-1000ms')]
REQUEST_KEYS = {'schemaVersion', 'protocol', 'runToken', 'sequence', 'requestID',
    'kind', 'cycleOrdinal', 'phase', 'identity', 'publishedUptimeSeconds',
    'replyDeadlineUptimeSeconds', 'maximumHoldSeconds', 'fixtureDeadlineUptimeSeconds',
    'mainActorBlocked', 'perturbationLabel', 'mallocEnvironment', 'calibration'}
IDENTITY_KEYS = {'pid', 'processStartEpochSeconds', 'processStartUptimeSeconds',
                 'executablePath', 'executableSHA256'}
LAUNCH_KEYS = {'schemaVersion', 'protocol', 'runToken', 'launcherPID',
    'launcherStartEpochSeconds', 'appPID', 'appLaunchEpochSeconds', 'selectedAppPath',
    'executablePath', 'executableSHA256'}
BAD_TEXT = re.compile(r'(?i)(no space left|disk (?:is )?full|stack log\w*[^\n]{0,80}'
    r'(?:truncat|disable|fail|error|cannot)|unable to (?:read|open|attach)|'
    r'cannot (?:read|open|attach)|permission denied|operation not permitted)')


class ProbeError(RuntimeError):
    pass


def need(value, code):
    if not value:
        raise ProbeError(code)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def sha_file(path):
    need(path.is_file() and not path.is_symlink(), 'identity-file-invalid')
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(MIB), b''):
            value.update(chunk)
    return value.hexdigest()


def private_regular(path, maximum, private=True):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        need(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
             and info.st_nlink == 1 and (not private or info.st_mode & 0o077 == 0) and 0 < info.st_size <= maximum,
             'invalid-owned-protocol-file')
        result = os.read(fd, maximum + 1)
        need(len(result) == info.st_size and len(result) <= maximum,
             'protocol-file-changed-or-oversized')
        return result
    finally:
        os.close(fd)


def read_json(path, private=True):
    def duplicate(pairs):
        result = {}
        for key, value in pairs:
            need(key not in result, 'duplicate-json-key')
            result[key] = value
        return result
    try:
        return json.loads(private_regular(path, 64 * 1024, private=private), object_pairs_hook=duplicate,
                          parse_constant=lambda _: (_ for _ in ()).throw(ProbeError('nonfinite-json')))
    except (UnicodeError, json.JSONDecodeError):
        raise ProbeError('invalid-json') from None


def atomic_json(path, value):
    data = (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()
    need(len(data) <= MIB, 'metadata-cap-exceeded')
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def clean_environment(source=None):
    source = os.environ if source is None else source
    return {**{key: value for key, value in source.items() if not key.startswith('Malloc')},
            'LC_ALL': 'C'}


def bounded_module():
    path = Path(__file__).with_name('run-bounded-command.py')
    spec = importlib.util.spec_from_file_location('original227_bounded', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TextBudget:
    def __init__(self, directory, maximum=TEXT_BYTES - 2 * MIB):
        self.directory, self.maximum, self.retained = directory, maximum, 0
        self.records = []

    def retain(self, name, text):
        # Native output can contain a login name through a loaded image path.
        # Never preserve home names or an inherited environment listing.
        text = re.sub(r'/Users/[^/\s]+', '<USER_HOME>', text)
        text = re.sub(r'/home/[^/\s]+', '<USER_HOME>', text)
        data = text.encode('utf-8')
        need(self.retained + len(data) <= self.maximum, 'retained-text-cap-exceeded')
        path = self.directory / name
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
        self.retained += len(data)
        self.records.append({'file': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        return text


class NativeCommands:
    """Stream-bounded pipes; reuse the existing unreaped process-group anchor."""
    def __init__(self, budget, bounded=None):
        self.budget = budget
        self.bounded = bounded or bounded_module()
        self.records = []
        self.health = None

    def run(self, argv, deadline, name, cap=2 * MIB, allowed=(0,), env=None, scan=True, retain_filter=None):
        need(time.monotonic() + 0.75 < deadline, 'tool-deadline-exhausted')
        reserve = 0 if name == 'volume-detach.txt' else 2 * MIB
        cap = min(cap, self.budget.maximum - self.budget.retained - reserve)
        need(cap > 0, 'retained-text-cap-exceeded')
        started = time.monotonic()
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, shell=False, start_new_session=True,
            env=clean_environment(env))
        group = self.bounded.ProcessGroup(child)
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ)
        os.set_blocking(child.stdout.fileno(), False)
        captured = bytearray()
        failure = None
        clean = False
        code = None
        try:
            while True:
                if self.health:
                    self.health()
                if time.monotonic() >= deadline - 0.65:
                    failure = 'native-tool-timeout'
                    break
                for key, _ in selector.select(0.01):
                    data = os.read(key.fd, min(64 * 1024, cap - len(captured) + 1))
                    if not data:
                        selector.unregister(key.fileobj)
                    else:
                        captured.extend(data)
                        if len(captured) > cap:
                            failure = 'native-tool-output-cap'
                            break
                if failure:
                    break
                if group.leader_exited() and not selector.get_map():
                    # A successful tool must leave no running same-group child.
                    if group.alive():
                        failure = 'native-tool-descendant-left-running'
                    break
        finally:
            # Never reap the group leader before all numeric-PGID operations end.
            try:
                if group.alive():
                    group.send(signal.SIGTERM)
                    until = min(deadline, time.monotonic() + 0.10)
                    while time.monotonic() < until and group.alive():
                        time.sleep(0.01)
                    if group.alive():
                        group.send(signal.SIGKILL)
                    until = min(deadline + 0.1, time.monotonic() + 0.50)
                    while time.monotonic() < until and group.alive():
                        time.sleep(0.01)
                clean = not group.alive()
            except Exception:
                # A failed descendant observation is never proof of retirement.
                # Still attempt exact unreaped-group KILL and preserve a failed
                # cleanup record so downstream consumers cannot infer all-clear.
                clean = False
                failure = 'native-tool-cleanup-observation-failed'
                try:
                    group.send(signal.SIGKILL)
                except Exception:
                    pass
            finally:
                group.close()
                selector.close()
                child.stdout.close()
                try:
                    code = child.wait(timeout=0.2)
                except subprocess.TimeoutExpired:
                    clean = False
            record = {'name': name, 'tool': Path(argv[0]).name, 'returnCode': code,
                'durationSeconds': time.monotonic() - started, 'observedBytes': len(captured),
                'outputTruncated': len(captured) > cap, 'cleanupConfirmed': clean,
                'failure': failure}
            self.records.append(record)
        need(clean, 'native-tool-cleanup-incomplete')
        # Overflow text is deliberately not retained as a seemingly complete snapshot.
        need(failure is None, failure or 'native-tool-failed')
        raw = captured.decode('utf-8', errors='replace')
        if retain_filter is not None:
            need(code in allowed, 'native-tool-nonzero')
            need(not scan or not BAD_TEXT.search(raw), 'native-tool-access-or-logging-failure')
            raw = retain_filter(raw)
        text = self.budget.retain(name, raw)
        need(code in allowed, 'native-tool-nonzero')
        need(not scan or not BAD_TEXT.search(text), 'native-tool-access-or-logging-failure')
        return text


class BSDInfo(ctypes.Structure):
    # Existing native-test-diagnostics.py public libproc ABI, no process census.
    _fields_ = [(name, ctypes.c_uint32) for name in ('flags', 'status', 'xstatus', 'pid',
        'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'jobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_seconds', ctypes.c_uint64),
                 ('start_microseconds', ctypes.c_uint64)]


class DarwinIdentity:
    def __init__(self):
        need(sys.platform == 'darwin' and ctypes.sizeof(BSDInfo) == 136, 'darwin-identity-unavailable')
        self.denied_pids = set()
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                        ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidinfo.restype = ctypes.c_int
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_pidpath.restype = ctypes.c_int

    def __call__(self, pid):
        need(type(pid) is int and 1 < pid <= 2147483647, 'invalid-owned-pid')
        need(pid not in self.denied_pids, 'native-identity-access-denied')
        info, path = BSDInfo(), ctypes.create_string_buffer(4096)
        ctypes.set_errno(0)
        count = self.lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        if count == 0 and ctypes.get_errno() in (errno.EPERM, errno.EACCES):
            self.denied_pids.add(pid)
            raise ProbeError('native-identity-access-denied')
        if count == 0 and ctypes.get_errno() == errno.ESRCH:
            raise ProcessLookupError(pid)
        need(count == ctypes.sizeof(info) and info.pid == pid, 'native-identity-unavailable')
        ctypes.set_errno(0)
        count = self.lib.proc_pidpath(pid, path, len(path))
        if count == 0 and ctypes.get_errno() in (errno.EPERM, errno.EACCES):
            self.denied_pids.add(pid)
            raise ProbeError('native-identity-access-denied')
        need(0 < count < len(path) and path.value.startswith(b'/'), 'native-executable-unavailable')
        need(info.start_seconds > 0 and info.start_microseconds < 1000000, 'native-birth-invalid')
        return {'pid': pid, 'uid': info.uid, 'parentPID': info.ppid, 'groupID': info.pgid,
            'birthSeconds': info.start_seconds, 'birthMicroseconds': info.start_microseconds,
            'executablePath': os.path.realpath(os.fsdecode(path.value))}


def validate_launch(launch, token, launcher_pid, app, executable, digest, native, launcher_native):
    need(type(launch) is dict and set(launch) == LAUNCH_KEYS, 'launch-receipt-schema')
    need(type(launch['schemaVersion']) is int and launch['schemaVersion'] == 1 and launch['protocol'] == PROTOCOL
         and launch['runToken'] == token, 'launch-receipt-token')
    need(type(launch['launcherPID']) is int and launch['launcherPID'] == launcher_pid
         and launcher_native['pid'] == launcher_pid and launcher_native['parentPID'] == os.getpid()
         and launcher_native['uid'] == os.getuid(), 'launcher-ownership-mismatch')
    need(type(launch['appPID']) is int and launch['appPID'] == native['pid']
         and native['uid'] == os.getuid(), 'app-ownership-mismatch')
    need(launch['selectedAppPath'] == str(app) and launch['executablePath'] == str(executable)
         and native['executablePath'] == str(executable)
         and launch['executableSHA256'] == digest, 'app-executable-mismatch')
    for field, observed in [('appLaunchEpochSeconds', native),
                            ('launcherStartEpochSeconds', launcher_native)]:
        birth = observed['birthSeconds'] + observed['birthMicroseconds'] / 1000000
        # Fail closed if LaunchServices cannot bind kernel birth within 1ms.
        # Never widen this tolerance on a failed native run.
        need(finite(launch[field]) and abs(launch[field] - birth) <= 0.001,
             'launch-birth-mismatch')


def validate_request(request, sequence, token, launch, logging_env, now):
    need(type(request) is dict and set(request) == REQUEST_KEYS, 'request-schema')
    need(type(request['schemaVersion']) is int and request['schemaVersion'] == 1
         and request['protocol'] == PROTOCOL and request['runToken'] == token
         and type(request['sequence']) is int and request['sequence'] == sequence, 'request-binding')
    try:
        need(str(uuid.UUID(request['requestID'])).lower() == request['requestID'].lower(), 'request-id')
    except (ValueError, AttributeError, TypeError):
        raise ProbeError('request-id') from None
    identity = request['identity']
    need(type(identity) is dict and set(identity) == IDENTITY_KEYS, 'request-identity-schema')
    need(type(identity['pid']) is int and identity['pid'] == launch['appPID']
         and identity['executablePath'] == launch['executablePath']
         and identity['executableSHA256'] == launch['executableSHA256']
         and identity['processStartEpochSeconds'] == launch['appLaunchEpochSeconds'],
         'request-identity-mismatch')
    need(finite(identity['processStartUptimeSeconds']) and identity['processStartUptimeSeconds'] > 0,
         'request-start-uptime')
    need(request['mainActorBlocked'] is True and type(request['perturbationLabel']) is str
         and 0 < len(request['perturbationLabel']) <= 1024, 'request-hold-scope')
    need(request['mallocEnvironment'] == logging_env, 'request-logging-environment')
    hold = 15 if sequence <= 2 else 10
    for key in ['publishedUptimeSeconds', 'replyDeadlineUptimeSeconds', 'maximumHoldSeconds',
                'fixtureDeadlineUptimeSeconds']:
        need(finite(request[key]), 'request-invalid-time')
    need(request['maximumHoldSeconds'] == hold
         and identity['processStartUptimeSeconds'] <= request['publishedUptimeSeconds']
         and request['publishedUptimeSeconds'] <= now + 0.25
         and now < request['replyDeadlineUptimeSeconds']
         and 0 < request['replyDeadlineUptimeSeconds'] - request['publishedUptimeSeconds'] <= hold + 0.01
         and request['replyDeadlineUptimeSeconds'] <= request['fixtureDeadlineUptimeSeconds'],
         'request-deadline')
    need(type(request['cycleOrdinal']) is int, 'request-cycle-type')
    if sequence <= 2:
        kind = 'calibration-live' if sequence == 1 else 'calibration-released'
        need(request['kind'] == kind and request['cycleOrdinal'] == 0
             and request['phase'] == ('calibration-owned-allocation-live' if sequence == 1
                                      else 'calibration-owned-allocation-released'), 'calibration-order')
        calibration = request['calibration']
        need(type(calibration) is dict and set(calibration) == {'address', 'requestedBytes', 'usableBytes'},
             'calibration-schema')
        need(type(calibration['address']) is str
             and re.fullmatch(r'0x[0-9a-fA-F]{1,16}', calibration['address'])
             and int(calibration['address'], 16) > 0 and type(calibration['requestedBytes']) is int
             and calibration['requestedBytes'] == 65537 and type(calibration['usableBytes']) is int
             and 65537 <= calibration['usableBytes'] <= MIB, 'calibration-values')
    else:
        need(3 <= sequence <= 10 and request['kind'] == 'checkpoint'
             and (request['cycleOrdinal'], request['phase']) == CHECKPOINTS[sequence - 3]
             and request['calibration'] is None, 'checkpoint-order')
    return request['replyDeadlineUptimeSeconds'] - 0.12


def reply_for(request, status, error=''):
    need(status in ('ok', 'failed') and (error == '' if status == 'ok' else bool(error))
         and (not error or re.fullmatch(r'[a-z0-9-]{1,128}', error)), 'invalid-reply')
    return {'schemaVersion': 1, 'protocol': PROTOCOL, 'runToken': request['runToken'],
        'sequence': request['sequence'], 'requestID': request['requestID'],
        'identity': request['identity'], 'status': status,
        'completedUptimeSeconds': time.monotonic(), 'errorCode': error}


def capacity_receipt(mount, parent, root, fs, sentinel_bytes, saw_enospc, restored_free):
    total = fs.f_blocks * fs.f_frsize
    need(mount.st_dev != parent.st_dev and mount.st_dev != root.st_dev,
         'volume-is-not-isolated')
    need(0 < total <= VOLUME_BYTES and fs.f_frsize > 0, 'volume-exceeds-fixed-capacity')
    need(saw_enospc is True and 0 < sentinel_bytes <= VOLUME_BYTES + MIB,
         'volume-enospc-unproven')
    need(restored_free >= min(16 * MIB, total // 2), 'volume-capacity-not-restored')
    return {'fixedCapacityBytes': VOLUME_BYTES, 'statfsTotalBytes': total,
        'separateDeviceFromParentAndRoot': True, 'enospcObserved': True,
        'calibrationBytesWritten': sentinel_bytes, 'calibrationFileUnlinked': True,
        'availableBytesAfterCalibration': restored_free}


class FixedLogVolume:
    def __init__(self, commands):
        self.commands = commands
        self.base = Path(tempfile.mkdtemp(prefix='picshot227-alloc-')).resolve()
        os.chmod(self.base, 0o700)
        self.image = self.base / 'logs.dmg'
        self.mount = self.base / 'mount'
        self.mount.mkdir(mode=0o700)
        self.logs = self.mount / 'stack-logs'
        self.device = None
        self.mount_device = None
        self.attached = False
        self.receipt = None
        self.cleanup_confirmed = False
        self.peak_used = 0
        self.seen_log = False

    def prepare(self, deadline):
        self.commands.run(['/usr/bin/hdiutil', 'create', '-size', '256m', '-fs', 'HFS+',
            '-volname', 'PicShot227Alloc', '-format', 'UDRW', str(self.image)], deadline,
            'volume-create.txt', cap=256 * 1024)
        need(self.image.is_file() and not self.image.is_symlink(), 'volume-image-invalid')
        # A UDIF trailer may add a small amount to the backing image; capacity
        # is established by mounted statfs, not host sparse-file logical size.
        need(self.image.stat().st_size <= VOLUME_BYTES + MIB, 'volume-backing-image-oversized')
        text = self.commands.run(['/usr/bin/hdiutil', 'attach', '-nobrowse', '-noautoopen',
            '-mountpoint', str(self.mount), '-plist', str(self.image)], deadline,
            'volume-attach.txt', cap=256 * 1024)
        # Even malformed plist must not make an attached volume invisible to cleanup.
        self.attached = self.mount.stat().st_dev != self.base.stat().st_dev
        try:
            info = plistlib.loads(text.encode())
        except Exception:
            raise ProbeError('volume-attach-receipt-invalid') from None
        matches = [entry for entry in info.get('system-entities', [])
                   if entry.get('mount-point') == str(self.mount)]
        need(len(matches) == 1 and re.fullmatch(r'/dev/disk[0-9]+s[0-9]+', matches[0].get('dev-entry', '')),
             'volume-mount-binding-invalid')
        self.device = matches[0]['dev-entry']
        self.mount_device = self.mount.stat().st_dev
        need(self.attached and not self.mount.is_symlink() and self.mount.resolve() != Path('/'),
             'volume-mount-invalid')
        fs = os.statvfs(self.mount)
        need(0 < fs.f_blocks * fs.f_frsize <= VOLUME_BYTES, 'volume-exceeds-fixed-capacity')
        need(self.mount.stat().st_dev not in (self.base.stat().st_dev, Path('/').stat().st_dev),
             'volume-is-not-isolated')
        sentinel = self.mount / ('capacity-' + uuid.uuid4().hex)
        written, enospc = 0, False
        fd = os.open(sentinel, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        # Real non-sparse writes, a bounded 257MiB maximum, and no generated data retained.
        chunk = bytes(range(256)) * 4096
        try:
            while written < VOLUME_BYTES + MIB:
                need(time.monotonic() < deadline, 'volume-calibration-timeout')
                try:
                    count = os.write(fd, chunk[:min(len(chunk), VOLUME_BYTES + MIB - written)])
                    need(count > 0, 'volume-calibration-short-write')
                    written += count
                except OSError as error:
                    if error.errno != errno.ENOSPC:
                        raise
                    enospc = True
                    break
            try:
                os.fsync(fd)
            except OSError as error:
                if error.errno != errno.ENOSPC:
                    raise
                enospc = True
        finally:
            os.close(fd)
            sentinel.unlink()
        after = os.statvfs(self.mount)
        self.receipt = capacity_receipt(self.mount.stat(), self.base.stat(), Path('/').stat(), fs,
            written, enospc, after.f_bavail * after.f_frsize)
        self.logs.mkdir(mode=0o700)
        return self.receipt

    def environment(self):
        need(self.receipt is not None, 'volume-preflight-incomplete')
        return {'MallocStackLogging': 'full', 'MallocStackLoggingNoCompact': '1',
                'MallocStackLoggingDirectory': str(self.logs)}

    def health(self, require_space=True):
        need(self.attached and self.mount.stat().st_dev == self.mount_device
             and self.mount.stat().st_dev != self.base.stat().st_dev
             and not self.mount.is_symlink() and not self.logs.is_symlink()
             and self.logs.stat().st_dev == self.mount_device, 'stack-volume-disappeared')
        fs = os.statvfs(self.mount)
        need(0 < fs.f_blocks * fs.f_frsize <= VOLUME_BYTES, 'stack-volume-capacity-changed')
        free = fs.f_bavail * fs.f_frsize
        self.peak_used = max(self.peak_used, (fs.f_blocks - fs.f_bfree) * fs.f_frsize)
        need(not require_space or free >= MIB, 'stack-volume-near-full')
        entries = list(self.logs.iterdir())
        need(len(entries) <= 128, 'stack-log-file-count-exceeded')
        for path in entries:
            info = path.lstat()
            need(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                 and info.st_nlink == 1 and info.st_size <= VOLUME_BYTES,
                 'stack-log-file-invalid')
            self.seen_log |= info.st_size > 0

    def cleanup(self, app_retired):
        # Never unmount logging storage while the app may still write to it.
        need(app_retired, 'app-retirement-unproven-volume-retained')
        self.commands.health = None
        if self.mount.exists() and self.mount.stat().st_dev != self.base.stat().st_dev:
            self.attached = True
        if self.attached:
            need(self.mount_device is None or self.mount.stat().st_dev == self.mount_device,
                 'volume-mount-device-changed-no-detach')
            self.commands.run(['/usr/bin/hdiutil', 'detach', str(self.mount)],
                time.monotonic() + 8, 'volume-detach.txt', cap=256 * 1024)
            need(not self.mount.exists() or self.mount.stat().st_dev == self.base.stat().st_dev,
                 'volume-detach-unconfirmed')
            self.attached = False
        self.image.unlink(missing_ok=True)
        if self.mount.exists():
            self.mount.rmdir()
        self.base.rmdir()
        self.cleanup_confirmed = True


def normalized_man(text):
    return re.sub('.\x08', '', text)


def check_capabilities(commands, deadline):
    docs = {}
    env = {**os.environ, 'LC_ALL': 'C', 'MANPAGER': 'cat', 'PAGER': 'cat', 'MANWIDTH': '120'}
    for tool in ('vmmap', 'heap', 'malloc_history'):
        need(Path('/usr/bin', tool).is_file(), 'native-tool-missing')
        help_text = commands.run(['/usr/bin/' + tool, '-h'], deadline, tool + '-help.txt',
                                  cap=512 * 1024, allowed=(0, 1, 2, 64), env=env, scan=False)
        man_text = commands.run(['/usr/bin/man', '-P', 'cat', tool], deadline,
                                 tool + '-man.txt', cap=MIB, env=env, scan=False)
        docs[tool] = normalized_man(help_text + '\n' + man_text)
    need(Path('/usr/sbin/lsof').is_file(), 'owned-log-fd-tool-missing')
    lsof_help = commands.run(['/usr/sbin/lsof', '-h'], deadline, 'lsof-help.txt',
        cap=512 * 1024, allowed=(0, 1), env=env, scan=False)
    lsof_man = commands.run(['/usr/bin/man', '-P', 'cat', 'lsof'], deadline, 'lsof-man.txt',
        cap=2 * MIB, env=env, scan=False)
    lsof_docs = normalized_man(lsof_help + lsof_man)
    need(all(flag in lsof_docs for flag in ['-F', '-p', '-a', '-n', '-P'])
         and re.search(r'(?i)(NUL|zero|\\0)', lsof_docs), 'lsof-bounded-field-options-undocumented')
    malloc = normalized_man(commands.run(['/usr/bin/man', '-P', 'cat', '3', 'malloc'],
        deadline, 'malloc-man.txt', cap=MIB, env=env, scan=False))
    need(re.search(r'(?<!\w)-w\b', docs['vmmap']), 'vmmap-full-width-option-undocumented')
    need('-addresses' in docs['heap'] and '-noContent' in docs['heap']
         and re.search(r'\ball\b', docs['heap']), 'heap-address-no-content-options-undocumented')
    need('-fullStacks' in docs['malloc_history'], 'history-full-stacks-option-undocumented')
    combined = malloc + docs['malloc_history']
    for key in ('MallocStackLogging', 'MallocStackLoggingNoCompact', 'MallocStackLoggingDirectory'):
        need(key in combined, 'full-stack-logging-option-undocumented')
    need(re.search(r'(?i)address', docs['malloc_history'])
         and re.search(r'(?i)(freed|free events|deallocat)', docs['malloc_history']),
         'malloc-history-address-history-undocumented')
    need(re.search(r'(?is)MallocStackLoggingNoCompact.{0,1500}(?:free|deallocat|all.{0,30}allocat)', combined),
         'noncompacting-allocation-free-history-undocumented')
    resident_documented = bool(re.search(r'(?<!\w)-resident\b', docs['vmmap']))
    return {'vmmapFlags': ['-w'] + (['-resident'] if resident_documented else []),
            'perRegionResidentOptionDocumented': resident_documented,
            'perRegionPageAttributionStatus': 'requires-native-output' if resident_documented else 'unsupported-inconclusive', 'heapFlags': ['-addresses', 'all', '-noContent'],
            'mallocHistoryFlags': ['-fullStacks'], 'ownedLogFDFlags': ['-nP', '-a', '-p', 'OWNED_PID', '-F0pftDn'], 'logging': 'full allocation and deallocation history with NoCompact',
            'installedHelpAndManChecked': True, 'runtimeCalibrationStillRequired': True,
            'literalFullValueMentionedInInstalledDocs': bool(re.search(
                r'(?is)MallocStackLogging.{0,800}\bfull\b', combined))}


def heap_allocations(text):
    """Recognize address+size rows only; never infer allocations from bare pointers."""
    found = {}
    patterns = [
        re.compile(r'^\s*(0x[0-9a-fA-F]+)\s*\([^\n)]*?\bsize\s*[=:]\s*([0-9,]+)\b'),
        re.compile(r'^\s*(0x[0-9a-fA-F]+)\s*\(\s*([0-9,]+)\s*bytes?\b'),
        re.compile(r'^\s*(0x[0-9a-fA-F]+)\s*:\s*([0-9,]+)\s+bytes?\b'),
        re.compile(r'^\s*(0x[0-9a-fA-F]+)\s*:[^\n]*?\(\s*([0-9,]+)\s+bytes?\)'),
    ]
    for line in text.splitlines():
        parsed = False
        for pattern in patterns:
            match = pattern.search(line)
            if match:
                address, size = int(match[1], 16), int(match[2].replace(',', ''))
                need(0 < address < 2**64 and 0 < size <= 3 * 1024**3, 'heap-allocation-row-invalid')
                need(address not in found or found[address] == size, 'heap-address-conflicting-size')
                found[address] = size
                parsed = True
                break
        need(parsed or not re.match(r'^\s*0x[0-9a-fA-F]+\b', line),
             'heap-allocation-row-format-unrecognized')
    need(found, 'heap-address-size-format-unrecognized')
    return found


def validate_vmmap(text, address=None):
    ranges = [(int(a, 16), int(b, 16)) for a, b in re.findall(
        r'\b([0-9a-fA-F]{8,16})-([0-9a-fA-F]{8,16})\b', text)]
    need(ranges and all(start < end for start, end in ranges), 'vmmap-address-regions-missing')
    if address is not None:
        need(any(start <= address < end for start, end in ranges), 'calibration-not-in-vmmap')
    return len(ranges)


def vmmap_page_columns(text):
    resident = bool(re.search(r'(?im)^.*(?:REGION|VSIZE).*\b(?:RSDNT|RESIDENT)\b', text))
    reusable = bool(re.search(r'(?im)^.*(?:REGION|VSIZE).*\b(?:REUSE|REUSABLE)\b', text))
    return {'residentColumnPresent': resident, 'reusableColumnPresent': reusable,
            'perRegionReusableAttribution': 'requires-analysis' if resident and reusable else 'unsupported-inconclusive',
            'processWideCountersUsedAsPerRegionEvidence': False}


def validate_history(text, address, freed=False, calibration=False):
    # -fullStacks must produce address-bound event blocks. A pointer mentioned
    # only in a stack, or FREE for some other allocation, cannot prove history.
    header = re.compile(r'(?im)^\s*(ALLOC|FREE)\s+(0x[0-9a-f]+)(?:-(0x[0-9a-f]+))?[^\n]*')
    headers = list(header.finditer(text))
    events = []
    matched_allocation = False
    any_matching_allocation = False
    matched_later_free = False
    for index, match in enumerate(headers):
        if int(match[2], 16) != address:
            continue
        kind = match[1].upper()
        size_match = re.search(r'\[size\s*=\s*([0-9,]+)\]', match[0])
        size = int(size_match[1].replace(',', '')) if size_match else None
        if kind == 'ALLOC':
            matched_allocation = False
            if calibration and size != 65537:
                continue
            need(size is not None and size > 0, 'history-allocation-size-missing')
        # Native FREE records may omit size or use zero. Exact pointer and an
        # earlier matching ALLOC establish the free relationship, not its size.
        end = headers[index + 1].start() if index + 1 < len(headers) else len(text)
        body = text[match.end():end]
        need(re.search(r'(?m)^\s*\d+\s+.+(?:0x[0-9a-fA-F]+|\+\s*\d+)', body),
             'history-stack-missing')
        need(re.search(r'PicShot|libsystem_malloc|CoreGraphics|AppKit|Foundation|ImageIO|libswift', body),
             'history-product-or-framework-stack-missing')
        if calibration:
            need('PicShot' in body, 'calibration-product-stack-missing')
        if kind == 'ALLOC':
            matched_allocation = True
            any_matching_allocation = True
        elif matched_allocation:
            matched_later_free = True
        events.append({'kind': kind, 'bytes': size})
    need(any_matching_allocation, 'history-allocation-event-missing')
    if freed:
        need(matched_later_free, 'history-ordered-free-event-missing')
    need(not BAD_TEXT.search(text), 'history-logging-incomplete')
    return events


def select_candidates(current, previous, seen, maximum=2):
    # New large allocations across every size are primary, then survivors.
    # There is deliberately no 4,177,920-byte equality filter.
    eligible = [(a, n) for a, n in current.items() if n >= 64 * 1024 and (a, n) not in seen]
    eligible.sort(key=lambda item: (item[0] in previous and previous[item[0]] == item[1], -item[1], item[0]))
    vanished = [(a, n) for a, n in previous.items() if a not in current and n >= 64 * 1024]
    vanished.sort(key=lambda item: (-item[1], item[0]))
    chosen = []
    if vanished:
        address, size = vanished[0]
        chosen.append({'address': hex(address), 'bytes': size, 'selection': 'disappeared-large-address'})
    for address, size in eligible:
        if not chosen or size != chosen[0]['bytes']:
            chosen.append({'address': hex(address), 'bytes': size,
                'selection': 'new-or-changed-large-address' if previous.get(address) != size else 'surviving-large-address'})
        if len(chosen) >= maximum:
            break
    if len(chosen) < maximum:
        for address, size in eligible:
            if all(int(item['address'], 16) != address for item in chosen):
                chosen.append({'address': hex(address), 'bytes': size,
                    'selection': 'additional-large-address'})
            if len(chosen) >= maximum:
                break
    return chosen


def stack_log_descriptors(text, pid, log_directory, device):
    """Parse only one exact PID's NUL-delimited lsof fields; discard other paths."""
    process_seen = False
    files = []
    current = None
    for token in text.split('\0'):
        token = token.lstrip('\n')
        if not token:
            continue
        field, value = token[0], token[1:]
        if field == 'p':
            need(not process_seen and value == str(pid), 'log-fd-process-mismatch')
            process_seen = True
        elif field == 'f':
            need(process_seen, 'log-fd-process-missing')
            if current is not None:
                files.append(current)
            current = {'f': value}
        elif field in ('t', 'D', 'n'):
            need(current is not None and field not in current, 'log-fd-fields-ambiguous')
            current[field] = value
        else:
            raise ProbeError('log-fd-output-format-unknown')
    if current is not None:
        files.append(current)
    need(process_seen, 'log-fd-process-missing')
    result = []
    for item in files:
        name = item.get('n', '')
        is_log = ('stack-logs' in name or 'stack_logging' in name
                  or name.startswith(str(log_directory) + '/'))
        if not is_log:
            continue
        need(set(item) == {'f', 't', 'D', 'n'}
             and (item['f'].isdigit() or item['f'] in ('mem', 'txt')) and item['t'] == 'REG',
             'stack-log-fd-incomplete')
        path = Path(name)
        need(path.is_absolute() and path.parent == log_directory
             and path.resolve() == path and path.is_file() and not path.is_symlink(),
             'active-stack-log-outside-fixed-volume')
        try:
            observed_device = int(item['D'], 0)
        except ValueError:
            raise ProbeError('stack-log-device-format-unknown') from None
        need(observed_device == device == path.stat().st_dev, 'active-stack-log-device-mismatch')
        result.append({'pid': pid, 'fileDescriptor': int(item['f']) if item['f'].isdigit() else item['f'], 'path': str(path),
                       'device': observed_device, 'regularFile': True})
    need(result and any(type(item['fileDescriptor']) is int for item in result),
         'active-stack-log-descriptor-unproven')
    need(len({item['fileDescriptor'] for item in result}) == len(result), 'stack-log-fd-duplicate')
    return result


class OwnedLauncher:
    def __init__(self, argv, environment, budget, bounded):
        self.process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, shell=False, start_new_session=True, env=clean_environment(environment))
        self.group = bounded.ProcessGroup(self.process)
        self.budget = budget
        self.data = bytearray()
        self.eof = False
        self.reaped = False
        self.code = None
        self.cleanup_confirmed = False
        os.set_blocking(self.process.stdout.fileno(), False)

    def drain(self):
        if self.eof:
            return
        try:
            chunk = os.read(self.process.stdout.fileno(), 64 * 1024)
        except BlockingIOError:
            return
        remaining = max(0, MIB + 1 - len(self.data))
        self.data.extend(chunk[:remaining])
        self.eof = not chunk
        need(len(self.data) <= MIB, 'launcher-output-cap')

    def exited(self):
        need(not self.reaped, 'launcher-already-reaped')
        return self.group.leader_exited()

    def finish(self, cancel):
        if self.reaped:
            return
        if cancel and not self.exited():
            # Swift forwards this to its retained NSRunningApplication, including
            # original TERM/KILL cleanup. Python never signals a discovered app PID.
            self.group.send(signal.SIGTERM)
        until = time.monotonic() + (7 if cancel else 1)
        while time.monotonic() < until:
            try:
                self.drain()
            except ProbeError:
                pass
            if self.group.leader_exited() and not self.group.alive():
                break
            time.sleep(0.02)
        if self.group.alive():
            self.group.send(signal.SIGKILL)
            until = time.monotonic() + 0.5
            while time.monotonic() < until and self.group.alive():
                time.sleep(0.01)
        self.cleanup_confirmed = not self.group.alive()
        self.group.close()
        self.process.stdout.close()
        try:
            self.code = self.process.wait(timeout=0.3)
            self.reaped = True
        except subprocess.TimeoutExpired:
            self.cleanup_confirmed = False
        if len(self.data) <= MIB:
            self.budget.retain('launcher-output.txt', self.data.decode('utf-8', errors='replace'))
        need(self.cleanup_confirmed and self.reaped, 'launcher-cleanup-incomplete')


class Observer:
    def __init__(self, args, commands, volume, identify):
        self.args, self.commands, self.volume, self.identify = args, commands, volume, identify
        self.token = str(uuid.uuid4())
        self.launcher = None
        self.launch = None
        self.native = None
        self.app_identity = None
        self.history_seconds = 0.0
        self.previous = {}
        self.seen = set()
        self.stages = []
        self.calibration = None
        self.started = None
        self.cancelled = False
        self.last_identity_check = 0.0
        self.log_sizes = {}
        self.report = {'schemaVersion': 1, 'status': 'preparing', 'diagnosticOnly': True,
            'memoryAcceptance': False, 'installerAcceptance': False, 'zeroLeakClaimed': False,
            'fullMemoryDump': False, 'singleOriginal227Replay': True, 'appLaunched': False, 'launcherCleanupConfirmed': True,
            'runToken': self.token, 'protocol': PROTOCOL,
            'limits': {'snapshotSets': 8, 'snapshotSetSeconds': 10,
                'calibrationHoldsSeconds': [15, 15], 'historyExtractionTotalSeconds': 30,
                'retainedTextBytes': TEXT_BYTES, 'perToolTextBytes': 8 * MIB,
                'stackLogVolumeBytes': VOLUME_BYTES, 'appCooperativeSeconds': 590,
                'originalLauncherSeconds': 600, 'appRSSBytes': 3 * 1024**3,
                'appPhysicalFootprintBytes': 512 * MIB},
            'scope': 'Instrumented original227 allocation attribution only; unchanged original output/resource validators remain required',
            'limitations': ['Native tools and full logging perturb timing and allocation behavior',
                'Two selected address histories per checkpoint cannot enumerate every allocation',
                'Allocations born and freed between snapshots can remain unattributed',
                'Successful evidence collection does not establish a leak verdict or memory acceptance']}

    def check_app(self, hash_check=False):
        need(self.launch is not None and self.native is not None, 'app-identity-unbound')
        current = self.identify(self.launch['appPID'])
        need(current == self.native, 'app-native-identity-changed')
        if hash_check:
            need(sha_file(self.args.executable) == self.args.digest, 'app-executable-hash-changed')
        return current

    def health(self):
        need(not self.cancelled, 'observer-cancelled')
        self.volume.health()
        if self.launcher:
            self.launcher.drain()
            need(not self.launcher.exited(), 'launcher-exited-during-probe')
        if self.native is not None:
            self.check_app()
            paths = list(self.volume.logs.iterdir())
            need(set(self.log_sizes).issubset({path.name for path in paths}), 'stack-log-disappeared')
            for path in paths:
                need(re.search(r'(^|[._-])' + str(self.native['pid']) + r'([._-]|$)', path.name),
                     'stack-log-not-owned-app')
                st = path.stat()
                previous = self.log_sizes.get(path.name)
                need(previous is None or (st.st_ino == previous[0] and st.st_size >= previous[1]),
                     'stack-log-shrunk-or-replaced')
                self.log_sizes[path.name] = (st.st_ino, st.st_size)
        if self.started is not None:
            need(time.monotonic() - self.started < 600, 'original-launcher-window-exhausted')

    def tool(self, tool, arguments, request, label, deadline, cap):
        self.check_app(hash_check=True)
        result = self.commands.run(['/usr/bin/' + tool] + arguments, deadline,
            f'{request["sequence"]:04d}-{label}.txt', cap=min(cap, 8 * MIB))
        self.check_app(hash_check=True)
        need(time.monotonic() < deadline, 'snapshot-deadline-exceeded')
        return result

    def history(self, address, request, deadline, label, freed=False, calibration=False):
        remaining = 30 - self.history_seconds
        need(remaining > 0.5, 'history-total-budget-exhausted')
        end = min(deadline, time.monotonic() + min(remaining, 4 if calibration else 2))
        start = time.monotonic()
        try:
            text = self.tool('malloc_history', ['-fullStacks', str(self.native['pid']), hex(address)],
                             request, label, end, MIB)
        finally:
            self.history_seconds += time.monotonic() - start
        need(self.history_seconds <= 30, 'history-total-budget-exceeded')
        events = validate_history(text, address, freed=freed, calibration=calibration)
        return {'matchingEventCount': len(events),
            'allocationCount': sum(item['kind'] == 'ALLOC' for item in events),
            'freeCount': sum(item['kind'] == 'FREE' for item in events),
            'firstEvents': events[:16], 'lastEvents': events[-16:] if len(events) > 16 else [],
            'completeEventAndStackTextRetained': True}

    def log_descriptors(self, request, deadline):
        self.check_app(hash_check=True)
        evidence = []
        def selected_only(text):
            evidence.extend(stack_log_descriptors(text, self.native['pid'], self.volume.logs,
                                                  self.volume.mount_device))
            return json.dumps({'ownedStackLogDescriptors': evidence}, sort_keys=True, indent=2) + '\n'
        self.commands.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(self.native['pid']), '-F0pftDn'],
            min(deadline, time.monotonic() + 2), f'{request["sequence"]:04d}-stack-log-fds.txt',
            cap=512 * 1024, retain_filter=selected_only)
        self.check_app(hash_check=True)
        return evidence

    def observe(self, request, deadline):
        sequence = request['sequence']
        pid = str(self.native['pid'])
        row = {'sequence': sequence, 'cycleOrdinal': request['cycleOrdinal'], 'phase': request['phase'],
            'kind': request['kind'], 'startedUptimeSeconds': time.monotonic(), 'status': 'running'}
        self.stages.append(row)
        row['ownedStackLogDescriptors'] = self.log_descriptors(request, deadline)
        if sequence == 1:
            self.calibration = request['calibration']
            address = int(self.calibration['address'], 16)
            vmmap = self.tool('vmmap', self.report['capabilities']['vmmapFlags'] + [pid], request, 'vmmap', min(deadline, time.monotonic() + 5), 3 * MIB)
            row['vmmapRegionCount'] = validate_vmmap(vmmap, address)
            row['perRegionPageColumns'] = vmmap_page_columns(vmmap)
            heap = self.tool('heap', ['-addresses', 'all', '-noContent', pid], request,
                             'heap', min(deadline, time.monotonic() + 5), 5 * MIB)
            allocations = heap_allocations(heap)
            need(allocations.get(address) == self.calibration['usableBytes'],
                 'calibration-live-heap-size-mismatch')
            row['historyEvents'] = self.history(address, request, deadline, 'calibration-history', calibration=True)
            self.health()
            need(self.volume.seen_log, 'full-stack-log-files-missing')
            row['liveMallocAddressAndUsableSizeConfirmed'] = True
        elif sequence == 2:
            need(request['calibration'] == self.calibration, 'calibration-address-changed')
            address = int(self.calibration['address'], 16)
            row['historyEvents'] = self.history(address, request, deadline, 'calibration-history',
                                                freed=True, calibration=True)
            self.health()
            row['sameAppFullAllocationAndFreeHistoryProven'] = True
            self.report['preflightPassed'] = True
        else:
            need(self.report.get('preflightPassed') is True, 'workload-before-full-history-preflight')
            vmmap = self.tool('vmmap', self.report['capabilities']['vmmapFlags'] + [pid], request, 'vmmap', min(deadline, time.monotonic() + 3), 3 * MIB)
            row['vmmapRegionCount'] = validate_vmmap(vmmap)
            row['perRegionPageColumns'] = vmmap_page_columns(vmmap)
            heap = self.tool('heap', ['-addresses', 'all', '-noContent', pid], request,
                             'heap', min(deadline, time.monotonic() + 3), 5 * MIB)
            allocations = heap_allocations(heap)
            selected = select_candidates(allocations, self.previous, self.seen)
            need(selected, 'no-attribution-history-candidates')
            row['heapLiveAllocationCount'] = len(allocations)
            row['heapLiveAllocationBytes'] = sum(allocations.values())
            row['historyCandidates'] = selected
            for index, candidate in enumerate(selected):
                address = int(candidate['address'], 16)
                candidate['events'] = self.history(address, request, deadline, f'history-{index + 1}',
                    freed=candidate.get('selection') == 'disappeared-large-address')
                self.seen.add((address, candidate['bytes']))
            self.previous = allocations
        self.health()
        row['status'] = 'observed'
        row['completedUptimeSeconds'] = time.monotonic()
        row['durationSeconds'] = row['completedUptimeSeconds'] - row['startedUptimeSeconds']
        need(row['completedUptimeSeconds'] < deadline, 'request-observation-late')

    def bind_launch(self):
        path = self.args.diagnostic_directory / 'launch.json'
        while not path.exists():
            self.health()
            time.sleep(0.01)
        launch = read_json(path)
        need(type(launch) is dict and type(launch.get('appPID')) is int, 'launch-receipt-invalid')
        native = self.identify(launch['appPID'])
        launcher_native = self.identify(self.launcher.process.pid)
        validate_launch(launch, self.token, self.launcher.process.pid, self.args.app,
                        self.args.executable, self.args.digest, native, launcher_native)
        need(sha_file(self.args.executable) == self.args.digest, 'launch-executable-hash-changed')
        need(self.identify(launch['appPID']) == native, 'launch-identity-raced')
        self.launch, self.native = launch, native
        self.report['ownedAppIdentity'] = native
        self.report['launchReceiptVerified'] = True
        self.report['appLaunched'] = True
        self.report['executableSHA256'] = self.args.digest

    def run(self):
        env = {key: value for key, value in clean_environment().items() if not key.startswith('PICSHOT_')}
        env.update({DIAG_DIR: str(self.args.diagnostic_directory), DIAG_TOKEN: self.token,
            'PICSHOT_LIVE_SCROLL_RESOURCE_MODE': 'measure',
            'PICSHOT_LIVE_SCROLL_RESOURCE_INPUT': str(self.args.resource_root / 'input'),
            'PICSHOT_LIVE_SCROLL_PNG_WRITER': 'foundation'})
        atomic_json(self.args.diagnostic_directory / 'configuration.json', {
            'schemaVersion': 1, 'protocol': PROTOCOL, 'runToken': self.token,
            'mallocEnvironment': self.volume.environment()})
        self.started = time.monotonic()
        self.launcher = OwnedLauncher(['/usr/bin/swift', str(self.args.launcher), str(self.args.app),
            str(self.args.resource_root / 'measure' / 'summary.json')], env, self.commands.budget,
            self.commands.bounded)
        self.report['appLaunched'] = None
        self.report['launcherCleanupConfirmed'] = False
        self.commands.health = self.health
        self.bind_launch()
        self.report['status'] = 'observing'
        for sequence in range(1, 11):
            path = self.args.diagnostic_directory / f'request-{sequence:04d}.json'
            while not path.exists():
                self.health()
                time.sleep(0.01)
            request = read_json(path)
            deadline = validate_request(request, sequence, self.token, self.launch,
                                        self.volume.environment(), time.monotonic())
            if self.app_identity is None:
                self.app_identity = request['identity']
            need(request['identity'] == self.app_identity, 'request-identity-changed')
            reply = self.args.diagnostic_directory / f'reply-{sequence:04d}.json'
            need(not reply.exists() and not reply.is_symlink(), 'reply-already-exists')
            try:
                self.observe(request, deadline)
                atomic_json(reply, reply_for(request, 'ok'))
            except Exception as error:
                code = str(error) if isinstance(error, ProbeError) else 'observer-internal-failure'
                code = code if re.fullmatch('[a-z0-9-]{1,128}', code) else 'observer-internal-failure'
                if time.monotonic() < request['replyDeadlineUptimeSeconds'] and not reply.exists():
                    atomic_json(reply, reply_for(request, 'failed', code))
                raise
        self.report['allEightSnapshotsObserved'] = True
        self.report['perRegionPageAttributionStatus'] = (
            'requires-analysis' if all(row.get('perRegionPageColumns', {}).get('reusableColumnPresent')
                and row.get('perRegionPageColumns', {}).get('residentColumnPresent')
                for row in self.stages if row['kind'] == 'checkpoint') else 'unsupported-inconclusive')
        self.report['attributionConclusion'] = 'inconclusive-pending-cross-snapshot-analysis'
        # All histories are resolved before reply10 permits final app cleanup/exit.
        self.commands.health = None
        while not self.launcher.exited():
            need(not self.cancelled, 'observer-cancelled')
            self.volume.health()
            self.launcher.drain()
            need(time.monotonic() - self.started < 600, 'original-launcher-window-exhausted')
            time.sleep(0.02)
        self.launcher.finish(cancel=False)
        need(self.launcher.code == 0, 'launcher-nonzero')
        self.report['status'] = 'evidence-collected'

    def app_retired(self):
        if self.native is None:
            # No launch receipt means absence cannot be inferred just from an
            # interpreter exit. A launch-failed receipt is required in cleanup.
            if self.launcher is None:
                return True
            lifecycle = self.args.resource_root / 'measure' / 'summary.json.launcher.json'
            if lifecycle.exists():
                data = read_json(lifecycle, private=False)
                diagnostic = data.get('allocationDiagnostic', {})
                return (data.get('status') == 'launch-failed' and data.get('processIdentifier') is None
                    and data.get('callbackReceived') is True
                    and data.get('selectedAppPath') == str(self.args.app)
                    and data.get('expectedExecutablePath') == str(self.args.executable)
                    and type(diagnostic) is dict and diagnostic.get('enabled') is True
                    and diagnostic.get('protocol') == PROTOCOL and diagnostic.get('runToken') == self.token)
            return False
        try:
            now = self.identify(self.native['pid'])
        except ProcessLookupError:
            return True
        return (now['birthSeconds'], now['birthMicroseconds']) != (
            self.native['birthSeconds'], self.native['birthMicroseconds'])

    def cleanup(self):
        errors = []
        self.commands.health = None
        if self.launcher is not None:
            try:
                self.launcher.finish(cancel=self.report['status'] != 'evidence-collected')
            except Exception as error:
                errors.append('launcher-cleanup-incomplete')
        retired = False
        try:
            retired = self.app_retired()
        except Exception:
            errors.append('app-retirement-observation-failed')
        self.report['appRetirementConfirmed'] = retired
        self.report['launcherCleanupConfirmed'] = self.launcher is None or self.launcher.cleanup_confirmed
        self.report['launcherReturnCode'] = self.launcher.code if self.launcher else None
        if retired and self.volume.receipt is not None:
            try:
                self.volume.health(require_space=False)
                self.report['stackLogManifest'] = [dict(name=path.name, bytes=path.stat().st_size,
                    sha256=sha_file(path)) for path in sorted(self.volume.logs.iterdir())]
                self.report['rawStackLogsRetention'] = 'Extracted while app alive; bounded raw journal removed with owned image after retirement'
            except Exception:
                errors.append('stack-log-final-integrity-incomplete')
        try:
            self.volume.cleanup(retired)
        except Exception:
            errors.append('fixed-volume-cleanup-incomplete')
        self.report['volumeCleanupConfirmed'] = self.volume.cleanup_confirmed
        self.report['stackLogPeakUsedBytes'] = self.volume.peak_used
        self.report['historyExtractionTotalSeconds'] = self.history_seconds
        self.report['stages'] = self.stages
        self.report['cleanupErrors'] = errors
        if errors:
            self.report['status'] = 'inconclusive'
            self.report['retainedOwnedVolumeDirectory'] = str(self.volume.base)
        return not errors


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['app', 'launcher', 'resource-root', 'diagnostic-directory', 'report']:
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--expected-executable-sha256')
    return parser.parse_args()


def main(args):
    need(sys.platform == 'darwin', 'macos-required-no-fallback')
    for name in ['app', 'launcher', 'resource_root', 'diagnostic_directory', 'report']:
        path = getattr(args, name)
        need(path.is_absolute() and path.resolve() == path, 'canonical-absolute-path-required')
    need(args.app.is_dir() and args.launcher.is_file() and not args.launcher.is_symlink(), 'launch-input-missing')
    need((args.resource_root / 'input').is_dir() and (args.resource_root / 'measure').is_dir(),
         'original-resource-directories-required')
    need(not args.diagnostic_directory.exists() and not args.report.exists(), 'fresh-evidence-required')
    args.executable = args.app / 'Contents' / 'MacOS' / 'PicShot'
    args.digest = sha_file(args.executable)
    need(args.expected_executable_sha256 is None or args.expected_executable_sha256 == args.digest,
         'pinned-executable-hash-mismatch')
    args.diagnostic_directory.mkdir(mode=0o700)
    text_dir = args.diagnostic_directory / 'text'
    text_dir.mkdir(mode=0o700)
    budget = TextBudget(text_dir)
    commands = NativeCommands(budget)
    volume = FixedLogVolume(commands)
    observer = Observer(args, commands, volume, DarwinIdentity())
    previous = {number: signal.signal(number, lambda *_: setattr(observer, 'cancelled', True))
                for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    try:
        readiness_deadline = time.monotonic() + 20
        observer.report['capabilities'] = check_capabilities(commands, readiness_deadline)
        observer.report['volumeCapacityProof'] = volume.prepare(readiness_deadline)
        need(time.monotonic() < readiness_deadline, 'external-readiness-timeout')
        observer.run()
    except Exception as error:
        observer.report['status'] = 'inconclusive'
        observer.report['failureCode'] = str(error) if isinstance(error, ProbeError) else type(error).__name__
    finally:
        observer.cleanup()
        observer.report['nativeCommands'] = commands.records
        metadata_bytes = sum(path.stat().st_size for path in args.diagnostic_directory.iterdir()
            if path.is_file() and not path.is_symlink())
        if metadata_bytes > MIB:
            observer.report['status'] = 'inconclusive'
            observer.report['failureCode'] = 'protocol-metadata-cap-exceeded'
        observer.report['retainedTextBytes'] = budget.retained
        observer.report['protocolMetadataBytes'] = metadata_bytes
        observer.report['finalReportReservedBytes'] = MIB
        observer.report['totalRetainedTextUpperBoundBytes'] = budget.retained + metadata_bytes + MIB
        observer.report['textFiles'] = budget.records
        observer.report['boundedRunnerSHA256'] = sha_file(Path(__file__).with_name('run-bounded-command.py'))
        atomic_json(args.report, observer.report)
        for number, handler in previous.items():
            signal.signal(number, handler)
    print(json.dumps({'status': observer.report['status'], 'report': str(args.report),
                      'memoryAcceptance': False}, sort_keys=True))
    return 0 if observer.report['status'] == 'evidence-collected' else 1


if __name__ == '__main__':
    try:
        sys.exit(main(parse_args()))
    except ProbeError as error:
        print(json.dumps({'status': 'inconclusive', 'failureCode': str(error), 'memoryAcceptance': False}))
        sys.exit(1)
