#!/usr/bin/env python3
"""One exact185 owned XCTest diagnostic, with269 product inputs and420s cap.

Reuses the unchanged direct-child runner. Native method boundaries are flushed
with NSUnbufferedIO=YES; owned stack samples never infer guilt from the last line.
This is not an ordinary SwiftPM rerun or distribution acceptance.
"""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import sys
import time
from types import SimpleNamespace

sys.dont_write_bytecode = True


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value


L = module('live_scroll_source_binding', 'local-shortcut-owned-diagnostic.py')
O, N, D, need, save = L.O, L.N, L.D, L.need, L.save
REFERENCE_SOURCE = 'f2ffefbafe46f93509d949f15fafbf3d88587c74'
REFERENCE_TREE = 'e86b1cba5dc2b0f487dda7c40c57d21d55ea8a10'
PRODUCT_SHA256 = 'f9610dd6667a05ad5b236da280b00a8bcf8847132e3a47f12c2e668278dfb374'
TESTS_SHA256 = '48f3098bcd67e99ff1a0edd16fcb22aa9002fdb37589c29686fa1615bc469dc0'
FULL_IDS_SHA256 = '38a94e9f556705bb7b34260cca519f70d8058e59ef4f12b0701cf1a65ad79d07'
SELECTED_IDS_SHA256 = '4f9b613004f8ac93aca7d18c5ac29defd96cd6f580fc688a4fb5a68c120bb1a9'
SOURCE_IDS_SHA256 = '89186110aeac71ab6814c6d6e6875dad962c061fc087728af9d0455891fc030c'
HELPERS = {
    'native-owned-xctest.py': 'da1d24aa1c21738e285cdbf9a6cbbbe2084dcb17dba1cc762ad7b5ca01d0161d',
    'local-shortcut-owned-diagnostic.py': '955bb3f3ea49843088a830a5171efa984f2d17a73cad21d1a284ec0c241487e7',
    'native-test-diagnostics.py': '8439c941e72e0382ce4530f0c0ffc01fc03b6d672c93ec5c7cf55691cd3f49e5',
    'native-test-shards.py': '797e5ddaf62b140dc60775fd5ddc267b2da1ffb0d21f6537fbf4fb9124387380',
    'run-bounded-command.py': 'ef85307a6227a0d99641b17c75e2aa625ae7344376fbcb3ec1af1c5be7e2d5d2',
}
CORRECTED_TESTS = {
    'Tests/PicShotTests/LiveScrollDeliveryTests.swift': 'd1e1f335d8d0c50cb144c7ccd2240c16d6c74cf4',
    'Tests/PicShotTests/LiveScrollOutputTransactionTests.swift': '618e9de20ad22e24c4f690d5210ee1366cbbfdde',
    'Tests/PicShotTests/LiveScrollSessionInteractionTests.swift': '860984a409e2c0821fda46f34ebe0d6f7ec5ac27',
}
SLOTS = (180, 360)
SCOPE = 'One exact185 LiveScroll owned-XCTest diagnostic; not SwiftPM reproduction or installer acceptance'


def tree_rows(raw):
    rows = []
    for line in raw.splitlines():
        match = re.fullmatch(r'(100644|100755) blob ([0-9a-f]{40})\t([A-Za-z0-9_./ -]+)', line)
        need(match is not None, 'Unexpected tracked input tree entry')
        mode, digest, path = match.groups()
        need('..' not in Path(path).parts, 'Unsafe tracked input path')
        rows.append(dict(path=path, mode=mode, sha=digest))
    need(rows and len(rows) == len({row['path'] for row in rows}), 'Empty or duplicate input tree')
    return sorted(rows, key=lambda row: row['path'])


def tree_digest(rows):
    return O.sha(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode())


