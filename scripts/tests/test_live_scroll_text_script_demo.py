"""Owned deterministic adversarial inputs, never evidence of native execution."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

SCRIPTS = Path(__file__).resolve().parents[1]

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result

C = module('live_scroll_text_reader_tests', SCRIPTS/'check-live-scroll-text-script-demo.py')
T = module('saved_text_reader_inputs', SCRIPTS/'tests/test_text_script_demo.py')
SOURCE = T.SOURCE
IDS = [prefix+'1111111-2222-3333-4444-555555555555' for prefix in 'EF12']
sha, dump, rect = T.sha, T.dump, T.rect
SOURCE_PNG, SOURCE_HASH = T.T.png(C.WIDTH, C.HEIGHT)
CHOICE_LIGHT_PNG, CHOICE_LIGHT_HASH = T.T.png(460,600,(240,240,240,255))
CHOICE_DARK_PNG, CHOICE_DARK_HASH = T.T.png(460,600,(30,30,30,255))


def artifacts(phase):
    width=460 if phase=='choice' else 600
    rows = []
    for index, (identifier, label) in enumerate(C.PHASES[phase].items()):
        kind = 'field' if identifier.endswith(('.title', '.description', '.name', '.outputs', '-status')) or '-receipt-' in identifier else 'button'
        row = T.control(identifier, index, kind)
        row.update(text=label, tooltip=label, accessibilityValue=label, accessibilityLabel=label)
        if phase=='choice':
            row['fullFrame']['width']=row['screenFrame']['width']=412
            if kind=='field':row['alignmentWidth']=400
        if identifier.endswith('.choice'):
            row['class']='NSPopUpButton'
            row['tooltip']=row['accessibilityValue']=C.NAME+' · '+C.PHASES['choice']['scroll.live.textScript.choice.outputs']
        rows.append(row)
    return [dict(filename='scroll-text-script-'+phase+'-'+mode+'.png', appearance=mode, width=width, height=600,
        canonicalRGBAPixelSHA256=pixel_hash, layout=dict(phase='scroll-text-script-'+phase, passed=True, windowVisible=True,
            violations=[], fullNativeFramesMeasured=True, alignmentRectanglesSubstituted=False,
            windowNumber=12, windowFrame=rect(20,20,width,622), screenFrame=rect(0,0,1200,900),
            contentBounds=rect(0,0,width,600), controls=copy.deepcopy(rows)))
        for mode,pixel_hash in [('light',CHOICE_LIGHT_HASH if phase=='choice' else T.LIGHT_HASH), ('dark',CHOICE_DARK_HASH if phase=='choice' else T.DARK_HASH)]]


def report():
    reference = dict(width=C.WIDTH, height=C.HEIGHT, canonicalRGBAPixelSHA256=SOURCE_HASH)
    case = copy.deepcopy(C.CASE_FIXED)
    case.update(preRunFrontier=copy.deepcopy(C.FRONTIER), definitionID=IDS[0], requestID=IDS[2], runID=IDS[1],
        isolatedDefaultsBeforeSHA256='d'*64, isolatedDefaultsAfterSHA256='d'*64,
        sourceProviderCallsAtFailure=10, sourceProviderCallsAfterRetry=10,
        ocrTextSHA256=sha(b'ABC-123\nXYZ-987\nABC-123'), ocrTextBytes=len(b'ABC-123\nXYZ-987\nABC-123'), catalogBeforeSHA256='b'*64, catalogAfterSHA256='b'*64,
        generatedActualOCR='ABC-123\nXYZ-987\nABC-123', helperMetrics=[T.metrics(IDS[2])],
        acceptedImageReference=copy.deepcopy(reference), acceptedPNGFileSHA256=sha(SOURCE_PNG),
        sourceImageComparison=dict(passed=True, dimensionsMatch=True, exactCanonicalRGBAEquality=True,
            width=C.WIDTH, height=C.HEIGHT, expectedWidth=C.WIDTH, expectedHeight=C.HEIGHT,
            outputPixelSHA256=SOURCE_HASH, sourcePixelSHA256=SOURCE_HASH, method=C.C.COMPARISON),
        failureAttempts=dict(capture=0,ocr=1,transform=1,copy=1,committedCopy=0),
        attempts=dict(capture=0,ocr=1,transform=1,copy=2,committedCopy=1),
        viewportTrace=[dict(offset=offset,height=480+offset,acceptedObservations=i+1) for i,offset in enumerate(C.OFFSETS)],
        actionTrace=copy.deepcopy(C.ACTIONS), copiedTextSHA256=sha(C.EXPECTED.encode()))
    for phase in C.PHASES: case[phase+'Artifacts'] = artifacts(phase)
    value = copy.deepcopy(C.TOP_FIXED)
    value.update(sourceCommit=SOURCE, limits=copy.deepcopy(C.LIMITS), sourceReference=reference, sourcePNGFileSHA256=sha(SOURCE_PNG),
        ownership={key:True for key in C.OWNERS}, elapsedSeconds=10., copyRetry=case)
    return value


def fixture(root):
    root = root.resolve(strict=True)
    value = report(); case = value['copyRetry']
    for name in ('owned-numbered', 'accepted'): (root/('scroll-text-script-'+name+'.png')).write_bytes(SOURCE_PNG)
    (root/'scroll-text-script-source.js').write_bytes(C.SOURCE_BODY.encode())
    (root/'scroll-text-script-ocr.txt').write_bytes(case['generatedActualOCR'].encode())
    (root/'scroll-text-script-copied.txt').write_bytes(C.EXPECTED.encode())
    catalog = dict(version=1, selectedID=case['definitionID'], definitions=[dict(id=case['definitionID'],name=C.NAME,source=C.SOURCE_BODY)])
    dump(root/'scroll-text-script-catalog.json',catalog)
    case['catalogBeforeSHA256'] = case['catalogAfterSHA256'] = sha((root/'scroll-text-script-catalog.json').read_bytes())
    dump(root/'scroll-text-script-actions.json',dict(actionTrace=case['actionTrace'], failureReceipts=case['failureReceipts'], receipts=case['receipts']))
    for phase in C.PHASES:
        for artifact in case[phase+'Artifacts']:
            light,dark=(CHOICE_LIGHT_PNG,CHOICE_DARK_PNG) if phase=='choice' else (T.LIGHT_PNG,T.DARK_PNG)
            (root/artifact['filename']).write_bytes(light if artifact['appearance']=='light' else dark)
            dump(root/(artifact['filename'][:-4]+'-layout.json'),artifact)
    dump(root/'scroll-text-script-case.json',case)
    path = root/C.RAW_NAME; dump(path,value)
    return path


def installed_fixture(root):
    outer, proof, sources = T.fixture(root, include_current_long_image=False)
    launch_path=outer.with_name(outer.name+'.launcher.json')
    launch=json.loads(launch_path.read_text());launch['scope']=C.LAUNCH_SCOPE;dump(launch_path,launch)
    child_dir = outer.parent/'current-long-image'; child_dir.mkdir()
    child = fixture(child_dir)
    for path in (outer, outer.parent/'text-script-demo.json'):
        value = json.loads(path.read_text()); value['currentLongImage'] = json.loads(child.read_text()); dump(path,value)
    package = json.loads(proof.read_text())
    present = {row['path'] for row in package['sources']}
    for name in sorted(C.REQUIRED_SOURCES-present):
        path = sources/name; path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(b'Owned synthetic current long image source inventory input')
        package['sources'].append(dict(path=name,bytes=path.stat().st_size,sha256=sha(path.read_bytes())))
    dump(proof,package)
    return outer,proof,sources


class ContractTests(unittest.TestCase):
    def test_complete_owned_contract(self):
        C.contract(report(),SOURCE)

    def test_every_top_level_and_case_field_is_required(self):
        original = report()
        for container in ((), ('copyRetry',)):
            baseline = original if not container else original[container[0]]
            for key in baseline:
                value = copy.deepcopy(original); target = value if not container else value[container[0]]; del target[key]
                with self.subTest(container=container,key=key), self.assertRaises(ValueError): C.contract(value,SOURCE)

    def test_unknown_fields_fail_at_bounded_levels(self):
        paths = [(), ('copyRetry',), ('ownership',), ('sourceReference',), ('copyRetry','attempts'),
            ('copyRetry','failureAttempts'), ('copyRetry','acceptedImageReference'), ('copyRetry','sourceImageComparison'),
            ('copyRetry','helperMetrics',0), ('copyRetry','helperMetrics',0,'signature'),
            ('copyRetry','choiceArtifacts',0), ('copyRetry','choiceArtifacts',0,'layout'),
            ('copyRetry','choiceArtifacts',0,'layout','controls',0),
            ('copyRetry','choiceArtifacts',0,'layout','controls',0,'fullFrame'),
            ('copyRetry','actionTrace',0), ('copyRetry','viewportTrace',0), ('limits',),
            ('copyRetry','preRunFrontier'), ('copyRetry','receipts',0)]
        for path in paths:
            value = report(); target = value
            for key in path: target = target[key]
            target['unreviewed'] = 'payload'
            with self.subTest(path=path), self.assertRaises(ValueError): C.contract(value,SOURCE)

    def test_boolean_and_integer_type_substitutions_fail(self):
        original = report()
        for path in ((), ('copyRetry',), ('copyRetry','attempts'), ('copyRetry','failureAttempts'), ('copyRetry','preRunFrontier'), ('ownership',), ('limits',)):
            baseline = original
            for key in path: baseline = baseline[key]
            for key,item in baseline.items():
                if type(item) not in (bool,int): continue
                value = copy.deepcopy(original); target = value
                for part in path: target = target[part]
                target[key] = int(item) if type(item) is bool else bool(item)
                with self.subTest(path=path,key=key),self.assertRaises(ValueError): C.contract(value,SOURCE)

    def test_metrics_use_existing_strict_production_contract(self):
        for key,bad in [('outcome','failed'),('childExitConfirmed',False),('pipesDrained',False),
            ('admissionReleased',False),('requestID',IDS[3]),('sampledPeakResidentBytes',256*1024**2+1),
            ('residentSamples',0),('acceptedSeconds',3.1),('stderrBytes',1),('retainedResponseBytesAfterFinish',1),
            ('responseIdentityMatched',False),('observationScope','hard memory cap')]:
            value=report();value['copyRetry']['helperMetrics'][0][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):C.contract(value,SOURCE)
        value=report();value['copyRetry']['helperMetrics'][0]['signature']['helperEntitlements'].append('com.apple.security.network.client')
        with self.assertRaises(ValueError):C.contract(value,SOURCE)

    def test_layout_and_readability_fail_closed(self):
        for mutation in ('offscreen','clipped','overlap','missing','duplicate','wrong-class','foreign-window','forged-path','forged-parent','hidden','hit-test','unreadable','wrong-text'):
            value=report();artifact=value['copyRetry']['choiceArtifacts'][0];layout=artifact['layout'];rows=layout['controls']
            if mutation=='offscreen':layout['windowFrame']['x']=1199
            elif mutation=='clipped':rows[0]['fullFrame']['x']=599
            elif mutation=='overlap':rows[1]['fullFrame']=copy.deepcopy(rows[0]['fullFrame'])
            elif mutation=='missing':rows.pop(0)
            elif mutation=='duplicate':rows.append(copy.deepcopy(rows[0]))
            elif mutation=='wrong-class':rows[0]['class']='UnreviewedControl'
            elif mutation=='foreign-window':rows[0]['ownerWindowNumber']=99
            elif mutation=='forged-path':rows[1]['viewPath']=rows[0]['viewPath']
            elif mutation=='forged-parent':rows[0]['ancestorIDs']=[rows[1]['id']]
            elif mutation=='hidden':rows[0]['hidden']=True
            elif mutation=='hit-test':next(row for row in rows if row['kind']=='button')['hitTest']=False
            elif mutation=='unreadable':next(row for row in rows if row['kind']=='field')['fontSize']=10
            else:rows[0]['text']='unrelated content'
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):C.contract(value,SOURCE)

    def test_counts_frontier_receipts_scope_and_cleanups(self):
        mutations=[('scope',lambda r:r.update(scope='unbounded installed acceptance')),
            ('viewport-boolean',lambda r:r['copyRetry']['viewportOffsets'].__setitem__(0,False)),
            ('source',lambda r:r.update(sourceCommit='b'*40)),
            ('capture',lambda r:r['copyRetry']['attempts'].update(capture=1)),
            ('repeat-ocr',lambda r:r['copyRetry']['attempts'].update(ocr=2)),
            ('repeat-helper',lambda r:r['copyRetry']['attempts'].update(transform=2)),
            ('repeat-copy',lambda r:r['copyRetry']['attempts'].update(copy=3)),
            ('repeat-commit',lambda r:r['copyRetry']['attempts'].update(committedCopy=2)),
            ('receipt',lambda r:r['copyRetry']['receipts'][0].update(characterCount=14)),
            ('forged-receipt-type',lambda r:r['copyRetry']['receipts'][0].update(characterCount=True)),
            ('pending-not-flushed',lambda r:r['copyRetry']['preRunFrontier'].update(pendingPixelRows=0)),
            ('cropped-output',lambda r:r['copyRetry']['acceptedImageReference'].update(height=1008)),
            ('wrong-output',lambda r:r['copyRetry'].update(generatedActualOutput='ABC-123')),
            ('retained-image',lambda r:r['copyRetry'].update(finalRetainedBytes=1)),
            ('retained-text',lambda r:r['copyRetry'].update(finalRetainedTextBytes=15)),
            ('repeat-render',lambda r:r['copyRetry'].update(textRenderCount=2)),
            ('provider-restarted',lambda r:r['copyRetry'].update(sourceProviderCallsAfterRetry=11)),
            ('owner-retained',lambda r:r['ownership'].update(runner=False)),
            ('early-helper',lambda r:r.update(finalHelperAdmissionOccupied=True)),
            ('source-mutated',lambda r:r['copyRetry'].update(savedDefinitionFrozen=False)),
            ('defaults-mutated',lambda r:r['copyRetry'].update(isolatedDefaultsAfterSHA256='e'*64)),
            ('catalog-mutated',lambda r:r['copyRetry'].update(catalogAfterSHA256='e'*64)),
            ('action-reordered',lambda r:r['copyRetry']['actionTrace'].reverse()),
            ('direct-call',lambda r:r['copyRetry']['actionTrace'][2].update(route='direct method')),
            ('unaccepted-frontier',lambda r:r['copyRetry']['viewportTrace'][-1].update(height=1008)),
            ('no-ocr-binding',lambda r:r['copyRetry'].update(ocrTextBytes=1)),
            ('wrong-ocr-order',lambda r:r['copyRetry'].update(generatedActualOCR='XYZ-987\nABC-123'))]
        for label,mutate in mutations:
            value=report();mutate(value)
            with self.subTest(mutation=label),self.assertRaises(ValueError):C.contract(value,SOURCE)

    def test_every_nested_proof_field_is_required(self):
        paths=[('limits',),('ownership',),('sourceReference',),('copyRetry','preRunFrontier'),
            ('copyRetry','attempts'),('copyRetry','failureAttempts'),('copyRetry','sourceImageComparison'),
            ('copyRetry','acceptedImageReference'),('copyRetry','helperMetrics',0),
            ('copyRetry','helperMetrics',0,'signature'),('copyRetry','actionTrace',0),('copyRetry','viewportTrace',0),
            ('copyRetry','choiceArtifacts',0),('copyRetry','choiceArtifacts',0,'layout'),
            ('copyRetry','choiceArtifacts',0,'layout','controls',0)]
        for path in paths:
            baseline=report()
            for key in path:baseline=baseline[key]
            for omitted in baseline:
                value=report();target=value
                for key in path:target=target[key]
                del target[omitted]
                with self.subTest(path=path,key=omitted),self.assertRaises(ValueError):C.contract(value,SOURCE)


class FileTests(unittest.TestCase):
    def test_standalone_fixture_is_unqualified_checker_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            result=C.validate(fixture(Path(temporary)),SOURCE)
            self.assertEqual(result['status'],'passed')
            for key in ('installerAcceptance','original227MemoryAcceptance','hardMemoryCapClaimed','sourceAndFinalPackageBound','installedIdentityBound'):
                self.assertFalse(result[key])

    def test_installed_source_and_final_package_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof,sources=installed_fixture(Path(temporary))
            result=C.validate(report_path,SOURCE,proof,sources)
            self.assertTrue(result['installedIdentityBound']);self.assertTrue(result['sourceAndFinalPackageBound'])

    def test_missing_raw_file_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary));path=report_path.parent/'scroll-text-script-source.js';path.unlink()
            with self.assertRaisesRegex(ValueError,'missing'):C.validate(report_path,SOURCE)

    def test_every_physical_evidence_file_is_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary))
            for path in sorted(report_path.parent.iterdir()):
                original=path.read_bytes();path.unlink()
                with self.subTest(file=path.name),self.assertRaises(ValueError):C.validate(report_path,SOURCE)
                path.write_bytes(original)

    def test_extra_nested_symlinked_and_hardlinked_files_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary));root=report_path.parent
            extra=root/'unreviewed.json';extra.write_text('{}')
            with self.assertRaisesRegex(ValueError,'unknown physical'):C.validate(report_path,SOURCE)
            extra.unlink();extra.mkdir()
            with self.assertRaisesRegex(ValueError,'unknown physical'):C.validate(report_path,SOURCE)
            extra.rmdir()
            source=root/'scroll-text-script-source.js';data=source.read_bytes();source.unlink()
            source.symlink_to(root/'scroll-text-script-copied.txt')
            with self.assertRaisesRegex(ValueError,'owned regular'):C.validate(report_path,SOURCE)
            source.unlink();source.hardlink_to(root/'scroll-text-script-copied.txt')
            with self.assertRaisesRegex(ValueError,'owned regular'):C.validate(report_path,SOURCE)
            source.unlink();source.write_bytes(data)

    def test_raw_bytes_catalog_case_layout_and_text_are_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary))
            for name in ('scroll-text-script-copied.txt','scroll-text-script-source.js','scroll-text-script-ocr.txt',
                         'scroll-text-script-catalog.json','scroll-text-script-case.json','scroll-text-script-actions.json',
                         'scroll-text-script-choice-light-layout.json','scroll-text-script-result-dark.png'):
                path=report_path.parent/name;original=path.read_bytes();path.write_bytes(original+b'corrupt')
                with self.subTest(file=name),self.assertRaises((ValueError,json.JSONDecodeError)):C.validate(report_path,SOURCE)
                path.write_bytes(original)

    def test_full_frontier_raw_pixel_comparison(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary));value=json.loads(report_path.read_text())
            for height in (C.HEIGHT,1008):
                changed,_=T.T.png(C.WIDTH,height,(31,42,53,255))
                (report_path.parent/'scroll-text-script-accepted.png').write_bytes(changed)
                value['copyRetry']['acceptedPNGFileSHA256']=sha(changed);dump(report_path,value)
                with self.subTest(height=height),self.assertRaisesRegex(ValueError,'full final frontier pixels'):
                    C.validate(report_path,SOURCE)

    def test_raw_child_outer_launcher_and_source_cannot_diverge(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof,sources=installed_fixture(Path(temporary))
            launch_path=report_path.with_name(report_path.name+'.launcher.json')
            original=json.loads(launch_path.read_text())
            for key,bad in [('ownedExitConfirmed',False),('textScriptDiagnosticOnly',False),('timeoutSeconds',45),
                            ('selectedAppPath','/wrong/PicShot.app'),('launchedExecutablePath','/wrong/PicShot'),
                            ('unexpectedClaim',True)]:
                value=copy.deepcopy(original);value[key]=bad;dump(launch_path,value)
                with self.subTest(key=key),self.assertRaises(ValueError):C.validate(report_path,SOURCE,proof,sources)
            dump(launch_path,original)
            child=report_path.parent/'current-long-image'/C.RAW_NAME
            value=json.loads(child.read_text());value['elapsedSeconds']=11.;dump(child,value)
            with self.assertRaisesRegex(ValueError,'raw child'):C.validate(report_path,SOURCE,proof,sources)
            value['elapsedSeconds']=10.;dump(child,value)
            target=sources/'Sources/PicShot/LiveScrollTextDependencies.swift';target.write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError,'source bytes changed'):C.validate(report_path,SOURCE,proof,sources)

    def test_new_helper_signature_is_bound_to_package(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path,proof,sources=installed_fixture(Path(temporary))
            child=report_path.parent/'current-long-image'/C.RAW_NAME
            value=json.loads(child.read_text());value['copyRetry']['helperMetrics'][0]['signature']['helperCDHash']='e'*40
            dump(child,value)
            for path in (report_path,report_path.parent/'text-script-demo.json'):
                wrapper=json.loads(path.read_text());wrapper['currentLongImage']=value;dump(path,wrapper)
            with self.assertRaisesRegex(ValueError,'runtime helper bound to package'):C.validate(report_path,SOURCE,proof,sources)

    def test_optional_identity_parameters_are_a_pair(self):
        for proof,root in ((Path('/unused'),None),(None,Path('/unused'))):
            with self.assertRaisesRegex(ValueError,'required together'):C.validate(Path('/unused'),SOURCE,proof,root)

    def test_source_and_png_alpha_corruption(self):
        for bad in (b'not a PNG',SOURCE_PNG[:-1],SOURCE_PNG+b'junk'):
            with self.assertRaises(ValueError):C.png(bad,'corrupt')
        translucent,_=T.T.png(2,2,(120,80,40,128))
        with self.assertRaisesRegex(ValueError,'not opaque'):C.png(translucent,'source')
        image=C.png(translucent,'UI',ui=True)
        self.assertEqual(image,(2,2,bytes((60,40,20,128))*4))

    def test_unsupported_png_semantics_and_crc_fail(self):
        tiny,_=T.T.png(2,2,(31,42,53,255))
        corrupt=bytearray(tiny);corrupt[-1]^=1
        with self.assertRaisesRegex(ValueError,'CRC'):C.png(bytes(corrupt),'CRC')
        for kind,payload in ((b'tRNS',b'\0'*6),(b'acTL',b'\0'*8),(b'ABCD',b'')):
            chunk=struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',zlib.crc32(kind+payload)&0xffffffff)
            with self.subTest(kind=kind),self.assertRaises(ValueError):C.png(tiny[:33]+chunk+tiny[33:],'unsupported')
        header=bytearray(tiny[16:29]);header[8]=16
        modified=tiny[:16]+bytes(header)+struct.pack('>I',zlib.crc32(b'IHDR'+header)&0xffffffff)+tiny[33:]
        with self.assertRaisesRegex(ValueError,'unsupported PNG format'):C.png(modified,'depth')

    def test_duplicate_and_nonfinite_json_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/C.RAW_NAME
            for invalid in ('{"schemaVersion":1,"schemaVersion":1}', '{"elapsedSeconds":NaN}', '{"elapsedSeconds":Infinity}'):
                path.write_text(invalid)
                with self.subTest(json=invalid),self.assertRaises(ValueError):C.validate(path,SOURCE)

    def test_cli_normal_and_optimized(self):
        with tempfile.TemporaryDirectory() as temporary:
            report_path=fixture(Path(temporary))
            for mode in ([],['-O']):
                good=subprocess.run([sys.executable,*mode,str(SCRIPTS/'check-live-scroll-text-script-demo.py'),'--report',str(report_path),'--source',SOURCE],capture_output=True,text=True)
                self.assertEqual(good.returncode,0,good.stderr)
                result=json.loads((report_path.parent/C.RECEIPT_NAME).read_text());self.assertFalse(result['installedIdentityBound'])
                bad=subprocess.run([sys.executable,*mode,str(SCRIPTS/'check-live-scroll-text-script-demo.py'),'--report',str(report_path),'--source','b'*40],capture_output=True,text=True)
                self.assertNotEqual(bad.returncode,0)


if __name__=='__main__':unittest.main()
