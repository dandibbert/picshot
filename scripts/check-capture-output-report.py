#!/usr/bin/env python3
"""Bind capture/output evidence to the actual app and require all component gates."""
import json
import pathlib
import plistlib
import struct
import sys


def validate(report_path, app, source):
    path, bundle = pathlib.Path(report_path), pathlib.Path(app)
    assert path.stat().st_size <= 1024 * 1024, "oversized report"
    report = json.loads(path.read_text())
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert report['status'] == 'passed' and report['schemaVersion'] == 1
    assert report['sourceCommit'] == source == info['PicShotSourceCommit']
    assert report['version'] == info['CFBundleShortVersionString']
    assert report['buildVersion'] == info['CFBundleVersion']
    assert pathlib.Path(report['bundlePath']).resolve() == bundle.resolve()
    for key in ('realDesktopCaptured', 'permissionRequested', 'generalPasteboardChanged', 'standardDefaultsChanged'):
        assert report[key] is False, key
    for key in ('captureRatios', 'outputDecoration', 'multipleWindows', 'originalCurrentPin'):
        assert report[key]['status'] == 'passed', key
    decoration_cases = report['outputDecoration']['cases']
    assert {case['name'] for case in decoration_cases} == {'light', 'dark', 'edge-light', 'edge-dark'}
    for case in decoration_cases:
        if case['frozenCaptureOverlay']:
            assert case['ratioDecorationSwitchVerified'] is True, case['name']
        assert case['ownedPaletteClosed'] is True, case['name']
    pin = report['originalCurrentPin']
    for key in ('separateAssets', 'sourcePixelsUnchanged', 'currentPixelsRestoredExactly', 'temporaryDirectoryRemoved'):
        assert pin[key] is True, key
    assert pin['controllerReleaseCount'] == 2 and pin['userPreferencesChanged'] is False
    for filename, size in [('pin-undecorated-original.png', (48, 32)), ('pin-decorated-current.png', (62, 46))]:
        data = (path.parent / filename).read_bytes()
        assert 24 < len(data) <= 1024 * 1024 and data.startswith(b'\x89PNG\r\n\x1a\n'), filename
        assert struct.unpack('>II', data[16:24]) == size, filename
    return report


if __name__ == '__main__':
    assert len(sys.argv) == 4, 'REPORT APP SOURCE'
    value = validate(*sys.argv[1:])
    print(json.dumps({'status': 'passed', 'sourceCommit': value['sourceCommit'], 'version': value['version'], 'buildVersion': value['buildVersion']}, indent=2))
