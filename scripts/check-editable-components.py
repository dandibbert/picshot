#!/usr/bin/env python3
"""Validate bounded, source-bound native component diagnostics, not acceptance.

Only the standard library is used. Synthetic tests are checker contract tests,
never native execution evidence. Native full-RGBA certificates are bound to real
local raw/PNG bytes; this checker does not substitute a different gamma renderer.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import sys
import uuid
import zlib

PROTOCOL = 'editable-components-v1'
FIXTURE_SOURCE = 'c80e94de9cf712e118009700feacbd707356e0a3'
ROLES = ('original', 'base', 'current')
CONSUMERS = ('raw-draw', 'png-write', 'png-decode-draw', 'png-decode-owned-draw', 'editable-render-pin')
OWNED_DECODE_MODE = 'png-decode-owned-draw'
NORMALIZATION_METHOD = 'vImageBuffer_InitWithCGImage/kvImageNoAllocate'
NORMALIZATION_MEMORY = ('beforeDecodeMemory', 'afterDecodeMemory', 'afterConversionMemory',
                        'afterDecodedInputReleaseMemory')
NORMALIZATION_FIELDS = {'role', 'sourcePNGBytes', 'sourcePNGSHA256', 'sourceRawBytes', 'sourceRawSHA256',
    'inputMetadata', 'normalizedMetadata', 'conversionError', 'conversionFlags', *NORMALIZATION_MEMORY}
OWNED_DECODE_CYCLE_FIELDS = {'ownedNormalizationCount', 'decodedInputReferencesReleasedBeforeValidation',
                            'normalizationMethod', 'normalizedInputs'}
DIMENSIONS = {'original': (3840, 2160), 'base': (3840, 2160), 'current': (2414, 1574)}
EXPECTED_HASHES = {
    'original': 'c7819513b71c4ad1675665feece59747ff9a518db5766c5a8de973f65fdf19c6',
    'base': 'b41f79800dd04476e3381aa6fa9da0a2e4f61034729dce3551909a383be83fc9',
    'current': 'b8362e485bb0bfc04471d4a9de1eaf01be470fb66f419193fa41966cdcaaaff5',
}
MAX_REPORT = 2 * 1024 * 1024
MAX_PNG = 40 * 1024 * 1024
MAX_BUNDLE = 210 * 1024 * 1024
MAX_OUTPUT = 320 * 1024 * 1024
MEMORY = ('resident_size', 'phys_footprint', 'purgeable_volatile_resident',
          'purgeable_volatile_virtual', 'purgeable_volatile_pmap',
          'ledger_purgeable_volatile', 'ledger_purgeable_volatile_compressed', 'compressed')
LIFETIME_ROLES = (*ROLES, 'canonical', 'editor', 'canvas', 'content', 'window', 'pin', 'store')
IDENTITY_FIELDS = {'sourceCommit', 'executableSHA256', 'executableBytes', 'bundlePath',
                   'architecture', 'operatingSystem', 'processIdentifier'}
BASE_FIELDS = IDENTITY_FIELDS | {'protocol', 'mode', 'status', 'entryMemory', 'diagnosticOnly',
    'fullWorkEquivalent', 'memoryStabilityAssessed', 'productMemoryRemedyClaim',
    'coreFoundationWeakProbesUsed', 'nativeImageLifetimeScope', 'memoryPressureOrPurgeRequested', 'deadlineSeconds', 'fixtureSourceCommit', 'warmupCycles',
    'measuredCycles', 'scope', 'finalMemory', 'sampledMemory', 'elapsedSeconds', 'inputManifestSHA256'}
LOADED_FIELDS = {'inputPreparationProcessIdentifier', 'certificateSHA256', 'retainedInputBytes',
                 'afterInputLoadMemory', 'retainedInputBytesAfterCleanup', 'inputOpenDescriptorsAfterPreparation'}
CONSUMER_FIELDS = {'retainedValidationDestinationBytes', 'afterPreparationMemory', 'measuredDiskReads',
    'inputScope', 'diskReadScope', 'nativeImageIOProviderCallbacksObserved', 'cycles', 'afterWarmupMemory', 'afterMeasuredMemory',
    'retainedOutputFileCount', 'retainedOutputBytes', 'outputPixelsValidatedInThisProcess',
    'outputVerificationScope', 'afterDestinationCleanupMemory', 'destinationLifetime',
    'providerLifetime', 'retainedValidationDestinationBytesAfterCleanup', 'ownedOpenDescriptorsAfterCleanup'}
PIXEL_FIELDS = {'label', 'sha256', 'comparedBytes', 'exact', 'width', 'height', 'imageMetadata'}
DRAW_FIELDS = {'beforeDrawMemory', 'afterDrawMemory', 'afterCompareMemory', 'elapsedSeconds'}
CYCLE_FIELDS = {'ordinal', 'phase', 'index', 'beforeMemory', 'afterReleaseMemory', 'afterWorkMemory',
    'elapsedSeconds', 'ownershipAfterRelease', 'windowContentGraphsAfterRelease', 'providerLifetime',
    'ownedOpenDescriptorsAfter', 'ownedInputOpenDescriptorsAfter', 'temporaryDirectoryRemoved', 'activeExportControllersAfter',
    'projectionReservedBytesAfter', 'exportQueueOperationsAfter', 'measuredDiskReads',
    'validations', 'writtenOutputs', 'imageCreationCount', 'pngDecodeCount', 'pngWriteCount',
    'editableRestoreCount', 'pinApplyCount', 'freshRenderCount', 'afterCreationMemory', 'afterValidationMemory'}


def need(condition, message):
    if not condition:
        raise ValueError(message)


def keys(value, expected, label='object'):
    need(type(value) is dict, label + ' must be an object')
    missing, extra = set(expected) - set(value), set(value) - set(expected)
    need(not missing and not extra, f'{label} keys: missing={sorted(missing)}, extra={sorted(extra)}')


def integer(value, low=0, high=2**63 - 1):
    need(type(value) is int and low <= value <= high, 'invalid bounded integer')
    return value


def number(value, low=0, high=2**63 - 1):
    need(type(value) in (int, float) and math.isfinite(value) and low <= value <= high, 'invalid finite number')
    return value


def equal_int(value, expected, label):
    need(integer(value) == expected, label + ' differs')


def string(value):
    need(type(value) is str and 0 < len(value) <= 8192, 'invalid bounded string')
    return value


def sha(value):
    need(type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value) is not None, 'invalid SHA256')
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def strict_pairs(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'duplicate JSON key: ' + key)
        result[key] = value
    return result


def json_object(data):
    def invalid_constant(_):
        raise ValueError('nonfinite JSON')
    value = json.loads(data, object_pairs_hook=strict_pairs, parse_constant=invalid_constant)
    need(type(value) is dict, 'JSON root must be an object')
    return value


def read_bytes(path, maximum):
    """Reject links, nonregular/empty/oversize files, and identity changes at read."""
    path = Path(path).absolute()
    need(path.resolve(strict=True) == path, 'linked or noncanonical evidence path: ' + str(path))
    before = path.lstat()
    need(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum, 'file type/size outside bound: ' + str(path))
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(descriptor, 'rb') as handle:
        opened = os.fstat(handle.fileno())
        need((before.st_dev, before.st_ino, before.st_size) == (opened.st_dev, opened.st_ino, opened.st_size), 'file changed at open')
        data = handle.read(maximum + 1)
        after = os.fstat(handle.fileno())
    need(len(data) == before.st_size and
         (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) == (after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'file changed while reading')
    return data


def read_json(path, maximum=MAX_REPORT):
    data = read_bytes(path, maximum)
    return json_object(data), digest(data)


def bundle_identity(app, expected_source):
    need(type(expected_source) is str and re.fullmatch(r'[0-9a-f]{40}', expected_source) is not None, 'invalid expected source')
    app = Path(app).resolve(strict=True)
    info = plistlib.loads(read_bytes(app / 'Contents/Info.plist', 1024 * 1024))
    need(info.get('PicShotSourceCommit') == expected_source, 'installed source differs from expected source')
    need(info.get('CFBundleExecutable', 'PicShot') == 'PicShot', 'unexpected installed executable')
    executable = read_bytes(app / 'Contents/MacOS/PicShot', 268435456)
    need(len(executable) >= 32 and executable[:4] == bytes.fromhex('cffaedfe'), 'expected thin 64-bit Mach-O')
    architecture = {0x0100000c: 'arm64', 0x01000007: 'x86_64'}.get(struct.unpack_from('<I', executable, 4)[0])
    need(architecture is not None, 'unsupported installed architecture')
    return {'sourceCommit': expected_source, 'executableSHA256': digest(executable),
            'executableBytes': len(executable), 'bundlePath': str(app), 'architecture': architecture}


def identity(value, installed, operating_system=None):
    for field, expected in installed.items():
        need(type(value.get(field)) is type(expected) and value[field] == expected, 'installed identity mismatch: ' + field)
    integer(value.get('processIdentifier'), 1, 2**31 - 1)
    os_version = string(value.get('operatingSystem'))
    if operating_system is not None:
        need(os_version == operating_system, 'operating system differs between processes')


def counters(value):
    keys(value, MEMORY, 'memory counters')
    for name, count in value.items():
        integer(count, -2**63 if name.startswith('ledger_') else 0)
    need(value['resident_size'] > 0 and value['phys_footprint'] > 0, 'resident/footprint observation missing')


def observation(value):
    keys(value, {'uptimeSeconds', 'counters', 'backingAccounting'}, 'memory observation')
    uptime = number(value['uptimeSeconds'])
    counters(value['counters'])
    raw = value['backingAccounting']
    keys(raw, {'standard', 'purgeable'}, 'backing accounting')
    fields = {'flavor', 'kernelReturn', 'requestedNaturalCount', 'returnedNaturalCount',
              'observedAtUptimeSeconds', 'pageSizeBytes', 'regionCount', 'bytes', 'ledgerBytes'}
    for label, flavor in [('standard', 'TASK_VM_INFO'), ('purgeable', 'TASK_VM_INFO_PURGEABLE')]:
        item = raw[label]
        keys(item, fields, 'task_info')
        need(item['flavor'] == flavor, 'wrong task_info flavor')
        equal_int(item['kernelReturn'], 0, 'task_info return')
        requested = integer(item['requestedNaturalCount'], 1, 4096)
        integer(item['returnedNaturalCount'], 1, requested)
        number(item['observedAtUptimeSeconds'], 0, uptime + .1)
        integer(item['pageSizeBytes'], 1, 65536)
        integer(item['regionCount'], 0, 2**31 - 1)
        for container, minimum, maximum in [('bytes', 0, 2**64-1), ('ledgerBytes', -2**63, 2**63-1)]:
            need(type(item[container]) is dict and len(item[container]) <= 64, 'unbounded task_info fields')
            for name, count in item[container].items():
                string(name); integer(count, minimum, maximum)
    for name, count in value['counters'].items():
        source = raw['purgeable']['ledgerBytes'] if name.startswith('ledger_') else (
            raw['purgeable']['bytes'] if name.startswith('purgeable_') else raw['standard']['bytes'])
        need(name in source and source[name] == count, 'flattened counter differs from kernel accounting: ' + name)
    integer(raw['standard']['bytes'].get('resident_size_peak'), 1, 2**64-1)
    integer(raw['standard']['ledgerBytes'].get('ledger_phys_footprint_peak'), -2**63)
    need(raw['standard']['bytes']['resident_size_peak'] >= value['counters']['resident_size'], 'kernel RSS peak below current RSS')


def ordered_observations(values):
    previous = -1
    for value in values:
        observation(value)
        need(value['uptimeSeconds'] >= previous, 'memory checkpoint order moved backwards')
        previous = value['uptimeSeconds']


def statistics(value):
    keys(value, {'sampleCount', 'timerSampleCount', 'sampledPeakBytes', 'sampledMinimumBytes', 'lastBytes', 'missingFieldCounts'}, 'sampler statistics')
    count = integer(value['sampleCount'], 1, 1000000)
    integer(value['timerSampleCount'], 0, count)
    need(value['missingFieldCounts'] == {}, 'sampler observed missing fields')
    for field in ('sampledPeakBytes', 'sampledMinimumBytes', 'lastBytes'):
        counters(value[field])
    for name in MEMORY:
        need(value['sampledMinimumBytes'][name] <= value['lastBytes'][name] <= value['sampledPeakBytes'][name], 'invalid sampled counter range')


def samples(value, consumer):
    keys(value, {'scope', 'sampleIntervalSeconds', 'maximumPhaseAggregates', 'continuousSampleArraysRetained',
        'pairedTaskInfoCallsAreAtomic', 'missingFieldsBecomeZero', 'total', 'phases'}, 'sampler')
    string(value['scope'])
    need(number(value['sampleIntervalSeconds']) == .05, 'sampler interval changed')
    equal_int(value['maximumPhaseAggregates'], 128, 'sampler bound')
    for field in ('continuousSampleArraysRetained', 'pairedTaskInfoCallsAreAtomic', 'missingFieldsBecomeZero'):
        need(value[field] is False, 'misleading sampler semantics')
    statistics(value['total'])
    expected = {'entry', 'final-cleanup'}
    if consumer:
        expected |= {f'warmup-{i}' for i in range(1, 3)} | {f'measured-{i}' for i in range(1, 9)}
    keys(value['phases'], expected, 'sample phases')
    for phase in value['phases'].values():
        statistics(phase)
    if consumer:
        need(value['total']['timerSampleCount'] > 0, 'consumer transient sampler never ticked')
    for field in ('sampleCount', 'timerSampleCount'):
        need(value['total'][field] == sum(p[field] for p in value['phases'].values()), 'sample counts do not reconcile')
    for name in MEMORY:
        need(value['total']['sampledPeakBytes'][name] == max(p['sampledPeakBytes'][name] for p in value['phases'].values()), 'sample peak aggregation differs')
        need(value['total']['sampledMinimumBytes'][name] == min(p['sampledMinimumBytes'][name] for p in value['phases'].values()), 'sample minimum aggregation differs')
        need(value['total']['lastBytes'][name] == value['phases']['final-cleanup']['lastBytes'][name], 'final sampler value differs')


def png_metadata(data, width, height):
    """Bounded PNG structural/inflated-row validation, without color conversion."""
    need(0 < len(data) <= MAX_PNG and data[:8] == b'\x89PNG\r\n\x1a\n', 'invalid PNG signature/size')
    offset, header, chunks, compressed, seen = 8, None, 0, bytearray(), set()
    idat_closed = False
    while offset < len(data):
        chunks += 1
        need(chunks <= 4096 and offset + 12 <= len(data), 'truncated/unbounded PNG chunks')
        size = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset+4:offset+8]
        end = offset + 12 + size
        need(end <= len(data) and re.fullmatch(b'[A-Za-z]{4}', kind) is not None, 'invalid PNG chunk')
        payload = data[offset+8:end-4]
        need(zlib.crc32(kind + payload) & 0xffffffff == struct.unpack_from('>I', data, end-4)[0], 'PNG CRC mismatch')
        need(kind not in (b'acTL', b'fcTL', b'fdAT'), 'animated PNG is outside scope')
        if kind == b'IHDR':
            need(offset == 8 and size == 13 and header is None, 'invalid PNG IHDR')
            header = struct.unpack('>IIBBBBB', payload)
            need(header[:3] == (width, height, 8) and header[3] in (2, 6) and header[4:] == (0, 0, 0), 'PNG dimensions/depth/format differ')
        else:
            need(header is not None, 'PNG header missing')
        if kind == b'IDAT':
            need(not idat_closed, 'nonconsecutive PNG image data')
            compressed.extend(payload)
        elif b'IDAT' in seen:
            idat_closed = True
        if kind == b'IEND':
            need(size == 0 and end == len(data) and b'IDAT' in seen, 'invalid PNG end')
        elif kind == b'eXIf':
            need(kind not in seen and b'IDAT' not in seen, 'duplicate/misordered PNG EXIF')
            # ImageIO in build116 emits this bounded TIFF structure: one IFD0
            # ExifIFD pointer, then only sRGB and the two pixel dimensions. No
            # Orientation, thumbnail, trailing data, alternate IFD or pointer
            # layout is admitted. This validates metadata, not a new pixel
            # golden; independent complete RGBA comparisons remain required.
            expected_exif = (bytes.fromhex(
                '4d4d002a00000008000187690004000000010000001a000000000003'
                'a00100030000000100010000a002000400000001')
                + struct.pack('>I', width) + bytes.fromhex('a003000400000001')
                + struct.pack('>I', height) + bytes(4))
            need(payload == expected_exif, 'PNG EXIF differs from canonical sRGB/dimensions-only metadata')
        elif kind == b'sRGB':
            need(kind not in seen and size == 1 and payload[0] <= 3, 'invalid PNG sRGB metadata')
        elif kind == b'gAMA':
            need(kind not in seen and size == 4 and struct.unpack('>I', payload)[0] > 0, 'invalid PNG gamma metadata')
        elif kind == b'cHRM':
            need(kind not in seen and size == 32, 'invalid PNG chromaticity metadata')
        elif kind == b'iCCP':
            need(kind not in seen and b'\0' in payload, 'invalid PNG ICC profile')
            name, encoded = payload.split(b'\0', 1)
            need(0 < len(name) <= 79 and len(encoded) > 1 and encoded[0] == 0, 'invalid PNG ICC encoding')
            inflater = zlib.decompressobj()
            profile = inflater.decompress(encoded[1:], 4 * 1024 * 1024 + 1)
            need(128 <= len(profile) <= 4 * 1024 * 1024 and inflater.eof and not inflater.unused_data and not inflater.unconsumed_tail,
                 'unbounded/truncated PNG ICC profile')
            need(struct.unpack_from('>I', profile)[0] == len(profile) and profile[16:20] == b'RGB ' and profile[36:40] == b'acsp', 'invalid RGB ICC profile')
        elif kind not in (b'IHDR', b'IDAT', b'PLTE') and kind[0] < 97:
            raise ValueError('unsupported critical PNG chunk')
        if kind == b'PLTE':
            need(kind not in seen and b'IDAT' not in seen and 0 < size <= 768 and size % 3 == 0, 'invalid PNG palette hint')
        seen.add(kind)
        offset = end
    need(b'IEND' in seen and header is not None, 'PNG is incomplete')
    stride = width * (4 if header[3] == 6 else 3)
    expected = (stride + 1) * height
    need(0 < width <= 3840 and 0 < height <= 2160 and expected <= 40 * 1024 * 1024, 'PNG inflated bound exceeded')
    inflater = zlib.decompressobj()
    raw = inflater.decompress(compressed, expected + 1)
    need(len(raw) == expected and inflater.eof and not inflater.unused_data and not inflater.unconsumed_tail, 'PNG inflated length differs')
    need(all(raw[y * (stride + 1)] <= 4 for y in range(height)), 'invalid PNG row filter')
    return {'width': width, 'height': height, 'bitsPerComponent': 8, 'colorType': header[3]}


def canonical(value, role):
    width, height = DIMENSIONS[role]
    expected = {'width': width, 'height': height, 'bytesPerRow': width * 4, 'bitsPerComponent': 8,
        'bitsPerPixel': 32, 'alphaInfo': 1, 'bitmapInfo': 16385, 'colorSpaceName': 'kCGColorSpaceSRGB',
        'colorSpaceModel': 1, 'colorSpaceICC_SHA256': value.get('colorSpaceICC_SHA256'),
        'channelOrder': 'RGBA', 'includesAllAlphaBytes': True}
    keys(value, expected, 'canonical metadata')
    sha(value['colorSpaceICC_SHA256'])
    for field, wanted in expected.items():
        need(type(value[field]) is type(wanted) and value[field] == wanted, 'canonical format differs: ' + field)


def image_metadata(value, role, profile_hash, *, decoded=False, owned=False):
    fields = {'width', 'height', 'bytesPerRow', 'bitsPerComponent', 'bitsPerPixel', 'alphaInfo',
        'bitmapInfo', 'colorSpaceName', 'colorSpaceModel', 'colorSpaceICC_SHA256', 'renderingIntent', 'shouldInterpolate'}
    keys(value, fields, 'image metadata')
    width, height = DIMENSIONS[role]
    for field, expected in [('width', width), ('height', height), ('bitsPerComponent', 8), ('bitsPerPixel', 32), ('colorSpaceModel', 1)]:
        equal_int(value[field], expected, 'image ' + field)
    integer(value['bytesPerRow'], width * 4, width * 4 + 256)
    need(value['colorSpaceName'] == 'kCGColorSpaceSRGB' and sha(value['colorSpaceICC_SHA256']) == profile_hash, 'image color profile differs')
    alpha, bitmap = integer(value['alphaInfo']), integer(value['bitmapInfo'])
    # Native ImageIO preserves straight last-alpha PNG pixels (3); all actual
    # comparisons normalize into the independently bound premultiplied RGBA (1).
    need((alpha, bitmap) in ((1, 16385), (3, 3)), 'image alpha/channel layout differs')
    integer(value['renderingIntent'], 0, 4)
    need(type(value['shouldInterpolate']) is bool, 'image interpolation metadata missing')
    if not decoded:
        need((alpha, bitmap) == (1, 16385), 'rendered/owned image is not premultiplied RGBA')
    if owned:
        equal_int(value['bytesPerRow'], width * 4, 'owned row bytes')
        equal_int(value['renderingIntent'], 0, 'owned rendering intent')
        need(value['shouldInterpolate'] is (role != 'current'), 'owned interpolation differs')


def validate_document(data):
    doc = json_object(data)
    need(doc.get('format') == 'picshot.editable-annotations' and doc.get('coordinates') == 'image-pixels-bottom-left', 'document format differs')
    equal_int(doc.get('version'), 1, 'document version')
    for prefix in ('original', 'base'):
        equal_int(doc.get(prefix + 'PixelWidth'), 3840, 'document width')
        equal_int(doc.get(prefix + 'PixelHeight'), 2160, 'document height')
        uuid.UUID(string(doc.get(prefix + 'AssetID')))
    need(doc['originalAssetID'] != doc['baseAssetID'] and doc.get('baseProvenance') == 'derivedRaster', 'document base identity differs')
    need(doc.get('baseCropInOriginal') is None and doc.get('cropViewportInBase') == [[480, 240], [2400, 1560]], 'document viewport differs')
    need(type(doc.get('annotations')) is list and len(doc['annotations']) == 7, 'document layer count differs')
    decoration = doc.get('outputDecoration')
    need(type(decoration) is dict, 'document decoration missing')
    for field, expected in {'enabled': True, 'cornerRadius': 8, 'borderEnabled': True, 'borderWidth': 2,
        'shadowEnabled': True, 'shadowBlur': 2, 'shadowOffsetX': 3, 'shadowOffsetY': 4}.items():
        if type(expected) is bool:
            need(decoration.get(field) is expected, 'document decoration differs: ' + field)
        else:
            need(number(decoration.get(field)) == expected, 'document decoration differs: ' + field)


def validate_preparation(directory, manifest, report, installed):
    fields = IDENTITY_FIELDS | {'protocol', 'status', 'fixtureSourceCommit', 'referenceEvidence', 'assets',
        'documentFile', 'documentBytes', 'documentSHA256', 'totalBytes', 'originalAndBaseDistinct',
        'sourceWidth', 'sourceHeight', 'crop', 'outputWidth', 'outputHeight', 'layerCount'}
    keys(manifest, fields, 'input manifest')
    identity(manifest, installed, report['operatingSystem'])
    need(manifest['processIdentifier'] == report['processIdentifier'], 'preparation PID differs')
    need(manifest['protocol'] == PROTOCOL and manifest['status'] == 'prepared' and manifest['fixtureSourceCommit'] == FIXTURE_SOURCE, 'preparation identity differs')
    string(manifest['referenceEvidence'])
    for field, expected in [('sourceWidth', 3840), ('sourceHeight', 2160), ('outputWidth', 2414), ('outputHeight', 1574), ('layerCount', 7)]:
        equal_int(manifest[field], expected, 'manifest ' + field)
    need(manifest['crop'] == [480, 240, 2400, 1560] and all(type(x) is int for x in manifest['crop']), 'manifest crop differs')
    need(manifest['originalAndBaseDistinct'] is True, 'distinct original/base missing')
    entries = manifest['assets']
    need(type(entries) is list and len(entries) == 3 and [x.get('role') for x in entries if type(x) is dict] == list(ROLES), 'input roles/order differ')
    need(report['assets'] == entries, 'preparation report assets differ from manifest')
    total, profile = 0, None
    for entry, role in zip(entries, ROLES):
        keys(entry, {'role', 'width', 'height', 'pngFile', 'pngBytes', 'pngSHA256', 'rawFile', 'rawBytes', 'rawSHA256', 'sourceMetadata', 'canonical'}, 'input asset')
        width, height = DIMENSIONS[role]
        equal_int(entry['width'], width, 'asset width'); equal_int(entry['height'], height, 'asset height')
        need(entry['pngFile'] == role + '.png' and entry['rawFile'] == role + '.rgba', 'unsafe input name')
        canonical(entry['canonical'], role)
        profile = profile or entry['canonical']['colorSpaceICC_SHA256']
        need(entry['canonical']['colorSpaceICC_SHA256'] == profile, 'canonical ICC differs between roles')
        image_metadata(entry['sourceMetadata'], role, profile)
        raw = read_bytes(directory / entry['rawFile'], width * height * 4)
        equal_int(entry['rawBytes'], width * height * 4, 'raw byte count')
        need(len(raw) == entry['rawBytes'] and digest(raw) == sha(entry['rawSHA256']) == EXPECTED_HASHES[role], 'raw bytes/hash differ from pinned build113 reference: ' + role)
        png = read_bytes(directory / entry['pngFile'], MAX_PNG)
        equal_int(entry['pngBytes'], len(png), 'PNG bytes')
        need(digest(png) == sha(entry['pngSHA256']), 'input PNG file hash differs')
        png_metadata(png, width, height)
        total += len(raw) + len(png)
        need(total <= MAX_BUNDLE, 'input bundle exceeds bound')
    need(manifest['documentFile'] == 'document.annotations', 'unsafe document name')
    doc = read_bytes(directory / manifest['documentFile'], 1048576)
    equal_int(manifest['documentBytes'], len(doc), 'document bytes')
    need(digest(doc) == sha(manifest['documentSHA256']), 'document file hash differs')
    validate_document(doc)
    total += len(doc)
    equal_int(manifest['totalBytes'], total, 'bundle total')
    need(total <= MAX_BUNDLE, 'bundle total exceeds bound')
    return {a['role']: a for a in entries}


def pixel_record(value, label, role, assets, *, drawn=False, decoded=False, owned=False, extra=()):
    keys(value, PIXEL_FIELDS | (DRAW_FIELDS if drawn else set()) | set(extra), 'pixel validation')
    asset = assets[role]
    need(value['label'] == label and value['exact'] is True, 'pixel validation label/exact result differs')
    need(sha(value['sha256']) == EXPECTED_HASHES[role] == asset['rawSHA256'], 'full RGBA pixel hash differs')
    equal_int(value['comparedBytes'], DIMENSIONS[role][0] * DIMENSIONS[role][1] * 4, 'full RGBA comparison byte count')
    equal_int(value['width'], DIMENSIONS[role][0], 'comparison width')
    equal_int(value['height'], DIMENSIONS[role][1], 'comparison height')
    image_metadata(value['imageMetadata'], role, asset['canonical']['colorSpaceICC_SHA256'], decoded=decoded, owned=owned)
    if drawn:
        ordered_observations([value[name] for name in ('beforeDrawMemory', 'afterDrawMemory', 'afterCompareMemory')])
        number(value['elapsedSeconds'], 0, 300)


def validate_certificate(report, assets):
    records = report['validations']
    need(type(records) is list and len(records) == 4, 'certificate must contain exactly four validations')
    for index, label in enumerate((*ROLES, 'controller-replay')):
        role = label if label in ROLES else 'current'
        pixel_record(records[index], label, role, assets, decoded=index < 3)


def allocation(value, count, byte_count):
    keys(value, {'allocations', 'releaseCallbacks', 'deallocations', 'activeBytes', 'peakActiveBytes', 'callbackSizesMatch'}, 'allocation lifecycle')
    for field in ('allocations', 'releaseCallbacks', 'deallocations'):
        equal_int(value[field], count, field)
    equal_int(value['activeBytes'], 0, 'active allocation bytes')
    equal_int(value['peakActiveBytes'], byte_count if count else 0, 'peak owned allocation bytes')
    need(value['callbackSizesMatch'] is True, 'provider callback size differs')


def allocations(value, count):
    keys(value, ROLES, 'per-role allocations')
    for role in ROLES:
        allocation(value[role], count, DIMENSIONS[role][0] * DIMENSIONS[role][1] * 4)


def ownership(value, editable):
    keys(value, LIFETIME_ROLES, 'owned lifecycle')
    expected = {'original': 0, 'base': 0, 'current': 0, 'canonical': 0,
                'editor': 2 if editable else 0, 'canvas': 2 if editable else 0, 'content': 3 if editable else 0,
                'window': 3 if editable else 0, 'pin': 1 if editable else 0, 'store': 0}
    for role, item in value.items():
        keys(item, {'created', 'alive', 'peakConcurrent', 'peakKnownBytes'}, 'owned role')
        created = integer(item['created'], 0, 32)
        equal_int(created, expected[role], 'created ' + role)
        alive = integer(item['alive'], 0, created)
        peak = integer(item['peakConcurrent'], 0, created)
        need(alive <= peak and ((peak > 0) == (created > 0)), 'invalid owned lifetime peak')
        if role != 'window':
            equal_int(alive, 0, 'alive ' + role)
        count = integer(item['peakKnownBytes'], 0, MAX_BUNDLE)
        equal_int(count, 0, 'AppKit-only weak observer known bytes')


def validate_normalization(value, assets, certificate):
    equal_int(value['ownedNormalizationCount'], 3, 'owned normalization count')
    need(value['decodedInputReferencesReleasedBeforeValidation'] is True,
         'decoded input references were not released before validation')
    need(value['normalizationMethod'] == NORMALIZATION_METHOD, 'owned normalization method differs')
    records = value['normalizedInputs']
    need(type(records) is list and len(records) == 3, 'exactly three normalized inputs required')
    timeline = [value['beforeMemory']]
    for index, (record, role) in enumerate(zip(records, ROLES)):
        keys(record, NORMALIZATION_FIELDS, 'normalized input')
        need(record['role'] == role, 'normalized input roles/order differ')
        asset = assets[role]
        equal_int(record['sourcePNGBytes'], asset['pngBytes'], 'normalization source PNG bytes')
        equal_int(record['sourceRawBytes'], asset['rawBytes'], 'normalization source raw bytes')
        need(sha(record['sourcePNGSHA256']) == asset['pngSHA256'], 'normalization source PNG hash differs')
        need(sha(record['sourceRawSHA256']) == asset['rawSHA256'] == EXPECTED_HASHES[role],
             'normalization source raw hash differs')
        profile = asset['canonical']['colorSpaceICC_SHA256']
        image_metadata(record['inputMetadata'], role, profile, decoded=True)
        need(record['inputMetadata'] == certificate['validations'][index]['imageMetadata'],
             'normalization input metadata differs from certificate')
        image_metadata(record['normalizedMetadata'], role, profile, owned=True)
        need(record['normalizedMetadata'] == value['validations'][index]['imageMetadata'],
             'normalized metadata differs from validation image')
        equal_int(record['conversionError'], 0, 'normalization conversion error')
        equal_int(record['conversionFlags'], 512, 'normalization conversion flags')
        timeline += [record[name] for name in NORMALIZATION_MEMORY]
    timeline += [value['afterCreationMemory']]
    for record in value['validations']:
        timeline += [record[name] for name in ('beforeDrawMemory', 'afterDrawMemory', 'afterCompareMemory')]
    timeline += [value['afterValidationMemory']]
    ordered_observations(timeline)
    need(value['creationStartUptime'] <= records[0]['beforeDecodeMemory']['uptimeSeconds'],
         'owned normalization began before creation start')


def validate_cycle(value, mode, ordinal, assets, certificate):
    editable = mode == 'editable-render-pin'
    normalized = mode == OWNED_DECODE_MODE
    extra = {'documentChanged', 'persistenceCommitCount', 'afterRestoreMemory', 'afterPinOpenMemory', 'afterApplyMemory', 'afterFreshRenderMemory'} if editable else {'creationStartUptime', 'afterWritesMemory', 'writeSeconds'}
    if normalized:
        extra |= OWNED_DECODE_CYCLE_FIELDS
    keys(value, CYCLE_FIELDS | extra, 'consumer cycle')
    equal_int(value['ordinal'], ordinal, 'cycle ordinal')
    equal_int(value['index'], ordinal if ordinal <= 2 else ordinal - 2, 'cycle index')
    need(value['phase'] == ('warmup' if ordinal <= 2 else 'measured'), 'cycle phase differs')
    for name, expected in {'imageCreationCount': 6 if normalized else 3, 'pngDecodeCount': 3 if mode in ('png-decode-draw', OWNED_DECODE_MODE) else 0,
        'pngWriteCount': 3 if mode == 'png-write' else 0, 'editableRestoreCount': 2 if editable else 0,
        'pinApplyCount': 1 if editable else 0, 'freshRenderCount': 1 if editable else 0}.items():
        equal_int(value[name], expected, 'operation ' + name)
    labels = list(ROLES) + (['restored-render', 'pin-applied-current', 'fresh-render'] if editable else [])
    need(type(value['validations']) is list and len(value['validations']) == len(labels), 'draw count differs')
    for index, (record, label) in enumerate(zip(value['validations'], labels)):
        role = label if label in ROLES else 'current'
        decoded = mode == 'png-decode-draw'
        pixel_record(record, label, role, assets, drawn=True, decoded=decoded, owned=index < 3 and not decoded)
        if decoded:
            need(record['imageMetadata'] == certificate['validations'][index]['imageMetadata'], 'decoded metadata differs from certificate')
    names = ['beforeMemory', 'afterCreationMemory', 'afterValidationMemory']
    if editable:
        need(value['documentChanged'] is False, 'component edited document')
        equal_int(value['persistenceCommitCount'], 0, 'persistence commits')
        names += ['afterRestoreMemory', 'afterPinOpenMemory', 'afterApplyMemory', 'afterFreshRenderMemory']
    else:
        number(value['creationStartUptime'], value['beforeMemory']['uptimeSeconds'], value['afterCreationMemory']['uptimeSeconds'])
        number(value['writeSeconds'], 0, 300)
        names += ['afterWritesMemory']
    names += ['afterWorkMemory', 'afterReleaseMemory']
    ordered_observations([value[name] for name in names])
    number(value['elapsedSeconds'], 0, 300)
    for record in value['validations']:
        need(value['afterCreationMemory']['uptimeSeconds'] <= record['beforeDrawMemory']['uptimeSeconds'] <= record['afterCompareMemory']['uptimeSeconds'] <= value['afterWorkMemory']['uptimeSeconds'], 'draw checkpoint outside cycle')
    if normalized:
        validate_normalization(value, assets, certificate)
    ownership(value['ownershipAfterRelease'], editable)
    for field in ('windowContentGraphsAfterRelease', 'ownedOpenDescriptorsAfter', 'ownedInputOpenDescriptorsAfter', 'activeExportControllersAfter',
                  'projectionReservedBytesAfter', 'exportQueueOperationsAfter', 'measuredDiskReads'):
        equal_int(value[field], 0, field)
    need(value['temporaryDirectoryRemoved'] is True, 'cycle temporary directory retained')
    allocations(value['providerLifetime'], 0 if mode == 'png-decode-draw' else ordinal)
    writes = value['writtenOutputs']
    need(type(writes) is list and len(writes) == (3 if mode == 'png-write' else 0), 'written output count differs')
    for record, role in zip(writes, ROLES):
        keys(record, {'file', 'role', 'byteCount', 'sourceRawSHA256', 'width', 'height', 'outputPixelVerificationPending'}, 'written output')
        need(record['file'] == f'cycle-{ordinal}-{role}.png' and record['role'] == role, 'written output identity differs')
        need(record['sourceRawSHA256'] == EXPECTED_HASHES[role] and record['outputPixelVerificationPending'] is True, 'writer falsely verified output or changed source')
        integer(record['byteCount'], 1, MAX_PNG)
        equal_int(record['width'], DIMENSIONS[role][0], 'written width'); equal_int(record['height'], DIMENSIONS[role][1], 'written height')
    return sum(record['byteCount'] for record in writes)


def validate_consumer(report, assets, certificate):
    mode = report['mode']
    need(report['nativeImageIOProviderCallbacksObserved'] is False, 'native ImageIO provider callbacks are not observed')
    need(mode in CONSUMERS, 'invalid consumer')
    cycles = report['cycles']
    need(type(cycles) is list and len(cycles) == 10, 'requires exactly 2 warmup + 8 measured cycles')
    total = sum(validate_cycle(cycle, mode, index, assets, certificate) for index, cycle in enumerate(cycles, 1))
    need(total <= MAX_OUTPUT, 'writer output aggregate exceeds bound')
    equal_int(report['retainedOutputBytes'], total, 'retained output bytes')
    equal_int(report['retainedOutputFileCount'], 30 if mode == 'png-write' else 0, 'retained output count')
    need(report['outputPixelsValidatedInThisProcess'] is (mode != 'png-write'), 'output validation scope misstated')
    for field in ('inputScope', 'diskReadScope', 'outputVerificationScope'):
        string(report[field])
    for field in ('measuredDiskReads', 'retainedValidationDestinationBytesAfterCleanup', 'ownedOpenDescriptorsAfterCleanup'):
        equal_int(report[field], 0, field)
    equal_int(report['retainedValidationDestinationBytes'], sum(w*h*4 for w, h in DIMENSIONS.values()), 'retained comparison destination bytes')
    allocations(report['destinationLifetime'], 1)
    allocations(report['providerLifetime'], 0 if mode == 'png-decode-draw' else 10)
    timeline = [report['entryMemory'], report['afterInputLoadMemory'], report['afterPreparationMemory']]
    for index, cycle in enumerate(cycles, 1):
        timeline += [cycle['beforeMemory'], cycle['afterReleaseMemory']]
        if index == 2:
            timeline += [report['afterWarmupMemory']]
    timeline += [report['afterMeasuredMemory'], report['afterDestinationCleanupMemory'], report['finalMemory']]
    ordered_observations(timeline)


def validate_common(report, mode, installed, manifest_hash, manifest, certificate_hash=None):
    additional = {'assets'} if mode == 'prepare' else set(LOADED_FIELDS)
    if mode == 'certify':
        additional |= {'validations'}
    elif mode in CONSUMERS:
        additional |= CONSUMER_FIELDS
    elif mode == 'verify-writes':
        additional |= {'writerReportSHA256', 'writerProcessIdentifier', 'validations', 'verifiedOutputFiles', 'verifiedOutputBytes', 'memoryComparisonExcluded'}
    keys(report, BASE_FIELDS | additional, mode + ' report')
    identity(report, installed, manifest['operatingSystem'])
    need(report['protocol'] == PROTOCOL and report['mode'] == mode and report['fixtureSourceCommit'] == FIXTURE_SOURCE, 'component protocol/mode/fixture differs')
    expected_status = {'prepare': 'prepared', 'certify': 'certified', 'verify-writes': 'verified', 'png-write': 'observed-pending-output-validation'}.get(mode, 'observed')
    need(report['status'] == expected_status, 'component status incomplete: ' + mode)
    need(report['diagnosticOnly'] is True, 'diagnostic scope omitted')
    for field in ('fullWorkEquivalent', 'memoryStabilityAssessed', 'productMemoryRemedyClaim', 'memoryPressureOrPurgeRequested', 'coreFoundationWeakProbesUsed'):
        need(report[field] is False, 'unsupported scope/claim: ' + field)
    equal_int(report['warmupCycles'], 2, 'warmup bound'); equal_int(report['measuredCycles'], 8, 'measured bound')
    need(number(report['deadlineSeconds']) == 300 and 0 < number(report['elapsedSeconds']) < 300, 'native deadline omitted/exceeded')
    need(sha(report['inputManifestSHA256']) == manifest_hash, 'input manifest hash differs')
    string(report['scope']); string(report['nativeImageLifetimeScope'])
    need(report['finalMemory']['uptimeSeconds'] - report['entryMemory']['uptimeSeconds'] <= report['elapsedSeconds'] + .1, 'native observations exceed elapsed interval')
    ordered_observations([report['entryMemory'], report['finalMemory']])
    samples(report['sampledMemory'], mode in CONSUMERS)
    if mode != 'prepare':
        equal_int(report['inputPreparationProcessIdentifier'], manifest['processIdentifier'], 'input preparation PID')
        need(report['processIdentifier'] != manifest['processIdentifier'], 'process reused preparation PID')
        need(report['certificateSHA256'] == certificate_hash, 'certificate hash differs')
        equal_int(report['retainedInputBytes'], manifest['totalBytes'], 'retained input bytes')
        equal_int(report['retainedInputBytesAfterCleanup'], 0, 'retained input bytes after cleanup')
        equal_int(report['inputOpenDescriptorsAfterPreparation'], 0, 'input descriptors after preparation')
        ordered_observations([report['entryMemory'], report['afterInputLoadMemory'], report['finalMemory']])


def validate_launch(launcher, report, installed):
    keys(launcher, {'schemaVersion', 'status', 'launcherExitCode', 'selectedAppPath', 'createsNewApplicationInstance',
        'timeoutSeconds', 'elapsedSeconds', 'callbackReceived', 'ownedExitConfirmed', 'processStartMemoryCaptured',
        'scope', 'processIdentifier', 'launchedAppPath', 'launchBeganUptimeSeconds', 'finishUptimeSeconds'}, 'owned launcher')
    equal_int(launcher['schemaVersion'], 1, 'launcher schema')
    equal_int(launcher['launcherExitCode'], 0, 'launcher exit')
    equal_int(launcher['processIdentifier'], report['processIdentifier'], 'launcher/native PID')
    need(launcher['status'] == 'exited' and launcher['callbackReceived'] is True and launcher['ownedExitConfirmed'] is True
         and launcher['createsNewApplicationInstance'] is True, 'fresh owned process exit unverified')
    need(launcher['processStartMemoryCaptured'] is False, 'launcher falsely claims process-start memory')
    need(launcher['selectedAppPath'] == launcher['launchedAppPath'] == installed['bundlePath'], 'launcher installed path differs')
    need(number(launcher['timeoutSeconds']) == 600 and 0 < number(launcher['elapsedSeconds']) < 600, 'outer deadline omitted/exceeded')
    need(launcher['elapsedSeconds'] + .1 >= report['elapsedSeconds'], 'launcher interval shorter than native work')
    string(launcher['scope'])
    began = number(launcher['launchBeganUptimeSeconds'])
    finished = number(launcher['finishUptimeSeconds'], began, began + 600)
    need(began <= report['entryMemory']['uptimeSeconds'] <= report['finalMemory']['uptimeSeconds'] <= finished,
         'native checkpoints fall outside owned launch interval')


def validate_group_observation(observation, duration):
    keys(observation, {'backend', 'timeout_seconds', 'count', 'failures', 'total_seconds',
        'max_seconds', 'atomic_snapshot'}, 'owned process-group observation')
    need(observation['backend'] == 'darwin-ps-pgrp', 'native process-group backend differs')
    need(number(observation['timeout_seconds']) == .5, 'process-group subprocess timeout differs')
    count = integer(observation['count'], 1, 1_000_000)
    equal_int(observation['failures'], 0, 'process-group observation failures')
    need(observation['atomic_snapshot'] is False, 'process-group snapshot cannot claim atomicity')
    # The wrapper duration is rounded to milliseconds. Observation wall time
    # includes bounded ps setup/parsing and scheduling, so it is not the .5s
    # subprocess timeout itself. Preserve both values without inventing a
    # tighter wall-clock claim or accepting unreported probe failures.
    total = number(observation['total_seconds'], 0, duration + .001)
    maximum = number(observation['max_seconds'], 0, total)
    need(maximum > 0 and total <= count * maximum + 1e-9,
         'process-group observation timing/counts disagree')


def validate_command(command, directory, installed):
    keys(command, {'schema_version', 'status', 'command', 'started_at', 'timeout_seconds',
        'grace_seconds', 'max_log_bytes', 'pid', 'child_returncode', 'exit_code', 'cancel_signal',
        'sigterm_sent', 'sigkill_sent', 'descendant_cleanup', 'output_bytes', 'log_bytes',
        'log_truncated', 'termination_reason', 'duration_seconds', 'group_observation'}, 'bounded launcher command')
    equal_int(command['schema_version'], 1, 'command schema')
    need(command['status'] == command['termination_reason'] == 'exited', 'bounded launcher did not exit normally')
    equal_int(command['exit_code'], 0, 'wrapper exit'); equal_int(command['child_returncode'], 0, 'launcher child exit')
    need(command['cancel_signal'] is None, 'launcher command cancelled')
    for field in ('sigterm_sent', 'sigkill_sent', 'descendant_cleanup'):
        need(command[field] is False, 'launcher command required process cleanup')
    need(number(command['timeout_seconds']) == 620 and number(command['grace_seconds']) == 5, 'wrapper bounds differ')
    equal_int(command['max_log_bytes'], MAX_REPORT, 'wrapper log bound')
    integer(command['pid'], 1, 2**31 - 1)
    output_bytes = integer(command['output_bytes'])
    log_bytes = integer(command['log_bytes'], 0, MAX_REPORT)
    need(log_bytes == min(output_bytes, MAX_REPORT) and command['log_truncated'] is (output_bytes > log_bytes), 'wrapper log accounting differs')
    duration = number(command['duration_seconds'], 0, 620)
    need(duration > 0, 'wrapper duration missing')
    validate_group_observation(command['group_observation'], duration)
    need(command['command'] == ['swift', 'scripts/launch-editable-component.swift', installed['bundlePath'], str(directory / 'launch.json')], 'wrapper command target differs')
    start = datetime.datetime.fromisoformat(string(command['started_at']))
    need(start.tzinfo is not None and start.utcoffset() == datetime.timedelta(0), 'wrapper start must be UTC')
    return start.timestamp(), duration


def load_process(directory, installed):
    report, report_hash = read_json(directory / 'component.json')
    envelope, envelope_hash = read_json(directory / 'launch.json')
    need(envelope == report, 'launch report differs from component report')
    launcher, launcher_hash = read_json(directory / 'launch.json.launcher.json')
    validate_launch(launcher, report, installed)
    command, command_hash = read_json(directory / 'command.json')
    start, duration = validate_command(command, directory, installed)
    need(duration + .1 >= launcher['elapsedSeconds'], 'wrapper interval shorter than launcher')
    return report, {'componentSHA256': report_hash, 'launchSHA256': envelope_hash, 'launcherSHA256': launcher_hash,
                    'commandSHA256': command_hash, 'commandStartedAtEpochSeconds': start, 'commandDurationSeconds': duration,
                    'launchBeganUptimeSeconds': launcher['launchBeganUptimeSeconds'], 'finishUptimeSeconds': launcher['finishUptimeSeconds']}


def validate_written_outputs(writer_directory, writer, writer_hash, verifier, assets, certificate):
    need(verifier['memoryComparisonExcluded'] is True, 'output verifier included in memory comparison')
    need(sha(verifier['writerReportSHA256']) == writer_hash, 'post-exit verifier bound to different writer report')
    equal_int(verifier['writerProcessIdentifier'], writer['processIdentifier'], 'verified writer PID')
    need(verifier['processIdentifier'] != writer['processIdentifier'], 'output verifier is not a fresh process')
    equal_int(verifier['verifiedOutputFiles'], 30, 'verified output count')
    records = verifier['validations']
    need(type(records) is list and len(records) == 30, 'all 30 post-exit output validations required')
    output = writer_directory / 'outputs'
    expected_names = {f'cycle-{i}-{role}.png' for i in range(1, 11) for role in ROLES}
    need(output.resolve(strict=True) == output.absolute() and {p.name for p in output.iterdir()} == expected_names, 'output directory has missing/extra/linked evidence')
    total = 0
    for index, checked in enumerate(records):
        ordinal, role_index = divmod(index, 3)
        ordinal += 1
        role = ROLES[role_index]
        filename = f'cycle-{ordinal}-{role}.png'
        written = writer['cycles'][ordinal-1]['writtenOutputs'][role_index]
        pixel_record(checked, filename, role, assets, decoded=True,
                     extra={'fileSHA256', 'byteCount', 'sourceRawSHA256', 'ordinal', 'role'})
        equal_int(checked['ordinal'], ordinal, 'verified ordinal')
        need(checked['role'] == role and checked['sourceRawSHA256'] == EXPECTED_HASHES[role], 'verified output role/source differs')
        need(checked['imageMetadata'] == certificate['validations'][role_index]['imageMetadata'], 'verified output metadata differs from certification')
        data = read_bytes(output / filename, MAX_PNG)
        equal_int(written['byteCount'], len(data), 'writer actual output bytes')
        equal_int(checked['byteCount'], len(data), 'verifier actual output bytes')
        need(digest(data) == sha(checked['fileSHA256']), 'actual PNG bytes differ from post-exit verified file: ' + filename)
        png_metadata(data, *DIMENSIONS[role])
        total += len(data)
        need(total <= MAX_OUTPUT, 'actual writer output aggregate exceeds bound')
    equal_int(writer['retainedOutputBytes'], total, 'actual retained output bytes')
    equal_int(verifier['verifiedOutputBytes'], total, 'actual verified output bytes')


def delta(before, after):
    return {name: after['counters'][name] - before['counters'][name] for name in MEMORY}


def metrics(report):
    result = {'entryBytes': report['entryMemory']['counters'], 'finalBytes': report['finalMemory']['counters'],
        'entryToFinalDeltaBytes': delta(report['entryMemory'], report['finalMemory']),
        'sampledPeakBytes': report['sampledMemory']['total']['sampledPeakBytes'],
        'entryToSampledPeakDeltaBytes': {name: report['sampledMemory']['total']['sampledPeakBytes'][name] -
            report['entryMemory']['counters'][name] for name in MEMORY},
        'sampledMinimumBytes': report['sampledMemory']['total']['sampledMinimumBytes'],
        'kernelReportedPeakBytesAtCleanup': {
            'resident_size_peak': report['finalMemory']['backingAccounting']['standard']['bytes']['resident_size_peak'],
            'ledger_phys_footprint_peak': report['finalMemory']['backingAccounting']['standard']['ledgerBytes']['ledger_phys_footprint_peak']},
        'entryToKernelReportedPeakDeltaBytes': {
            'resident_size': report['finalMemory']['backingAccounting']['standard']['bytes']['resident_size_peak'] - report['entryMemory']['counters']['resident_size'],
            'phys_footprint': report['finalMemory']['backingAccounting']['standard']['ledgerBytes']['ledger_phys_footprint_peak'] - report['entryMemory']['counters']['phys_footprint']},
        'elapsedSeconds': report['elapsedSeconds']}
    if report['mode'] in CONSUMERS:
        cycles = report['cycles']
        result.update({
            'entryToInputLoadDeltaBytes': delta(report['entryMemory'], report['afterInputLoadMemory']),
            'entryToPreparationDeltaBytes': delta(report['entryMemory'], report['afterPreparationMemory']),
            'preparationToWarmupDeltaBytes': delta(report['afterPreparationMemory'], report['afterWarmupMemory']),
            'entryToWarmupDeltaBytes': delta(report['entryMemory'], report['afterWarmupMemory']),
            'warmupToMeasuredDeltaBytes': delta(report['afterWarmupMemory'], report['afterMeasuredMemory']),
            'warmupToFinalDeltaBytes': delta(report['afterWarmupMemory'], report['finalMemory']),
            'measuredToDestinationCleanupDeltaBytes': delta(report['afterMeasuredMemory'], report['afterDestinationCleanupMemory']),
            'measuredToFinalDeltaBytes': delta(report['afterMeasuredMemory'], report['finalMemory']),
            'lateMeasuredIncrements': [
                {'fromMeasuredIndex': a['index'], 'toMeasuredIndex': b['index'],
                 'deltaBytes': delta(a['afterReleaseMemory'], b['afterReleaseMemory'])}
                for a, b in zip(cycles[2:], cycles[3:])],
            'measuredReleaseIncrements': [
                {'from': 'afterWarmupMemory' if index == 0 else f'measured-{index}-afterReleaseMemory',
                 'toMeasuredIndex': cycle['index'],
                 'deltaBytes': delta(report['afterWarmupMemory'] if index == 0 else cycles[index+1]['afterReleaseMemory'],
                                     cycle['afterReleaseMemory'])}
                for index, cycle in enumerate(cycles[2:])],
            'cycleReleaseDeltaBytes': [delta(c['beforeMemory'], c['afterReleaseMemory']) for c in cycles],
            'warmupEndpoints': [c['afterReleaseMemory']['counters'] for c in cycles[:2]],
            'measuredEndpoints': [c['afterReleaseMemory']['counters'] for c in cycles[2:]],
            'retainedInputBytes': report['retainedInputBytes'],
            'retainedValidationDestinationBytes': report['retainedValidationDestinationBytes'],
            'retainedOutputFileCount': report['retainedOutputFileCount'], 'retainedOutputBytes': report['retainedOutputBytes'],
            'operationCountsPerCycle': {name: cycles[0][name] for name in ('imageCreationCount', 'pngDecodeCount', 'pngWriteCount', 'editableRestoreCount', 'pinApplyCount', 'freshRenderCount')},
            'checkpointNetDeltasByCycle': []})
        result['finalThreeLateMeasuredIncrements'] = result['lateMeasuredIncrements'][-3:]
        if report['mode'] == OWNED_DECODE_MODE:
            result['normalizationMethod'] = NORMALIZATION_METHOD
            result['operationCountsPerCycle']['ownedNormalizationCount'] = cycles[0]['ownedNormalizationCount']
            result['normalizationStagesByCycle'] = []
        for cycle in cycles:
            stages = ['beforeMemory', 'afterCreationMemory', 'afterValidationMemory']
            stages += (['afterRestoreMemory', 'afterPinOpenMemory', 'afterApplyMemory', 'afterFreshRenderMemory']
                       if report['mode'] == 'editable-render-pin' else ['afterWritesMemory'])
            stages += ['afterWorkMemory', 'afterReleaseMemory']
            checkpoints = [cycle[name] for name in stages]
            checkpoints += [r[name] for r in cycle['validations']
                            for name in ('beforeDrawMemory', 'afterDrawMemory', 'afterCompareMemory')]
            if report['mode'] == OWNED_DECODE_MODE:
                checkpoints += [r[name] for r in cycle['normalizedInputs'] for name in NORMALIZATION_MEMORY]
                result['normalizationStagesByCycle'].append({'ordinal': cycle['ordinal'],
                    'creationElapsedSeconds': cycle['afterCreationMemory']['uptimeSeconds'] - cycle['creationStartUptime'],
                    'validationElapsedSeconds': cycle['afterValidationMemory']['uptimeSeconds'] - cycle['afterCreationMemory']['uptimeSeconds'],
                    'cycleElapsedSeconds': cycle['elapsedSeconds'],
                    'inputs': [{'role': record['role'],
                        'checkpoints': [{'stage': name, 'uptimeSeconds': record[name]['uptimeSeconds'],
                                         'bytes': record[name]['counters']} for name in NORMALIZATION_MEMORY],
                        'boundaries': [{'from': a, 'to': b, 'deltaBytes': delta(record[a], record[b]),
                            'elapsedSeconds': record[b]['uptimeSeconds'] - record[a]['uptimeSeconds']}
                            for a, b in zip(NORMALIZATION_MEMORY, NORMALIZATION_MEMORY[1:])]}
                        for record in cycle['normalizedInputs']]})
            checkpoint_peak = {name: max(point['counters'][name] for point in checkpoints) for name in MEMORY}
            result['checkpointNetDeltasByCycle'].append({'ordinal': cycle['ordinal'],
                'sampledPeakBytes': report['sampledMemory']['phases'][f"{cycle['phase']}-{cycle['index']}"]['sampledPeakBytes'],
                'checkpointPeakBytes': checkpoint_peak,
                'kernelReportedPeakBytesAfterRelease': {
                    'resident_size_peak': cycle['afterReleaseMemory']['backingAccounting']['standard']['bytes']['resident_size_peak'],
                    'ledger_phys_footprint_peak': cycle['afterReleaseMemory']['backingAccounting']['standard']['ledgerBytes']['ledger_phys_footprint_peak']},
                'cycleEntryToCheckpointPeakDeltaBytes': {name: checkpoint_peak[name] - cycle['beforeMemory']['counters'][name] for name in MEMORY},
                'boundaries': [{'from': a, 'to': b, 'deltaBytes': delta(cycle[a], cycle[b])} for a, b in zip(stages, stages[1:])],
                'drawBoundaries': [{'label': r['label'], 'beforeToDrawDeltaBytes': delta(r['beforeDrawMemory'], r['afterDrawMemory']),
                    'drawToCompareDeltaBytes': delta(r['afterDrawMemory'], r['afterCompareMemory'])} for r in cycle['validations']]})
    return result


def check(app, expected_source, root, stage='complete'):
    need(stage in ('certify', 'complete'), 'unknown checker stage')
    root = Path(root).absolute()
    need(root.resolve(strict=True) == root and root.is_dir(), 'invalid evidence root')
    installed = bundle_identity(app, expected_source)
    manifest, manifest_hash = read_json(root / 'prepare/inputs.json', 262144)
    prepared, prepared_hashes = load_process(root / 'prepare', installed)
    validate_common(prepared, 'prepare', installed, manifest_hash, manifest)
    assets = validate_preparation(root / 'prepare', manifest, prepared, installed)
    cert, cert_hashes = load_process(root / 'certify', installed)
    validate_common(cert, 'certify', installed, manifest_hash, manifest)
    validate_certificate(cert, assets)
    reports = {'prepare': prepared, 'certify': cert}
    hashes = {'prepare': prepared_hashes, 'certify': cert_hashes}
    if stage == 'complete':
        for mode in (*CONSUMERS, 'verify-writes'):
            report, bindings = load_process(root / mode, installed)
            validate_common(report, mode, installed, manifest_hash, manifest, cert_hashes['componentSHA256'])
            if mode in CONSUMERS:
                validate_consumer(report, assets, cert)
            reports[mode], hashes[mode] = report, bindings
        validate_written_outputs(root / 'png-write', reports['png-write'], hashes['png-write']['componentSHA256'], reports['verify-writes'], assets, cert)
    for previous, current in zip(reports, list(reports)[1:]):
        before, after = hashes[previous], hashes[current]
        need(before['finishUptimeSeconds'] <= after['launchBeganUptimeSeconds'], 'next component launched before previous owned process exit')
        need(after['commandStartedAtEpochSeconds'] + .01 >= before['commandStartedAtEpochSeconds'] + before['commandDurationSeconds'],
             'next component started before previous owned command exited')
    pids = [report['processIdentifier'] for report in reports.values()]
    need(len(set(pids)) == len(pids), 'every component must have a distinct fresh process identifier')
    for mode in CONSUMERS:
        if mode in reports:
            for ordinal in range(1, 11):
                need(not os.path.lexists(root / mode / f'cycle-temp-{ordinal}'), 'cycle temporary directory still exists')
    return {'status': 'certified' if stage == 'certify' else 'complete', 'protocol': PROTOCOL,
        **installed, 'operatingSystem': manifest['operatingSystem'], 'fixtureSourceCommit': FIXTURE_SOURCE,
        'diagnosticOnly': True, 'fullWorkEquivalent': False, 'nativeExecutionAttestedByChecker': False,
        'memoryStabilityAssessed': False, 'productMemoryRemedyClaim': False,
        'inputManifestSHA256': manifest_hash, 'inputFileBytesVerified': True,
        'certificateSHA256': cert_hashes['componentSHA256'], 'completeRGBAReferencesBound': True,
        'allThirtyWrittenOutputsPostExitVerified': stage == 'complete',
        'ownedExitConfirmed': True, 'processIdentifiers': {mode: r['processIdentifier'] for mode, r in reports.items()},
        'evidenceBindings': hashes, 'observations': {mode: metrics(r) for mode, r in reports.items() if mode in CONSUMERS},
        'memoryComparisonExcluded': ['prepare', 'certify', 'verify-writes'],
        'interpretation': 'Unequal-work component diagnostics, not full editable acceptance, a leak/stability verdict, or a product memory remedy. Entry/preparation/warmup/late/final changes are independently derived signed observations. Kernel fields and checkpoint/draw deltas overlap and must not be summed into causal allocation ownership. Self-task calls are not atomic; 50 ms sampled peaks can miss transients. No pressure or purge request.'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--expected-source', required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--stage', choices=('certify', 'complete'), default='complete')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    result = {'status': 'failed', 'diagnosticOnly': True, 'fullWorkEquivalent': False,
              'nativeExecutionAttestedByChecker': False, 'memoryStabilityAssessed': False,
              'productMemoryRemedyClaim': False}
    try:
        result = check(args.app, args.expected_source, args.root, args.stage)
    except (ValueError, OSError, KeyError, TypeError, OverflowError, RecursionError, plistlib.InvalidFileException, zlib.error) as error:
        result['error'] = str(error)[:4096]
    text = json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + '\n'
    args.output.write_text(text)
    print(text, end='')
    return 1 if result['status'] == 'failed' else 0


if __name__ == '__main__':
    sys.exit(main())
