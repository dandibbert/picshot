"""Synthetic contract/adversarial tests. Never native product evidence."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value


P = module('product_test_checker', SCRIPTS / 'check-editable-product-resource.py')
C = module('product_component_test_fixture', SCRIPTS / 'tests/test_check_editable_components.py')
D = module('product_drawing_test_fixture', SCRIPTS / 'tests/test_check_editable_drawing_pair.py')
R = module('product_renderer_test_fixture', SCRIPTS / 'tests/test_check_renderer_storage_pair.py')
REJECTED = (ValueError, TypeError, KeyError, OSError)


def docs(date=800000001):
    source = P.recipe()
    def restore(value):
        if isinstance(value, str) and value.startswith('fixture-uuid-'):
            return str(uuid.UUID(int=int(value[13:]) + 100))
        if value == 'bounded-session-date': return date
        if type(value) is dict: return {key: restore(child) for key, child in value.items()}
        if type(value) is list: return [restore(child) for child in value]
        return value
    return restore(source['seven']), restore(source['eight'])


def owner(released=True):
    return dict(created=16, aliveNonWindowObjects=0 if released else 3, liveEditors=0 if released else 1,
                livePins=0, attachedWindowGraphs=0 if released else 1, retainedWindowShells=0)


def state(phase='cycle-released', strategy='reference'):
    app, pin, editor = P.LIVE_COUNTS[phase]
    roles = []
    if app or editor: roles += ['editor-original', 'editor-base']
    if pin: roles += ['pin-original', 'pin-current']
    if phase == 'annotations-hidden': roles += ['pin-hidden-preview']
    rows, seen = [], set()
    for role in roles:
        w, h = (2414, 1574) if role in ('pin-current', 'pin-hidden-preview') else (3840, 2160)
        ident = 'original-shared' if role.endswith('-original') else role
        rows.append(dict(role=role, identity=ident, width=w, height=h, bytesPerRow=w*4,
            knownBytes=w*h*4, firstIdentityOccurrence=ident not in seen)); seen.add(ident)
    return dict(appEditorCount=app, pinCount=pin, pinEditorCount=editor,
        knownRasters=rows, knownUniqueRasterBytes=sum(r['knownBytes'] for r in rows if r['firstIdentityOccurrence']),
        rasterIdentityScope='synthetic scalar census', editorAdmissionEstimateBytes=0, pinAdmissionEstimateBytes=0,
        undoRasterIdentities=0, hiddenPreviewCount=int(phase == 'annotations-hidden'), retainedEditableBaseCount=0,
        projectionBusy=False, projectionReservedBytes=0, projectionQueueOperations=0, projectionStarted=0,
        projectionCompleted=0, exportSessions=0, exportQueueOperations=0, pinThumbnailCacheBytes=0,
        pinThumbnailCacheCount=0, historyThumbnailRequests=0, historyThumbnailCacheLimitBytes=24*1024*1024,
        historyThumbnailCacheObservedBytes=None, ownedOpenDescriptors=0,
        fixedRunOwners=dict(appDelegate=1, historyStore=1, pinSessionCoordinator=1, pinSessionStore=1),
        drawing=D.state(strategy), rendererStorage=R.state('native'))


def cycles(strategy='reference'):
    report = dict(cycles=[], actions=[], checkpoints=[], phaseTimings=[], beforeWarmup=C.memory(99),
                  completedWarmupCycles=2, completedMeasuredCycles=8)
    for ordinal in range(1, 11):
        start, end = 100 + (ordinal-1)*3, 102 + (ordinal-1)*3
        row = dict(ordinal=ordinal, warmup=ordinal <= 2, cold=ordinal == 1,
            beforeMemory=C.memory(start), afterMemory=C.memory(end), deltaBytes=dict.fromkeys(P.C.MEMORY, 0), elapsedSeconds=2,
            historyID=str(uuid.UUID(int=ordinal+1000)), pinID=str(uuid.UUID(int=ordinal+2000)),
            actionRange=[(ordinal-1)*len(P.ACTIONS), ordinal*len(P.ACTIONS)], stageRange=[(ordinal-1)*4, ordinal*4],
            afterReleaseState=state(strategy=strategy), ownershipAfterRelease=owner(), assertions=dict.fromkeys(P.ASSERTIONS, True))
        report['cycles'].append(row)
        for index, phase in enumerate(P.SAMPLE_PHASES):
            begin=start+index*.25;finish=start+(index+1)*.25 if index<6 else end
            report['phaseTimings'].append(dict(cycle=ordinal,phase=phase,startUptimeSeconds=begin,
                endUptimeSeconds=finish,elapsedSeconds=finish-begin))
        for index, name in enumerate(P.ACTIONS):
            begin = start + index*.05
            report['actions'].append(dict(cycle=ordinal, name=name, startUptimeSeconds=begin,
                                         endUptimeSeconds=begin+.025, elapsedSeconds=.025))
        for index, phase in enumerate(P.CHECKPOINTS):
            report['checkpoints'].append(dict(cycle=ordinal, phase=phase, memory=C.memory(start+index*.1),
                                             state=state(phase, strategy), ownership=owner()))
    report.update(afterWarmupBaseline=report['cycles'][1]['afterMemory'], afterMeasuredCycles=report['cycles'][-1]['afterMemory'],
        warmupDeltaBytes=dict.fromkeys(P.C.MEMORY, 0), afterWarmupToMeasuredDeltaBytes=dict.fromkeys(P.C.MEMORY, 0),
        lateMeasuredIncrements=[dict.fromkeys(P.C.MEMORY, 0) for _ in range(3)])
    return report


def stored_workflow(root):
    """Real bounded byte files, synthetic PNG payloads; pixel decode is separate."""
    report=cycles();report['sessionDateBounds']={'start':800000000,'end':800000300}
    report['stages']=[];seen={};seed,_=docs();copies=[]
    def saved(data,name,ordinal):
        digest=P.C.digest(data);suffix=name.split('.')[-1]
        relative=f'artifacts/blobs/{digest}.{suffix}';path=root/relative
        duplicate=relative in seen
        if not duplicate:path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data);seen[relative]=len(data)
        memory={'uptimeSeconds':100+(ordinal-1)*3+.1,'counters':C.memory()['counters']}
        row=dict(sourceFilename=name,evidenceFilename=relative,byteCount=len(data),sha256=digest,
            copySeconds=.01,memoryBefore=memory,memoryAfter=memory,streamedBytes=len(data),deduplicated=duplicate)
        copies.append(row);return row
    for ordinal in range(1,11):
        for label in P.STAGES:
            expected='eight' if label in ('pin-after-apply','pin-closed') else 'seven'
            doc=copy.deepcopy(seed)
            if expected=='eight':
                _,doc=docs(800000000+ordinal)
                doc['annotations'][7]['id']=str(uuid.UUID(int=4000+ordinal))
            uid=lambda slot:str(uuid.UUID(int=ordinal*100+10000+slot))
            store='history' if label=='history-save' else 'pin'
            filenames={role:uid((1 if store=='history' else 10)+index)+'.png' for index,role in enumerate(('original','base','current'))}
            if expected=='eight':filenames['base']=uid(30)+'.png';filenames['current']=uid(31)+'.png'
            descriptor={};raster_data=[]
            doc_filename=uid(50 if expected=='seven' else 51)+'.annotations'
            doc_bytes=json.dumps(doc,sort_keys=True,separators=(',',':')).encode()
            for index,role in enumerate(('original','base','current')):
                state_key=expected if role=='current' else role;w,h=P.DIMENSIONS[state_key]
                data=('synthetic PNG '+state_key).encode()
                aid=doc[role+'AssetID'] if role!='current' else uid(70 if expected=='seven' else 71)
                descriptor[role]=dict(filename=filenames[role],width=w,height=h,byteCount=len(data),sha256=P.C.digest(data),assetID=aid)
                raster_data.append((data,role,state_key,aid,w,h))
            descriptor.update(documentFilename=doc_filename,documentByteCount=len(doc_bytes),documentSHA256=P.C.digest(doc_bytes))
            record_id=report['cycles'][ordinal-1]['historyID' if store=='history' else 'pinID']
            if store=='history':
                current=descriptor['current']
                index_value=[dict(id=record_id,createdAt=800000000+ordinal,title='编辑 · 00:00',text='',starred=False,
                    filename=current['filename'],width=current['width'],height=current['height'],byteCount=current['byteCount'],editableCapture=descriptor)]
            else:
                projection=lambda role:{k:v for k,v in descriptor[role].items() if k!='assetID'}
                group='00000000-0000-0000-0000-000000000001'
                record=dict(id=record_id,groupID=group,title='贴图',createdAt=800000000+ordinal,updatedAt=800000000+ordinal,
                    original=projection('original'),current=projection('current'),editableCapture=descriptor,
                    presentation=dict(frame=dict(x=80,y=80,width=680,height=480),opacity=1,clickThrough=False,locked=False),
                    isVisible=label!='pin-closed')
                if label=='pin-closed':record['archiveSequence']=1
                index_value=dict(version=3,activeGroupID=group,allHidden=False,
                    groups=[dict(id=group,name='默认',color='gray',isHidden=False,isProtected=False)],entries=[record])
            index_row=saved(json.dumps(index_value,sort_keys=True).encode(),'index.json',ordinal)
            doc_row=saved(doc_bytes,doc_filename,ordinal)
            raster_rows=[]
            for data,role,state_key,aid,w,h in raster_data:
                row=saved(data,filenames[role],ordinal);row.update(role=role,expectedState=state_key,assetID=aid,width=w,height=h)
                raster_rows.append(row)
            report['stages'].append(dict(cycle=ordinal,stage=label,id=f'{ordinal}-{label}',store=store,recordID=record_id,
                expectedState=expected,index=index_row,document=doc_row,rasters=raster_rows))
    report['evidenceCopies']=dict(sourceFiles=200,streamedBytes=sum(r['byteCount'] for r in copies),uniqueFiles=len(seen),
        uniqueBytes=sum(seen.values()),copySeconds=sum(r['copySeconds'] for r in copies),bufferBytes=65536,
        maximumSourceFiles=256,maximumUniqueFiles=256,maximumUniqueBytes=P.MAX_ARTIFACT_BYTES,maximumStreamedBytes=2147483648,
        excludedFromProcessMemory=False,rasterDecodeCount=0,rasterNormalizationCount=0)
    return report,seed,{role:root/(role+'.rgba') for role in P.GOLDEN}


class ProductEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_audited_full_document_recipe_accepts_only_narrow_identity_and_date_changes(self):
        seven, eight = docs()
        bounds = {'start': 800000000, 'end': 800000002}
        P.check_recipe(seven, eight, bounds)
        self.assertEqual(P.GOLDEN['eight'], '901d625dd2b57188f0d6228ab9ecfbdc1ceee7d2e297d85d42a03bcdf751f621')
        mutations = [
            lambda a,b: b['annotations'][7].update(frozenTimestamp=800000003),
            lambda a,b: b['annotations'][7].update(id=a['annotations'][0]['id']),
            lambda a,b: b['annotations'][0].update(frozenTimestamp=-978307199),
            lambda a,b: b.update(capturedAt=800000001),
            lambda a,b: b.update(captureTimeZoneIdentifier='GMT'),
            lambda a,b: b['annotations'][7].update(frozenTimeZoneIdentifier='GMT'),
            lambda a,b: b['annotations'][7].update(lineWidth=True),
            lambda a,b: b['annotations'][7].update(lineWidth=5),
            lambda a,b: b['annotations'][7].update(unknownMetadata=123),
            lambda a,b: b['annotations'][6]['mosaicLink'].update(rootAdditionID=a['annotations'][6]['mosaicLink']['groupID']),
            lambda a,b: b['annotations'][7]['points'][1].__setitem__(1, 1550.4),
            lambda a,b: b.update(baseAssetID=a['originalAssetID']),
            lambda a,b: b['outputDecoration'].update(shadowOpacity=.2),
            lambda a,b: b['annotations'].reverse(),
            lambda a,b: b['annotations'].pop(),
        ]
        for mutation in mutations:
            a,b = copy.deepcopy(seven), copy.deepcopy(eight); mutation(a,b)
            with self.subTest(mutation=mutation), self.assertRaises(REJECTED): P.check_recipe(a,b,bounds)

    def test_json_duplicate_nonfinite_overflow_and_boolean_counts_reject(self):
        for data in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":Infinity}', b'{"a":1e9999}'):
            path=self.root/'bad.json'; path.write_bytes(data)
            with self.subTest(data=data), self.assertRaises(REJECTED): P.load(path)
        for value in (True, False, -1, 2**64, 1.5):
            with self.assertRaises(REJECTED): P.integer(value)

    def test_unsafe_regular_files_symlinks_hardlinks_and_bounds_reject(self):
        path=self.root/'owned'; path.write_bytes(b'bounded')
        self.assertEqual(P.read(path, 7), b'bounded')
        with self.assertRaises(REJECTED): P.read(path, 6)
        link=self.root/'symlink'; link.symlink_to(path)
        with self.assertRaises(REJECTED): P.read(link, 7)
        hard=self.root/'hard'; os.link(path, hard)
        with self.assertRaises(REJECTED): P.read(hard, 7)
        hard.unlink()
        with self.assertRaises(REJECTED): P.read(self.root, 7)
        empty=self.root/'empty';empty.write_bytes(b'')
        with self.assertRaises(REJECTED): P.read(empty, 7)
        fifo=self.root/'fifo';os.mkfifo(fifo)
        with self.assertRaises(REJECTED): P.read(fifo, 7)

    def test_all_two_plus_eight_actions_and_lifecycle_states_in_both_finite_cells(self):
        for strategy in P.CELL_STRATEGIES.values():
            value=cycles(strategy);P.cycles(value,strategy)
            self.assertEqual(len(value['actions']), 170);self.assertEqual(len(value['checkpoints']), 130)
        mutations = [
            lambda v: v['cycles'].pop(), lambda v: v['cycles'].reverse(),
            lambda v: v['cycles'][0].update(ordinal=True), lambda v:v['cycles'][0].update(cold=False),
            lambda v:v.update(completedWarmupCycles=1), lambda v:v['actions'].pop(),
            lambda v:v['actions'][0].update(name='native-pin'),
            lambda v:v['actions'][0].update(startUptimeSeconds=0),
            lambda v:v['actions'][0].update(elapsedSeconds=1),
            lambda v:v['checkpoints'][0]['state'].update(appEditorCount=500),
            lambda v:v['checkpoints'][0]['state'].update(projectionBusy=True),
            lambda v:v['checkpoints'][0]['state'].update(ownedOpenDescriptors=1),
            lambda v:v['checkpoints'][0]['state'].update(undoRasterIdentities=2),
            lambda v:v['checkpoints'][0]['state']['knownRasters'][0].update(width=200),
            lambda v:v['checkpoints'][10]['state']['knownRasters'][2].update(identity='not-shared',firstIdentityOccurrence=True),
            lambda v:v['cycles'][0]['afterReleaseState'].update(pinCount=1),
            lambda v:v['cycles'][0]['ownershipAfterRelease'].update(liveEditors=1),
            lambda v:v['cycles'][0]['assertions'].update(nativeEditUndo=False),
            lambda v:v['cycles'][0]['deltaBytes'].update(resident_size=1),
            lambda v:v['lateMeasuredIncrements'][0].update(compressed=1),
            lambda v:v['cycles'][0]['beforeMemory']['counters'].pop('purgeable_volatile_pmap'),
            lambda v:v['cycles'][0]['beforeMemory']['backingAccounting']['standard']['bytes'].update(resident_size=5),
            lambda v:v['cycles'][0]['beforeMemory'].update(uptimeSeconds=1000),
            lambda v:v['phaseTimings'].pop(),lambda v:v['phaseTimings'][0].update(phase='release'),
            lambda v:v['phaseTimings'][0].update(elapsedSeconds=100),
            lambda v:v['phaseTimings'][0].update(startUptimeSeconds=0),
        ]
        for mutation in mutations:
            value=cycles();mutation(value)
            with self.subTest(mutation=mutation),self.assertRaises(REJECTED):P.cycles(value)

    def test_copy_file_identity_bounds_and_content_addressing(self):
        data=b'synthetic encoded bytes'; digest=P.C.digest(data)
        path=self.root/f'artifacts/blobs/{digest}.png';path.parent.mkdir(parents=True);path.write_bytes(data)
        m={'uptimeSeconds':100,'counters':C.memory()['counters']}
        row=dict(sourceFilename=str(uuid.UUID(int=17))+'.png', evidenceFilename=str(path.relative_to(self.root)),
            byteCount=len(data),sha256=digest,copySeconds=.01,memoryBefore=m,memoryAfter=m,streamedBytes=len(data),deduplicated=False)
        self.assertEqual(P.file_record(row,self.root),data)
        for key,value in [('byteCount',len(data)-1),('sha256','a'*64),('evidenceFilename','../outside.png'),
                          ('sourceFilename','../bad.png'),('streamedBytes',0),('deduplicated',1),('copySeconds',float('inf'))]:
            bad=copy.deepcopy(row);bad[key]=value
            with self.subTest(key=key),self.assertRaises(REJECTED):P.file_record(bad,self.root)
        path.write_bytes(data+b'append')
        with self.assertRaises(REJECTED):P.file_record(row,self.root)

    def test_sampler_exact_seventy_three_phases_and_eight_counters(self):
        value=C.sampler()
        names={'entry','final-cleanup','run-cleanup'}|{f'cycle-{i}-{s}' for i in range(1,11) for s in P.SAMPLE_PHASES}
        value['phases']={name:C.stats() for name in names}
        for field in ('sampleCount','timerSampleCount'):value['total'][field]=sum(x[field] for x in value['phases'].values())
        P.samples(value,True)
        for mutation in (lambda v:v['phases'].pop('cycle-1-seed'),lambda v:v.update(maximumPhaseAggregates=129),
                         lambda v:v['total']['sampledPeakBytes'].update(compressed=1),
                         lambda v:v['total'].update(timerSampleCount=0),lambda v:v['total']['sampledMinimumBytes'].pop('ledger_purgeable_volatile')):
            bad=copy.deepcopy(value);mutation(bad)
            with self.assertRaises(REJECTED):P.samples(bad,True)

    def test_every_saved_index_document_raster_and_copy_is_bound(self):
        report,seed,goldens=stored_workflow(self.root)
        with mock.patch.object(P.C,'png_metadata',return_value={}):
            plan,counts=P.stages(report,self.root,seed,goldens)
            self.assertEqual(counts['sourceFiles'],200);self.assertEqual(len(plan),4)
            mutations=[lambda r:r['stages'].pop(),lambda r:r['stages'].reverse(),
                lambda r:r['stages'][0].update(recordID=str(uuid.uuid4())),
                lambda r:r['stages'][2].update(expectedState='seven'),
                lambda r:r['stages'][0]['rasters'].reverse(),
                lambda r:r['stages'][0]['rasters'][0].update(assetID=seed['baseAssetID']),
                lambda r:r['stages'][0]['rasters'][0].update(width=True),
                lambda r:r['stages'][0]['rasters'][0].update(expectedState='base'),
                lambda r:r['stages'][0]['document'].update(deduplicated=True),
                lambda r:r['stages'][0]['index'].update(sourceFilename='other.json'),
                lambda r:r['stages'][0]['index'].update(sha256='a'*64),
                lambda r:r['evidenceCopies'].update(sourceFiles=199),
                lambda r:r['evidenceCopies'].update(uniqueBytes=1),
                lambda r:r['evidenceCopies'].update(copySeconds=0),
                lambda r:r['evidenceCopies'].update(bufferBytes=65537),
                lambda r:r['evidenceCopies'].update(excludedFromProcessMemory=True),
                lambda r:r['evidenceCopies'].update(rasterDecodeCount=1)]
            for mutation in mutations:
                bad=copy.deepcopy(report);mutation(bad)
                with self.subTest(mutation=mutation),self.assertRaises(REJECTED):P.stages(bad,self.root,seed,goldens)
            orphan=self.root/'artifacts/blobs/unreported';orphan.write_bytes(b'orphan')
            with self.assertRaises(REJECTED):P.stages(report,self.root,seed,goldens)

    def test_catalog_foreign_ids_immutable_asset_swaps_and_unknown_metadata_reject(self):
        report,seed,_=stored_workflow(self.root);stage=report['stages'][0]
        original=json.loads((self.root/stage['index']['evidenceFilename']).read_bytes())
        P.catalog(json.dumps(original),stage,seed,report['sessionDateBounds'])
        mutations=[lambda r:r[0].update(id=str(uuid.uuid4())),lambda r:r[0].update(unknown=True),
            lambda r:r[0].update(createdAt=0),lambda r:r[0].update(starred=True),
            lambda r:r[0]['editableCapture'].update(documentSHA256='f'*64),
            lambda r:r[0]['editableCapture'].update(original=r[0]['editableCapture']['base']),
            lambda r:r[0]['editableCapture']['current'].update(width=3840)]
        for mutation in mutations:
            bad=copy.deepcopy(original);mutation(bad)
            with self.assertRaises(REJECTED):P.catalog(json.dumps(bad),stage,seed,report['sessionDateBounds'])

    def test_postexit_decoder_plan_executable_pid_full_pixels_and_command_bindings(self):
        directory=self.root/'baseline/verification';directory.mkdir(parents=True)
        exe=str(self.root/'verification/pixel-verifier')
        row=dict(path=str(self.root/'original.png'),encodedBytes=123,encodedSHA256='a'*64,
            goldenPath=str(self.root/'original.rgba'),goldenSHA256=P.GOLDEN['original'],width=3840,height=2160)
        plan=dict(protocol=P.PIXEL_PROTOCOL,measuredProcessIdentifier=101,ownedExitUptimeSeconds=500,
            allMeasuredAppsExitUptimeSeconds=510,rawReportSHA256='b'*64,certificateSHA256='c'*64,
            decoderSourceSHA256='d'*64,decoderExecutableSHA256='e'*64,decoderExecutableBytes=128,
            decoderCompileCommandSHA256='f'*64,files=[row])
        (directory/'pixel-plan.json').write_text(json.dumps(plan))
        report=dict(protocol=P.PIXEL_PROTOCOL,status='verified',processIdentifier=102,startUptimeSeconds=511,
            finishUptimeSeconds=512,memoryComparisonExcluded=True,goldensGenerated=False,
            planSHA256=P.C.digest((directory/'pixel-plan.json').read_bytes()),measuredProcessIdentifier=101,
            executablePath=exe,executableSHA256='e'*64,executableBytes=128,
            files=[{**row,'comparedBytes':3840*2160*4,'rgbaSHA256':P.GOLDEN['original'],
                'exact':True,'comparison':'memcmp/full-premultiplied-sRGB-RGBA8-including-alpha'}])
        command=dict(schema_version=1,status='exited',termination_reason='exited',
            command=[exe,str(directory/'pixel-plan.json'),str(directory/'pixel-report.json')],
            started_at='2026-10-09T02:00:00+00:00',timeout_seconds=300.0,grace_seconds=5.0,max_log_bytes=P.MAX_JSON,
            pid=102,child_returncode=0,exit_code=0,cancel_signal=None,sigterm_sent=False,sigkill_sent=False,
            descendant_cleanup=False,output_bytes=0,log_bytes=0,log_truncated=False,duration_seconds=2.0,
            group_observation=dict(backend='darwin-ps-pgrp',timeout_seconds=.5,count=1,failures=0,total_seconds=.01,
                                   max_seconds=.01,atomic_snapshot=False))
        save=lambda r,c: ((directory/'pixel-report.json').write_text(json.dumps(r)),(directory/'decoder-command.json').write_text(json.dumps(c)))
        save(report,command);result=P.pixels(self.root,'baseline',plan)
        self.assertEqual(result['uniquePNGFilesVerified'],1);self.assertEqual(result['fullRGBABytesCompared'],3840*2160*4)
        mutations=[lambda r,c:r.update(startUptimeSeconds=509),lambda r,c:r.update(processIdentifier=101),
            lambda r,c:r.update(planSHA256='0'*64),lambda r,c:r.update(executableSHA256='0'*64),
            lambda r,c:r.update(executablePath='/tmp/foreign'),lambda r,c:r.update(memoryComparisonExcluded=False),
            lambda r,c:r.update(goldensGenerated=True),lambda r,c:r['files'][0].update(comparedBytes=1),
            lambda r,c:r['files'][0].update(exact=False),lambda r,c:r['files'][0].update(rgbaSHA256='0'*64),
            lambda r,c:r['files'][0].update(goldenSHA256='0'*64),lambda r,c:r['files'].clear(),
            lambda r,c:c.update(pid=103),lambda r,c:c.update(exit_code=True),lambda r,c:c.update(sigkill_sent=True),
            lambda r,c:c.update(child_returncode=1),lambda r,c:c.update(status='timeout'),
            lambda r,c:c.update(timeout_seconds=301),lambda r,c:c['command'].__setitem__(0,'/tmp/foreign')]
        for mutation in mutations:
            r,c=copy.deepcopy(report),copy.deepcopy(command);mutation(r,c);save(r,c)
            with self.subTest(mutation=mutation),self.assertRaises(REJECTED):P.pixels(self.root,'baseline',plan)

    def test_checker_cli_fails_closed_under_normal_and_optimized_python(self):
        for optimized in (False,True):
            out=self.root/('opt.json' if optimized else 'normal.json')
            process=subprocess.run([sys.executable,*(['-O'] if optimized else []),str(SCRIPTS/'check-editable-product-resource.py'),
                '--app',str(self.root/'missing.app'),'--expected-source','a'*40,'--root',str(self.root),
                '--output',str(out)],capture_output=True,text=True,timeout=15)
            self.assertEqual(process.returncode,1,process.stdout+process.stderr)
            report=json.loads(out.read_text());self.assertEqual(report['status'],'failed')
            self.assertFalse(report['memoryStabilityAssessed']);self.assertFalse(report['outputPixelsIndependentlyVerified'])

    def test_postexit_helper_owns_context_through_complete_pixel_comparison(self):
        source=(SCRIPTS/'verify-editable-product-pixels.swift').read_text()
        begin=source.index('let (exact, pixelsHash) = withExtendedLifetime(context)')
        end=source.index('try need(exact && pixelsHash',begin)
        self.assertIn('memcmp(destination',source[begin:end]);self.assertIn('SHA256.hash',source[begin:end])
        for forbidden in ('ImageEditorRenderer','ImageOutputDecorationRenderer','ImageEditorController'):
            self.assertNotIn(forbidden,source)
        self.assertIn('O_NOFOLLOW',source);self.assertIn('65_536',source)
        self.assertIn('began >= (plan["ownedExitUptimeSeconds"]',source)
        self.assertIn('"goldensGenerated": false',source)


if __name__=='__main__':unittest.main()
