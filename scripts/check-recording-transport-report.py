#!/usr/bin/env python3
"""Check native transport evidence; all gates remain active under python -O.

Usage: check-recording-transport-report.py /path/to/recording-transport.json
This checks evidence consistency, not source/installer identity or physical
capture exclusion. The invoking installed-app workflow owns those boundaries.
"""
import json
import math
from pathlib import Path
import struct
import sys
import zlib


def need(condition, message):
    if not condition:
        raise ValueError(message)


def object_value(value, label):
    need(type(value) is dict, label + ' must be an object')
    return value


def count(value, key, expected):
    need(type(value.get(key)) is int and value[key] == expected, 'Invalid ' + key)


def number(value):
    try:
        return type(value) in (int, float) and math.isfinite(value)
    except OverflowError:
        return False


def rectangle(value):
    object_value(value, 'Rectangle')
    need(set(value) == {'x', 'y', 'width', 'height'} and all(number(x) for x in value.values()), 'Invalid rectangle')
    need(value['width'] > 0 and value['height'] > 0, 'Empty rectangle')
    return tuple(value[k] for k in ('x', 'y', 'width', 'height'))


def contains(outer, inner):
    x, y, w, h = outer
    a, b, c, d = inner
    return a >= x and b >= y and a + c <= x + w and b + d <= y + h


def overlap(a, b):
    return min(a[0] + a[2], b[0] + b[2]) > max(a[0], b[0]) and min(a[1] + a[3], b[1] + b[3]) > max(a[1], b[1])


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'Duplicate JSON key: ' + key)
        result[key] = value
    return result


def read_bytes(path, maximum):
    path = Path(path)
    need(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= maximum, 'Missing/oversized/symlink file: ' + str(path))
    return path.read_bytes()


def read_json(path):
    def reject(value):
        raise ValueError('Nonfinite JSON number: ' + value)
    return json.loads(read_bytes(path, 128 * 1024), object_pairs_hook=unique_object, parse_constant=reject)


