"""Fabricated schema tests only. No test here is macOS/native memory evidence."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('manual_resource_check', Path(__file__).resolve().parents[1]/'check-scroll-manual-resource-report.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
COMMIT = 'a'*40


def mem(index):
    return dict(residentBytes=10_000_000+index*1000, physicalFootprintBytes=8_000_000+index*700)


def stats():
    return dict(residentSampleCount=30, physicalFootprintSampleCount=30, failedResidentSampleCount=0,
                failedPhysicalFootprintSampleCount=0, timerTickCount=20, boundarySampleCount=10,
                peakResidentBytes=20_000_000, peakPhysicalFootprintBytes=15_000_000)


def functional():
    axes = []
    for axis in ('vertical', 'horizontal'):
        row = dict(axis=axis)
        for field in ('stableCapture', 'stationarySuppressed', 'pauseDrains', 'resumeWithoutCountdown',
                      'fixedRegionMovePreservesBytes', 'uncertainSeamRejected', 'retryKeepsAnchor', 'exactPixels', 'closeReleases'):
            row[field] = True
        axes.append(row)
    return dict(status='passed', sourceCommit=COMMIT, screenCaptureStarted=False, accessibilityRequested=False,
                permissionRequested=False, systemInputEventsPosted=0, acceptedSourcesImmutable=True,
                regionMoveNativeEvents=True, lateCaptureClose=True, colorDigest=True, axes=axes,
                lateWritePauseStopClose=[dict(action=action, uncommittedPNGRemoved=True, lateCommitRejected=True)
                                        for action in ('pause', 'stop', 'close')])


def cycle(profile, index, phase):
    name, width, height, axis = profile
    step = (height if axis == 'vertical' else width)//4
    output_width = width+(3*step if axis == 'horizontal' else 0)
    output_height = height+(3*step if axis == 'vertical' else 0)
    sources = [dict(name=f'frame-{i}.png', bytes=1000+i, sha256=hashlib.sha256(str(i).encode()).hexdigest()) for i in range(4)]
    preview = dict(outputWidth=output_width, outputHeight=output_height, zoom=4.0, displayScale=0.5,
                   visibleRect=[0.0,0.0,100.0,100.0], latestOutputRanges=[[3*step,3*step+(height if axis=='vertical' else width)]],
                   tileWidth=50, tileHeight=50, activeJobs=0, pendingJobs=0, cachedTiles=1, sourceReferences=4,
                   resolutionLabel='Sampled detail, sources at most 2048 px')
    end = copy.deepcopy(preview)
    end['visibleRect'] = [float(output_width-100),float(output_height-100),100.0,100.0]
    peaks = dict(fixtureViewportRasters=1, fixtureViewportPixels=width*height,
                 pendingCaptureRasters=1, pendingCapturePixels=width*height, captureRunners=1,
                 providerCalls=1, acceptedSources=4, acceptedGrayPixels=width*height,
                 overviewPixels=800*450, previewTilePixels=2500, previewCachedTiles=1,
                 previewActiveJobs=1, previewPendingJobs=1, previewSourceReferences=4,
                 temporaryDiskBytes=sum(item['bytes'] for item in sources))
    row = dict(index=index, phase=phase, profile=name, axis=axis, width=width, height=height,
               framePixels=width*height, rgbaBytesPerViewport=width*height*4, elapsedSeconds=2.0,
               captures=13, sampledFrames=13, acceptedFrames=4, verifiedSpoolBytes=sum(item['bytes'] for item in sources),
               providerPeakActiveCalls=1, lateCaptureIncrements=0, sourceBytesBefore=sources,
               sourceBytesAfter=copy.deepcopy(sources), preview=dict(beginning=preview,end=end),
               observedPeaks=peaks, ownershipSamples=50, resetState={key:0 for key in CHECK.RESET_FIELDS},
               closedState={key:0 for key in CHECK.CLOSED_FIELDS}, before=mem(index),
               settledAfterClose=mem(index+1), sampledMemory=stats())
    row.update({key:True for key in CHECK.TRUE_CYCLE_FIELDS})
    return row


def report(app, executable):
    warmups = [cycle(CHECK.PROFILES[i%4],i+1,'warmup') for i in range(8)]
    cycles = [cycle(CHECK.PROFILES[i%4],i+1,'measured') for i in range(16)]
    value = dict(schemaVersion=1,status='passed',sourceCommit=COMMIT,version='0.14.0',buildVersion='140',
                 bundlePath=str(app),processIdentifier=123,architecture='arm64',buildMode='release',
                 warmupCycles=8,measuredCycles=16,acceptedFramesPerCycle=4,overallDeadlineSeconds=240,
                 sampleIntervalSeconds=0.05,settlingDelaySeconds=0.15,workload='direct setup with real production pipeline',
                 fullOutputRastersInResourceLoop=0,giantMasterPageRasters=0,memoryIsObservational=True,
                 memoryScope='Main process sampled RSS and footprint, excluding GPU and WindowServer',
                 backingCaveat='ImageIO volatile backing may survive; injected viewports omit production full-display backing',
                 ownershipScope='One source raster and sampled pipeline references, excluding transient decoder allocations',
                 limits=copy.deepcopy(CHECK.LIMITS),executableSHA256=hashlib.sha256(executable).hexdigest(),
                 functionalReportSHA256=hashlib.sha256(json.dumps(functional(),sort_keys=True).encode()).hexdigest(),
                 beforeWarmup=mem(0),warmups=warmups,warmupSampledMemory=stats(),baselineAfterWarmup=mem(1),
                 cycles=cycles,sampledMemory=stats(),finalAfterCleanup=mem(18),profileMemory=[],
                 completedWarmupCycles=8,completedMeasuredCycles=16,observationsComplete=True,elapsedSeconds=60.0)
    value.update({key:False for key in CHECK.FALSE_FIELDS})
    for field,prefix,_ in CHECK.MEMORY_FIELDS:
        points = [row['settledAfterClose'][field] for row in cycles]
        value[prefix+'GrowthFromWarmupBytes']=points[-1]-value['baselineAfterWarmup'][field]
        value[prefix+'EveryIntervalGrowthBytes']=[b-a for a,b in zip(points,points[1:])]
        value[prefix+'LateThreeIntervalGrowthBytes']=[points[i]-points[i-1] for i in range(13,16)]
        value[prefix+'CleanupDeltaBytes']=value['finalAfterCleanup'][field]-points[-1]
    for i,profile in enumerate(CHECK.PROFILES):
        indices=[i+1+4*r for r in range(4)]
        points=[cycles[index-1]['settledAfterClose'] for index in indices]
        row=dict(profile=profile[0],cycleIndices=indices,settledAfterCycles=points)
        for field,prefix,_ in CHECK.MEMORY_FIELDS:
            row[prefix+'LateThreeIntervalGrowthBytes']=[b[field]-a[field] for a,b in zip(points,points[1:])]
        value['profileMemory'].append(row)
    return value


class ResourceReportTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.app=self.root/'PicShot.app'
        (self.app/'Contents/MacOS').mkdir(parents=True)
        self.executable=b'fake executable for schema tests only, never native evidence'
        (self.app/'Contents/MacOS/PicShot').write_bytes(self.executable)
        self.plist=dict(PicShotSourceCommit=COMMIT,CFBundleShortVersionString='0.14.0',CFBundleVersion='140',CFBundleExecutable='PicShot')
        self.write_plist()
        self.report=report(self.app,self.executable)
        self.functional=functional()

    def write_plist(self):
        (self.app/'Contents/Info.plist').write_bytes(plistlib.dumps(self.plist))

    def validate(self):
        CHECK.validate(self.report,expected_commit=COMMIT,expected_version='0.14.0',expected_build='140',
                       installed_app=self.app,functional_report=self.functional,
                       functional_report_sha256=hashlib.sha256(json.dumps(self.functional,sort_keys=True).encode()).hexdigest())

    def rebind_functional(self):
        self.report["functionalReportSHA256"]=hashlib.sha256(json.dumps(self.functional,sort_keys=True).encode()).hexdigest()

    def reject(self):
        with self.assertRaises((ValueError,KeyError,TypeError,OSError)):
            self.validate()

    def test_complete_schema_passes_without_plateau_claim(self):
        self.validate()
        self.assertGreater(self.report['residentLateThreeIntervalGrowthBytes'][-1],0)
        self.assertFalse(self.report['stabilityAssessed'])

    def test_every_required_cycle_assertion_fails_closed(self):
        for field in CHECK.TRUE_CYCLE_FIELDS:
            with self.subTest(field=field):
                self.report['cycles'][0][field]=False
                self.reject()
                self.report['cycles'][0][field]=True

    def test_boolean_is_not_an_integer(self):
        self.report['cycles'][0]['providerPeakActiveCalls']=True
        self.reject()

    def test_unknown_fields_are_rejected(self):
        self.report['zeroLeaksProven']=True
        self.reject()

    def test_missing_or_duplicate_profile_cycles_rejected(self):
        self.report['cycles'][1]=copy.deepcopy(self.report['cycles'][0])
        self.reject()

    def test_source_commit_mismatch_rejected(self):
        self.report['sourceCommit']='b'*40
        self.reject()

    def test_actual_bundle_plist_mismatch_rejected(self):
        self.plist['PicShotSourceCommit']='b'*40
        self.write_plist()
        self.reject()

    def test_actual_executable_changed_rejected(self):
        (self.app/'Contents/MacOS/PicShot').write_bytes(b'changed')
        self.reject()

    def test_bundle_path_mismatch_rejected(self):
        self.report['bundlePath']=str(self.root)
        self.reject()

    def test_executable_path_escape_rejected(self):
        self.plist['CFBundleExecutable']='../../outside'
        self.write_plist()
        self.reject()

    def test_executable_symlink_escape_rejected(self):
        outside=self.root/'outside'
        outside.write_bytes(self.executable)
        executable=self.app/'Contents/MacOS/PicShot'
        executable.unlink(); executable.symlink_to(outside)
        self.reject()

    def test_debug_workload_rejected(self):
        self.report['buildMode']='debug'
        self.reject()

    def test_reduced_heavy_workload_rejected(self):
        self.report['measuredCycles']=8
        self.reject()

    def test_memory_sample_failures_rejected(self):
        self.report['cycles'][0]['sampledMemory']['failedPhysicalFootprintSampleCount']=1
        self.reject()

    def test_timer_counts_mismatch_rejected(self):
        self.report['sampledMemory']['timerTickCount']+=1
        self.reject()

    def test_no_timer_samples_rejected(self):
        self.report['sampledMemory']['timerTickCount']=0
        self.reject()

    def test_missing_settled_endpoint_rejected(self):
        del self.report['cycles'][3]['settledAfterClose']['physicalFootprintBytes']
        self.reject()

    def test_late_increment_forgery_rejected(self):
        self.report['residentLateThreeIntervalGrowthBytes'][-1]=0
        self.reject()

    def test_same_profile_increment_forgery_rejected(self):
        self.report['profileMemory'][0]['residentLateThreeIntervalGrowthBytes'][-1]=0
        self.reject()

    def test_profile_endpoint_reassignment_rejected(self):
        self.report['profileMemory'][0]['cycleIndices']=[1,2,3,4]
        self.reject()

    def test_source_bytes_mutation_rejected(self):
        self.report['cycles'][0]['sourceBytesAfter'][0]['sha256']='f'*64
        self.reject()

    def test_unsafe_source_filename_rejected(self):
        for key in ('sourceBytesBefore','sourceBytesAfter'):
            self.report['cycles'][0][key][0]['name']='../frame.png'
        self.reject()

    def test_duplicate_source_identity_rejected(self):
        for key in ('sourceBytesBefore','sourceBytesAfter'):
            self.report['cycles'][0][key][1]=copy.deepcopy(self.report['cycles'][0][key][0])
        self.reject()

    def test_disk_accounting_mismatch_rejected(self):
        self.report['cycles'][0]['verifiedSpoolBytes']+=1
        self.reject()

    def test_live_objects_at_reset_or_close_rejected(self):
        for state,field in [('resetState','previewActiveJobs'),('resetState','fixtureViewportRasters'),('closedState','drivers'),('closedState','spoolDirectories')]:
            with self.subTest(state=state,field=field):
                self.report['cycles'][0][state][field]=1
                self.reject()
                self.report['cycles'][0][state][field]=0

    def test_late_sampling_rejected(self):
        self.report['cycles'][0]['lateCaptureIncrements']=1
        self.reject()

    def test_multiple_provider_calls_rejected(self):
        self.report['cycles'][0]['observedPeaks']['providerCalls']=2
        self.reject()

    def test_unbounded_preview_rejected(self):
        self.report['cycles'][0]['preview']['end']['tileWidth']=1025
        self.reject()

    def test_preview_extent_and_latest_range_forgery_rejected(self):
        self.report['cycles'][0]['preview']['end']['latestOutputRanges'][0][0]+=1
        self.reject()

    def test_preview_must_navigate(self):
        self.report['cycles'][0]['preview']['end']=copy.deepcopy(self.report['cycles'][0]['preview']['beginning'])
        self.reject()

    def test_native_functional_proof_required(self):
        self.functional['regionMoveNativeEvents']=False
        self.rebind_functional()
        self.reject()

    def test_functional_commit_mismatch_rejected(self):
        self.functional['sourceCommit']='b'*40
        self.rebind_functional()
        self.reject()

    def test_actual_functional_report_hash_mismatch_rejected(self):
        self.report["functionalReportSHA256"]="f"*64
        self.reject()

    def test_late_write_proof_required(self):
        self.functional['lateWritePauseStopClose'][0]['lateCommitRejected']=False
        self.rebind_functional()
        self.reject()

    def test_deadline_not_relaxed(self):
        self.report['overallDeadlineSeconds']=600
        self.reject()

    def test_nonfinite_memory_rejected(self):
        self.report['cycles'][0]['settledAfterClose']['residentBytes']=float('nan')
        self.reject()

    def test_unsupported_claim_rejected(self):
        self.report['stabilityAssessed']=True
        self.reject()

    def test_backing_caveat_required(self):
        self.report['backingCaveat']='Everything released'
        self.reject()

    def test_duplicate_json_key_rejected(self):
        path=self.root/'duplicate.json'
        path.write_text('{"status":"failed","status":"passed"}')
        with self.assertRaises(ValueError): CHECK.read_json(path)

    def test_nonfinite_json_rejected(self):
        path=self.root/'nan.json'
        path.write_text('{"memory":NaN}')
        with self.assertRaises(ValueError): CHECK.read_json(path)

    def test_oversized_json_rejected(self):
        path=self.root/'large.json'
        path.write_bytes(b' '* (CHECK.MAX_REPORT_BYTES+1))
        with self.assertRaises(ValueError): CHECK.read_json(path)

    def test_report_symlink_rejected(self):
        path=self.root/'report.json'; path.write_text('{}')
        link=self.root/'link.json'; link.symlink_to(path)
        with self.assertRaises(ValueError): CHECK.read_json(link)

    def test_boolean_delta_rejected_even_when_numerically_equal(self):
        self.report['residentCleanupDeltaBytes']=True
        self.reject()


if __name__=='__main__':
    unittest.main()