def frozen_inputs(root, query):
    product = tree_rows(query(['git', 'ls-tree', '-r', '--full-tree', 'HEAD', '--', 'Package.swift', 'Sources'], root))
    tests = tree_rows(query(['git', 'ls-tree', '-r', '--full-tree', 'HEAD', '--', 'Tests'], root))
    need(len(product) == 336 and tree_digest(product) == PRODUCT_SHA256, 'Product inputs differ from immutable269')
    need(len(tests) == 290 and tree_digest(tests) == TESTS_SHA256, 'Tests differ beyond approved held-operation corrections')
    index = {row['path']: row['sha'] for row in tests}
    need(all(index.get(path) == digest for path, digest in CORRECTED_TESTS.items()), 'Approved test correction differs')
    helpers = {name: O.file_identity(root/'scripts'/name) for name in HELPERS}
    need(all(helpers[name]['sha256'] == digest for name, digest in HELPERS.items()), 'Original owned diagnostic helper changed')
    return dict(referenceSourceCommit=REFERENCE_SOURCE, referenceSourceTree=REFERENCE_TREE,
        productRows=product, productSHA256=PRODUCT_SHA256, testRows=tests, testsSHA256=TESTS_SHA256,
        correctedTestBlobs=CORRECTED_TESTS, originalHelpers=helpers)


def selection(root, path):
    raw = N.bounded_text(path, N.MAX_INVENTORY_BYTES)
    discovered = N.discover(raw)
    need(len(discovered) == 2436 and len({name.split('/')[0] for name in discovered}) == 271
         and O.ids_digest(discovered) == FULL_IDS_SHA256, 'Full native2436 discovery differs')
    source = root/'scripts/live-scroll-additive-tests.json'
    need(O.file_identity(source)['sha256'] == SOURCE_IDS_SHA256, 'Original185 source inventory bytes changed')
    names = json.loads(N.bounded_text(source, 128*1024))
    need(type(names) is list and names == sorted(set(names)) and len(names) == 185
         and O.ids_digest(names) == SELECTED_IDS_SHA256
         and names == [name for name in discovered if '.LiveScroll' in name], 'Exact185 selection differs')
    ordered = [line.strip() for line in raw.splitlines() if line.strip() in set(names)]
    need(sorted(ordered) == names, 'Raw discovery order lost selected methods')
    return ordered, raw