def png(path):
    data = read_bytes(path, 2 * 1024 * 1024)
    need(data[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid PNG signature')
    offset, header, compressed, ended = 8, None, bytearray(), False
    while offset < len(data):
        need(offset + 12 <= len(data), 'Truncated PNG chunk')
        length = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        need(offset + 12 + length <= len(data), 'Truncated PNG payload')
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from('>I', data, offset + 8 + length)[0]
        need(zlib.crc32(kind + payload) & 0xffffffff == crc, 'PNG CRC mismatch')
        if header is None:
            need(kind == b'IHDR' and length == 13, 'Missing PNG IHDR')
            header = struct.unpack('>IIBBBBB', payload)
            need(header[:2] == (300, 40) and header[2] == 8 and header[3] in (2, 6) and header[4:] == (0, 0, 0),
                 'Expected 300x40, 8-bit, noninterlaced RGB/RGBA PNG')
        else:
            need(kind != b'IHDR', 'Duplicate PNG IHDR')
        if kind == b'IDAT': compressed.extend(payload)
        offset += 12 + length
        if kind == b'IEND':
            need(length == 0 and offset == len(data), 'Invalid PNG end/trailing bytes')
            ended = True
            break
    need(ended and compressed, 'Incomplete PNG')
    channels = 4 if header[3] == 6 else 3
    row = 1 + 300 * channels
    decoder = zlib.decompressobj()
    raster = decoder.decompress(compressed, row * 40 + 1)
    need(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail and len(raster) == row * 40,
         'Invalid or oversized PNG raster')
    need(all(raster[y * row] <= 4 for y in range(40)), 'Invalid PNG row filter')
    return raster


def ownership(value, probes):
    object_value(value, 'Ownership')
    need(value.get('status') == 'passed', 'Ownership did not pass')
    for key, expected in [('weakProbeCount', probes), ('retainedObjects', 0), ('deadlineMilliseconds', 3000)]:
        count(value, key, expected)
    elapsed = value.get('releaseMilliseconds')
    need(number(elapsed) and 0 <= elapsed <= 3000, 'Retirement missed its deadline')


def geometry(path, before):
    value = object_value(read_json(path), 'Raw geometry')
    need(value.get('status') == 'measured-before-validation' and value.get('coordinateSystem') == 'AppKit bottom-left', 'Missing raw geometry')
    need(rectangle(value.get('contentBounds')) == (0, 0, 300, 40), 'Incorrect content bounds')
    need(rectangle(value.get('windowFrame')) == before, 'State update moved the native strip')
    controls = value.get('controls')
    need(type(controls) is list and len(controls) == 6, 'Incomplete control geometry')
    expected = {'recording.transport.' + x for x in ('grip', 'elapsed', 'status', 'pauseResume', 'stopSave', 'expand')}
    seen, frames = set(), []
    for control in controls:
        object_value(control, 'Control')
        identifier = control.get('identifier')
        need(type(identifier) is str and identifier in expected and identifier not in seen, 'Missing/duplicate/unexpected native control')
        seen.add(identifier)
        need(control.get('hidden') is False, 'Native control hidden')
        frame = rectangle(control.get('frame'))
        need(contains((0, 0, 300, 40), frame), 'Native control clipped')
        need(not any(overlap(frame, old) for old in frames), 'Native controls overlap')
        if identifier.endswith(('pauseResume', 'stopSave', 'expand')):
            need(frame[2:] == (32, 32), 'Action hit target changed')
        if identifier.endswith('grip'): need(frame[2:] == (20, 32), 'Grip hit target changed')
        frames.append(frame)


def validate(report, directory):
    report = object_value(report, 'Report')
    need(report.get('status') == 'passed' and report.get('phase') == 'complete', 'Native fixture did not complete')
    for key, expected in [('interactionRoute', 'NSButton.performClick'), ('hitTestRoute', 'NSView.hitTest'),
                          ('dragRoute', 'local NSView mouseDown/mouseDragged/mouseUp'),
                          ('captureExclusion', 'sharingType.none asserted; physical ScreenCaptureKit exclusion not tested')]:
        need(report.get(key) == expected, 'Missing native route/boundary: ' + key)
    for key in ('recordingStarted', 'permissionRequested', 'globalInputPosted'):
        need(report.get(key) is False, 'Unexpected ' + key)
    for key, expected in [('nativeMonitorRegistrations', 0), ('productionTimers', 0), ('productionObservers', 0),
                          ('snapshotPixelsPerPoint', 1), ('contentWidthPoints', 300), ('contentHeightPoints', 40), ('retirementCycles', 8)]:
        count(report, key, expected)
    ownership(report.get('repeatedRetirement'), 64)
    appearances = report.get('appearances')
    need(type(appearances) is list and len(appearances) == 2, 'Missing light/dark evidence')
    seen_themes, rasters = set(), {}
    for appearance in appearances:
        object_value(appearance, 'Appearance')
        theme = appearance.get('appearance')
        need(type(theme) is str and theme in ('light', 'dark') and theme not in seen_themes, 'Duplicate/invalid appearance')
        seen_themes.add(theme)
        need(appearance.get('status') == 'passed', 'Appearance did not pass')
        for key in ('busyStopVerified', 'replacementActionsVerified', 'shortcutUpdatesVerified', 'expandHideRestoreVerified', 'retiredActionsVerified'):
            need(appearance.get(key) is True, 'Missing native action assertion: ' + key)
        for key, expected in [('initialPauseCalls', 2), ('initialStopCalls', 1), ('replacementStopCalls', 1), ('replacementExpandCalls', 1)]:
            count(appearance, key, expected)
        ownership(appearance.get('ownership'), 9)
        drag = object_value(appearance.get('drag'), 'Drag')
        need(drag.get('status') == 'passed' and drag.get('buttonDragDidNotMove') is True and drag.get('hideCancelledDrag') is True and
             drag.get('regionMutationAvailable') is False, 'Missing drag isolation/cancellation assertion')
        visible, before, moved, clamped = [rectangle(drag.get(key)) for key in ('visibleFrame', 'before', 'afterGrip', 'afterClamp')]
        need(all(contains(visible, r) and r[2:] == (300, 40) for r in (before, moved, clamped)), 'Drag escaped visible screen')
        x, y, w, h = visible
        expected_move = (min(max(before[0] + 37, x), x + w - 300), min(max(before[1] - 21, y), y + h - 40), 300, 40)
        need(moved == expected_move and moved != before and clamped == (x + w - 300, y, 300, 40), 'Grip displacement/clamp not witnessed')
        states = appearance.get('states')
        need(type(states) is list and len(states) == 4, 'Missing transport state')
        seen_states = set()
        for state in states:
            object_value(state, 'State')
            name = state.get('state')
            need(type(name) is str and name in ('recording', 'paused', 'saving', 'error') and name not in seen_states, 'Duplicate/invalid transport state')
            seen_states.add(name)
            stem = 'recording-transport-' + name + '-' + theme
            need(state.get('file') == stem + '.png' and state.get('geometryFile') == stem + '-geometry.json', 'Unexpected evidence filename')
            need(state.get('layoutStatus') == 'passed' and state.get('hitTestStatus') == 'passed', 'Native layout/hit test did not pass')
            need(state.get('pauseEnabled') is (name in ('recording', 'paused')) and state.get('stopEnabled') is (name != 'saving'), 'Native action enablement is wrong')
            geometry(Path(directory) / state['geometryFile'], before)
            rasters[(theme, name)] = png(Path(directory) / state['file'])
    for state in ('recording', 'paused', 'saving', 'error'):
        need(rasters[('light', state)] != rasters[('dark', state)], 'Identical light/dark native raster')
    placements = report.get('placement')
    need(type(placements) is list and len(placements) == 9, 'Incomplete edge/negative-origin placement matrix')
    expected = set()
    for x, y, w, h in [(0, 24, 1280, 776), (-1920, -480, 1920, 1056), (-600, 900, 180, 400)]:
        for anchor in [(x, y, w, h), (x, y, 40, 40), (x + w - 10, y + h - 10, 10, 10)]:
            expected.add(((x, y, w, h), anchor))
    for item in placements:
        object_value(item, 'Placement')
        screen, anchor, initial, clamped = [rectangle(item.get(k)) for k in ('visibleFrame', 'anchor', 'initial', 'clamped')]
        need((screen, anchor) in expected, 'Duplicate/invalid placement case')
        expected.remove((screen, anchor))
        need(all(contains(screen, r) and r[2:] == (min(300, screen[2]), 40) for r in (initial, clamped)), 'Placement escaped visible frame')
        width = min(300, screen[2])
        x = min(max(anchor[0] + anchor[2] / 2 - width / 2, screen[0]), screen[0] + screen[2] - width)
        below, above = anchor[1] - 48, anchor[1] + anchor[3] + 8
        y = above if below < screen[1] and above + 40 <= screen[1] + screen[3] else below
        y = min(max(y, screen[1]), screen[1] + screen[3] - 40)
        need(initial == (x, y, width, 40), 'Adjacent placement changed')
        need(clamped[:2] == (screen[0], screen[1] + screen[3] - 40), 'Placement edge clamp changed')
    return report


if __name__ == '__main__':
    try:
        need(len(sys.argv) == 2, 'Usage: check-recording-transport-report.py REPORT.json')
        path = Path(sys.argv[1])
        validate(read_json(path), path.parent)
        print('Recording transport native evidence contract passed (8 PNGs, 8 raw layouts, 2 appearances)')
    except (ValueError, OSError, KeyError, TypeError, zlib.error, struct.error) as error:
        print('Recording transport evidence rejected: ' + str(error), file=sys.stderr)
        sys.exit(1)
