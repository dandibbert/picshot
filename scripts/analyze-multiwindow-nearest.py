#!/usr/bin/env python3
"""Compare observed Quartz index maps with explicit numerical hypotheses.

A matching hypothesis describes this finite probe, not a universal Quartz contract.
This script never edits the renderer or changes pixel-equality gates.
"""
import argparse
import collections
import json
import math
import pathlib
import struct


def f32(value):
    return struct.unpack('f', struct.pack('f', value))[0]


def hypotheses(source, destination, origin):
    clamp = lambda values: [min(source - 1, max(0, value)) for value in values]
    step = source / destination
    result = {
        'exactCenterUpper': [(2 * i + 1) * source // (2 * destination) for i in range(destination)],
        'exactCenterLower': [((2 * i + 1) * source - 1) // (2 * destination) for i in range(destination)],
        'doubleProduct': [math.floor((i + 0.5) * step) for i in range(destination)],
        'doubleDivision': [math.floor((i + 0.5) / (destination / source)) for i in range(destination)],
        'doubleTranslated': [math.floor((origin + i + 0.5) * step - origin * step) for i in range(destination)],
        'doubleBottomUp': [source - 1 - math.floor((destination - i - 0.5) * step) for i in range(destination)],
        'doubleTranslatedBottomUp': [source - 1 - math.floor((origin + destination - i - 0.5) * step - origin * step) for i in range(destination)],
        'floatProduct': [math.floor(f32(f32(i + 0.5) * f32(step))) for i in range(destination)],
        'floatTranslated': [math.floor(f32(f32(f32(origin + i + 0.5) * f32(step)) - f32(origin * step))) for i in range(destination)],
    }
    current = step / 2
    result['doubleIncrement'] = []
    for _ in range(destination):
        result['doubleIncrement'].append(math.floor(current))
        current += step
    current = f32(f32(step) / 2)
    result['floatIncrement'] = []
    for _ in range(destination):
        result['floatIncrement'].append(math.floor(current))
        current = f32(current + f32(step))
    for bits in (8, 12, 16, 24, 32):
        for rounding in ('Floor', 'Round'):
            numerator = source << bits
            fixed_step = (numerator + (destination // 2 if rounding == 'Round' else 0)) // destination
            result[f'fixed{bits}{rounding}Step'] = [(fixed_step // 2 + i * fixed_step) >> bits for i in range(destination)]
    return {name: clamp(values) for name, values in result.items()}


def axis_dimensions(case, axis):
    source = case['sourceWidth' if axis == 'x' else 'sourceHeight']
    destination = case['width' if axis == 'x' else 'height']
    origin = case['left'] if axis == 'x' else case['canvasHeight'] - case['top'] - case['height']
    return source, destination, origin


def analyze(report):
    assert report['status'] == 'observed', 'Probe did not complete'
    cases = report['cases']
    assert len(cases) == report['plannedCases'] == report['completedCases']
    totals = collections.defaultdict(lambda: collections.Counter())
    examples = collections.defaultdict(list)
    tie_counts = collections.Counter()
    tie_examples, non_tie_examples, nonseparable = [], [], []
    orientation_groups, clip_groups, translation_groups = collections.defaultdict(dict), collections.defaultdict(dict), collections.defaultdict(dict)
    checked_positions = 0
    for case in cases:
        if case['nonseparablePixelCount']:
            nonseparable.append({'label': case['label'], 'count': case['nonseparablePixelCount'], 'examples': case['nonseparableExamples']})
        for axis in ('x', 'y'):
            source, destination, origin = axis_dimensions(case, axis)
            actual = case[axis + 'Map']
            assert len(actual) == destination
            assert all(isinstance(v, int) and 0 <= v < source for v in actual)
            mirror = case['mirrorX' if axis == 'x' else 'mirrorY']
            # Reflect source indices to put mirrored observations in forward-index
            # form. Their tie preference may differ; that is useful evidence.
            observed = [source - 1 - v for v in actual] if mirror else actual
            models = hypotheses(source, destination, origin)
            ties = [(2 * i + 1) * source % (2 * destination) == 0 for i in range(destination)]
            group = axis + ('Mirrored' if mirror else 'Forward')
            for index, (value, exact) in enumerate(zip(observed, models['exactCenterUpper'])):
                checked_positions += 1
                if ties[index]:
                    choice = 'upper' if value == exact else ('lower' if value == exact - 1 else 'other')
                    tie_counts[group + '.' + choice] += 1
                    if len(tie_examples) < 32:
                        tie_examples.append({'label': case['label'], 'axis': axis, 'index': index, 'boundary': exact, 'observedForwardIndex': value, 'mirrored': mirror})
                elif value != exact and len(non_tie_examples) < 64:
                    non_tie_examples.append({'label': case['label'], 'axis': axis, 'index': index, 'expectedExact': exact, 'observedForwardIndex': value, 'mirrored': mirror,
                        'coordinateNumerator': (2 * index + 1) * source, 'coordinateDenominator': 2 * destination})
            for name, expected in models.items():
                key = group + '.' + name
                totals[key]['cases'] += 1
                mismatches = [i for i, (a, b) in enumerate(zip(observed, expected)) if a != b]
                totals[key]['positions'] += destination
                totals[key]['mismatchedCases'] += bool(mismatches)
                totals[key]['mismatchedPositions'] += len(mismatches)
                totals[key]['tieMismatches'] += sum(ties[i] for i in mismatches)
                totals[key]['nonTieMismatches'] += sum(not ties[i] for i in mismatches)
                if mismatches and len(examples[key]) < 8:
                    i = mismatches[0]
                    examples[key].append({'label': case['label'], 'index': i, 'actual': observed[i], 'predicted': expected[i], 'exactTie': ties[i]})
        if case['label'].startswith('grid-'):
            translation_groups[(case['sourceWidth'], case['width'])]['translated' if case['left'] else 'origin'] = case
        if case['label'].startswith('long-'):
            clip_groups[(case['sourceWidth'], case['sourceHeight'], case['width'], case['height'])][case['clips']] = case
        if case['label'].startswith('orientation-'):
            orientation_groups[(case['sourceWidth'], case['width'], case['left'])][(case['mirrorX'], case['mirrorY'])] = case
    translation_differences, clip_differences, orientation_differences = [], [], []
    def first_difference(left, right):
        return next((i for i, (a, b) in enumerate(zip(left, right)) if a != b), None)
    for records in translation_groups.values():
        base, moved = records['origin'], records['translated']
        for axis in ('x', 'y'):
            index = first_difference(base[axis + 'Map'], moved[axis + 'Map'])
            if index is not None:
                translation_differences.append({'base': base['label'], 'translated': moved['label'], 'axis': axis, 'index': index,
                    'baseIndex': base[axis + 'Map'][index], 'translatedIndex': moved[axis + 'Map'][index]})
    for records in clip_groups.values():
        base = records['whole']
        for clip in ('strips128', 'tailFirst128'):
            for axis in ('x', 'y'):
                other = records[clip]
                index = first_difference(base[axis + 'Map'], other[axis + 'Map'])
                if index is not None:
                    clip_differences.append({'base': base['label'], 'other': other['label'], 'axis': axis, 'index': index,
                        'baseIndex': base[axis + 'Map'][index], 'otherIndex': other[axis + 'Map'][index]})
    for records in orientation_groups.values():
        base = records[(False, False)]
        for (mirror_x, mirror_y), other in records.items():
            if not mirror_x and not mirror_y:
                continue
            for axis, mirrored in [('x', mirror_x), ('y', mirror_y)]:
                expected = base[axis + 'Map'][::-1] if mirrored else base[axis + 'Map']
                index = first_difference(expected, other[axis + 'Map'])
                if index is not None:
                    orientation_differences.append({'base': base['label'], 'other': other['label'], 'axis': axis,
                        'index': index, 'reflectedOutputIndex': expected[index], 'otherIndex': other[axis + 'Map'][index]})
    ranked = {}
    for group in ('xForward', 'yForward', 'xMirrored', 'yMirrored'):
        entries = [{'model': key.split('.', 1)[1], **dict(value), 'examples': examples[key]}
                   for key, value in totals.items() if key.startswith(group + '.')]
        ranked[group] = sorted(entries, key=lambda v: (v['mismatchedPositions'], v['mismatchedCases'], v['model']))
    return {
        'status': 'analyzed', 'observedCases': len(cases), 'checkedAxisPositions': checked_positions,
        'compiledArchitecture': report.get('compiledArchitecture'), 'osVersion': report.get('osVersion'),
        'interpretationBoundary': 'Numerical hypotheses over observed finite cases only. No production change or general Quartz contract inferred.',
        'tieChoices': dict(tie_counts), 'tieExamples': tie_examples, 'nonTieDisagreementExamples': non_tie_examples,
        'nonseparableCases': nonseparable, 'translationDifferences': translation_differences,
        'clipPartitionDifferences': clip_differences, 'mirrorVsReflectedOutputDifferences': orientation_differences,
        'modelsRankedByAxis': ranked,
        'run100Geometries': [case for case in cases if case['label'].startswith('run100-')],
        'equivalenceEstablished': False, 'productionChanged': False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output already exists; use a fresh path')
    result = analyze(json.loads(args.report.read_text()))
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ['status', 'observedCases', 'checkedAxisPositions', 'tieChoices']}, indent=2))
    print('Translation differences:', len(result['translationDifferences']))
    print('Clip differences:', len(result['clipPartitionDifferences']))
    print('Non-tie discrepancy examples:', len(result['nonTieDisagreementExamples']))
    for axis, models in result['modelsRankedByAxis'].items():
        print(axis, [(m['model'], m['mismatchedPositions']) for m in models[:5]])


if __name__ == '__main__':
    main()