def launch_inputs(args):
    need(sys.platform == 'darwin' and re.fullmatch('[0-9a-f]{40}', args.source), 'Exact native source required')
    root = args.source_root.resolve(strict=True)
    evidence = args.directory.with_name(args.directory.name+'-inputs')
    need(not args.directory.exists() and not args.directory.is_symlink(), 'Fresh owned evidence directory required')
    evidence.mkdir(parents=True, exist_ok=False)
    deadline = time.monotonic()+O.SETUP_SECONDS
    def query(argv, cwd=None, raw=False):
        remaining = deadline-time.monotonic()
        need(remaining > 0, 'Original60 second setup deadline exceeded')
        return O.bounded_read(argv, cwd, timeout=min(20, remaining), strip=not raw)
    tree = query(['git', 'rev-parse', 'HEAD^{tree}'], root)
    source = L.source_inputs(SimpleNamespace(expected_source=args.source, expected_tree=tree), root, evidence, query)
    frozen = frozen_inputs(root, query)
    save(evidence/'frozen-inputs.json', frozen)
    ordered, raw = selection(root, args.inventory)
    (evidence/'native-test-discovery.log').write_text(raw)
    selected = query(['/usr/bin/xcode-select', '-p'])
    developer = Path(os.environ.get('DEVELOPER_DIR') or selected).resolve(strict=True)
    if developer.suffix == '.app': developer /= 'Contents/Developer'
    platform = Path(query(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'])).resolve(strict=True)
    need(platform == developer/'Platforms/MacOSX.platform', 'Selected Xcode platform differs')
    agent = (platform/'Developer/Library/Xcode/Agents/xctest').resolve(strict=True)
    need(platform in agent.parents and agent.is_file(), 'XCTest agent escaped selected Xcode')
    with agent.open('rb') as stream:
        need(stream.read(4) in (b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xce',
            b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'), 'XCTest agent is not Mach-O')
    bin_path = Path(query(['/usr/bin/xcrun', 'swift', 'build', '--show-bin-path'], root)).resolve(strict=True)
    bundle = bin_path/'PicShotPackageTests.xctest'
    layout = O.bundle_inputs(root, bundle, bin_path, evidence, deadline)
    files = {name: {key: row[key] for key in ('bytes', 'sha256')}
             for name, row in layout['inventory'].items() if row['kind'] == 'file'}
    env = O.test_environment(os.environ, platform, 'unbuffered')
    identity = dict(sourceCommit=args.source, sourceTree=tree, sourceRoot=str(root),
        sourceInputEvidence=source, frozenInputs=frozen,
        rawDiscovery=O.file_identity(evidence/'native-test-discovery.log'),
        orderedSelectedIDs=ordered, selectedIDsSHA256=O.ids_digest(sorted(ordered)),
        orderedSelectedIDsSHA256=O.ids_digest(ordered), commaSelectorSHA256=O.sha(','.join(ordered).encode()),
        xctestPath=str(agent), xctest=O.file_identity(agent, deadline), bundlePath=str(bundle),
        bundleLayoutEvidence=layout, bundleFiles=files,
        bundleManifestSHA256=O.sha(json.dumps(files, sort_keys=True).encode()),
        bundleExecutable=files['Contents/MacOS/PicShotPackageTests'],
        xcodeSelectDirectory=selected, effectiveDeveloperDirectory=str(developer),
        xcodeVersion=query(['/usr/bin/xcodebuild', '-version']), swiftVersion=query(['/usr/bin/xcrun', 'swift', '--version']),
        osVersion=query(['/usr/bin/sw_vers']), adapter=O.file_identity(Path(__file__), deadline),
        runtimeEnvironment={key: env.get(key) for key in
            ('DYLD_FRAMEWORK_PATH','DYLD_LIBRARY_PATH','SWIFT_TESTING_ENABLED','NO_COLOR','NSUnbufferedIO')},
        limits=dict(setupSeconds=60, nativeSeconds=420, samplerSeconds=40,
                    sampleCollectionSeconds=2, sampleIntervalMilliseconds=10, postVerificationSeconds=20))
    need(time.monotonic() < deadline, 'Original60 second setup allowance exceeded')
    save(evidence/'launch-inputs.json', identity)
    return identity, env


def method_phases(log, expected):
    rows = [dict(index=index, method=match[1]+'/'+match[2], event=match[3])
            for index, match in enumerate(N.CASE_EVENT.finditer(log))]
    need(len(rows) <= 2*len(expected) and all(row['method'] in expected for row in rows),
         'Unexpected or excessive native method boundaries')
    by_method = {}
    for row in rows: by_method.setdefault(row['method'], []).append(row['event'])
    need(all(events in (['started'], ['started','passed'], ['started','failed']) for events in by_method.values()),
         'Duplicate, skipped or invalid native method boundaries')
    return dict(events=rows, passedIDs=sorted(name for name, events in by_method.items() if events==['started','passed']),
        failedIDs=sorted(name for name, events in by_method.items() if events==['started','failed']),
        startedWithoutTerminalIDs=sorted(name for name, events in by_method.items() if events==['started']),
        notStartedIDs=sorted(set(expected)-set(by_method)), lastPrintedMethodIsNotCausalAttribution=True)


def validate_process(directory, process, identity):
    evidence = directory.with_name(directory.name+'-inputs')
    need(json.loads(N.bounded_text(evidence/'launch-inputs.json', D.METADATA_CAP)) == identity,
         'Raw launch-input report differs')
    source = identity['sourceInputEvidence']
    need(json.loads(N.bounded_text(evidence/'source-inputs.json', D.METADATA_CAP)) == source
         and source['sourceCommit'] == identity['sourceCommit'] and source['sourceTree'] == identity['sourceTree'],
         'Raw source-input report differs')
    for key, name in (('trackedStatus','tracked-status.txt'),('buildInputStatus','build-input-status.txt')):
        need(N.bounded_text(evidence/name,64*1024) == source[key], 'Raw source status differs')
    lock = source['packageResolved']
    if lock['status']=='verified-generated':
        path=evidence/'Package.resolved'
        need(O.file_identity(path)=={key:lock[key] for key in ('bytes','sha256')}
             and path.stat().st_size <= O.RESOLVED_LIMIT and O.resolved_pin(path.read_bytes())==lock['resolved'],
             'Archived generated lock changed')
    else:
        need(lock['status']=='absent' and not (evidence/'Package.resolved').exists(), 'Absent generated lock differs')
    need(json.loads(N.bounded_text(evidence/'frozen-inputs.json', D.METADATA_CAP)) == identity['frozenInputs'],
         'Raw frozen-input report differs')
    need(O.file_identity(evidence/'native-test-discovery.log') == identity['rawDiscovery'], 'Raw discovery bytes changed')
    need(json.loads(N.bounded_text(directory/'process.json', D.METADATA_CAP)) == process, 'Raw process evidence differs')
    need(process['command'] == O.command(identity['xctestPath'], identity['bundlePath'], identity['orderedSelectedIDs'])
         and process['timeoutSeconds'] == 420 and process['samplerTimeoutSeconds'] == 40
         and process['expectedCaptureSlots'] == [180,360], 'Owned command or existing limits changed')
    need(process['schemaVersion'] == 1 and process['diagnosticOnly'] is True and process['installerAcceptance'] is False
         and process['cancellationSignal'] is None and process['cleanupConfirmed'] is True
         and process['outputEOF'] is True and not process['errors']
         and not process['logTruncated'] and process['status'] in ('exited','timeout'), 'Unproven owned cleanup or incomplete output')
    root = process['root']; target = root['identity']
    need(target is not None and not root['bindingError'] and not root.get('identityMismatch')
         and not root.get('emergencyCleanup') and root['cleanupConfirmed'] is True
         and target['pid'] == target['groupID'] == root['pid'] and target['parentPID'] == root['ownerPID']
         and target['executable'] == identity['xctestPath'] and root['returnCode'] == process['rootReturnCode']
         and root['retirementEvidence'] == 'unreaped-exit-observation-then-Popen-wait', 'Root identity/retirement differs')
    elapsed = process['workloadEndSeconds']
    need(type(elapsed) in (int,float) and math.isfinite(elapsed) and elapsed >= 0, 'Invalid workload duration')
    due = [slot for slot in SLOTS if slot <= elapsed]
    need(process['dueCaptureSlots'] == due and [row['slotSeconds'] for row in process['captures']] == due,
         'Missing, repeated or late owned sample')
    if process['status']=='timeout':
        need(elapsed >= 420 and process['terminationStartedAtSeconds'] >= 420 and due==[180,360], '420s timeout changed')
    for capture in process['captures']:
        need(capture['slotSeconds'] <= capture['startedAtSeconds'] <= elapsed, 'Sample outside workload')
        O.validate_capture(directory, capture, root)
    need(O.file_identity(directory/'xctest.log') == process['logIdentity'], 'Unbuffered raw log changed')
    O.verify_bundle_inputs(directory, identity)
    return target


def run(args):
    args.directory = args.directory.resolve()
    identity, env = launch_inputs(args)
    process = O.run_owned(O.command(identity['xctestPath'], identity['bundlePath'], identity['orderedSelectedIDs']),
        env, identity['sourceRoot'], args.directory, D.ProcessIdentity(), timeout=420, slots=SLOTS)
    result = dict(schemaVersion=1, scope=SCOPE, diagnosticOnly=True, installerAcceptance=False,
        ordinarySwiftPMAcceptance=False, diagnosticSourceCommit=identity['sourceCommit'], productReferenceCommit=REFERENCE_SOURCE,
        inputs=identity, process=process, evidenceStatus='rejected', caseStatus='unverified',
        launcherDifference='One directly owned platform XCTest process; no SwiftPM parent; NSUnbufferedIO=YES',
        phaseMarkerSource='Original XCTest started/passed/failed lines on the owned child pipe; no added method instrumentation',
        original269TimeoutPreserved=True, original269CauseEstablished=False)
    save(args.directory/'result.json', result)
    try:
        target = validate_process(args.directory, process, identity)
        log = N.bounded_text(args.directory/'xctest.log', N.MAX_LOG_BYTES)
        phases = method_phases(log, identity['orderedSelectedIDs'])
        save(args.directory/'method-phases.json', dict(ownedPID=target['pid'], rawLogIdentity=process['logIdentity'], **phases))
        result['methodPhases'] = phases
        deadline = time.monotonic()+20
        def query(argv, cwd=None):
            need(time.monotonic() < deadline, 'Post-verification deadline exceeded')
            return O.bounded_read(argv, cwd, timeout=min(5,max(.01,deadline-time.monotonic())))
        root = Path(identity['sourceRoot'])
        need(query(['git','rev-parse','HEAD'],root)==identity['sourceCommit']
             and query(['git','rev-parse','HEAD^{tree}'],root)==identity['sourceTree']
             and query(['git','status','--porcelain','--untracked-files=no'],root)==''
             and query(['git','status','--porcelain','--untracked-files=all','--','Sources','Tests','Package.swift'],root)=='',
             'Product or test inputs changed during owned cell')
        need(frozen_inputs(root,query)==identity['frozenInputs'], 'Frozen inputs changed during owned cell')
        need(O.file_identity(Path(__file__),deadline)==identity['adapter'], 'Diagnostic adapter changed during owned cell')
        lock=identity['sourceInputEvidence']['packageResolved'];lock_path=root/'Package.resolved'
        need((lock['status']=='absent' and not lock_path.exists()) or (lock['status']=='verified-generated'
             and O.file_identity(lock_path,deadline)=={key:lock[key] for key in ('bytes','sha256')}),
             'Generated dependency lock changed during owned cell')
        need(O.bundle_inputs(root,Path(identity['bundlePath']),Path(identity['bundlePath']).parent,None,deadline)
             == identity['bundleLayoutEvidence'], 'Compiled XCTest bundle changed during owned cell')
        result.update(evidenceStatus='verified', caseStatus='timeout' if process['status']=='timeout' else 'failed')
        if process['status']=='exited' and process['rootReturnCode']==0:
            passed, skipped=N.case_results(log, sorted(identity['orderedSelectedIDs']))
            need(not skipped and len(passed)==185, 'All185 cases must pass without skips')
            result['caseStatus']='passed'
    except Exception as error:
        result['evidenceError']=type(error).__name__+': '+str(error)
    finally:
        save(args.directory/'result.json', result)
    print(json.dumps({key:result[key] for key in ('evidenceStatus','caseStatus','diagnosticOnly','productReferenceCommit')}),flush=True)
    return 0 if result['evidenceStatus']=='verified' and result['caseStatus']=='passed' else 124 if process['status']=='timeout' else 1


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',required=True);parser.add_argument('--source-root',type=Path,default=Path.cwd())
    parser.add_argument('--inventory',type=Path,required=True);parser.add_argument('--directory',type=Path,required=True)
    return run(parser.parse_args())


if __name__=='__main__':
    try: raise SystemExit(main())
    except (ValueError,OSError,KeyError,TypeError) as error:
        print('Exact LiveScroll diagnostic rejected: '+str(error),file=sys.stderr)
        raise SystemExit(1)
