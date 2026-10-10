"""Remove only the literal counted opt-in product and early-recording hooks."""

# These ten exact reversals preserve the pre-existing launcher byte hash.
# Do not generalize to regex/block deletion or refresh the historical hashes.
EARLY_RECORDING_LAUNCHER_HOOKS = (
    (
        (
            'import Darwin\n'
        ),
        (
            ''
        ),
    ),
    (
        (
            'let recordingInputExportOnly = ProcessInfo.processInfo.environment["PICSHOT_RECORDING_INPUT_EXPORT_ONLY"] != nil\n'
            'let expectedExecutablePath = appURL.appendingPathComponent("Contents/MacOS/PicShot").resolvingSymlinksInPath().path\n'
        ),
        (
            ''
        ),
    ),
    (
        (
            'if let selector = ProcessInfo.processInfo.environment["PICSHOT_RECORDING_INPUT_EXPORT_ONLY"] {\n'
            '    configuration.environment["PICSHOT_RECORDING_INPUT_EXPORT_ONLY"] = selector\n'
            '}\n'
        ),
        (
            ''
        ),
    ),
    (
        (
            "// The early gate's outer bounded runner may cancel this launcher. LaunchServices\n"
            '// owns a separate app process, so let this existing owner close its exact app.\n'
            'var interruptedSignal: Int32?\n'
            'var interruptionSources: [DispatchSourceSignal] = []\n'
            'if recordingInputExportOnly {\n'
            '    for number in [SIGTERM, SIGINT] {\n'
            '        signal(number, SIG_IGN)\n'
            '        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)\n'
            '        source.setEventHandler { interruptedSignal = number }\n'
            '        source.resume(); interruptionSources.append(source)\n'
            '    }\n'
            '}\n'
            'func launchedIdentityMatches() -> Bool {\n'
            '    launchedBundlePath == appURL.resolvingSymlinksInPath().path && launchedExecutablePath == expectedExecutablePath\n'
            '}\n'
        ),
        (
            ''
        ),
    ),
    (
        (
            '    if recordingInputExportOnly || ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil ||\n'
        ),
        (
            '    if ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil ||\n'
        ),
    ),
    (
        (
            '        if recordingInputExportOnly {\n'
            '            report["earlyWitnessOnly"] = true\n'
            '            report["expectedExecutablePath"] = expectedExecutablePath\n'
            '            report["launchedIdentityMatches"] = launchedIdentityMatches()\n'
            '            if let interruptedSignal { report["interruptedSignal"] = Int(interruptedSignal) }\n'
            '        }\n'
        ),
        (
            ''
        ),
    ),
    (
        (
            'while Date() < deadline && interruptedSignal == nil {\n'
        ),
        (
            'while Date() < deadline {\n'
        ),
    ),
    (
        (
            '        if recordingInputExportOnly && !launchedIdentityMatches() {\n'
            '            fputs("LaunchServices returned a different installed bundle or executable\\n", stderr)\n'
            '            finish(1, "identity-mismatch")\n'
            '        }\n'
        ),
        (
            ''
        ),
    ),
    (
        (
            'fputs(interruptedSignal == nil ? "LaunchServices smoke app did not terminate within \\(Int(timeout)) seconds\\n" : "Early recording witness launch interrupted\\n", stderr)\n'
            'if let launched, !launched.isTerminated, !recordingInputExportOnly || launchedIdentityMatches() {\n'
        ),
        (
            'fputs("LaunchServices smoke app did not terminate within \\(Int(timeout)) seconds\\n", stderr)\n'
            'if let launched, !launched.isTerminated {\n'
        ),
    ),
    (
        (
            'finish(1, interruptedSignal == nil ? "timed-out" : "cancelled")\n'
        ),
        (
            'finish(1, "timed-out")\n'
        ),
    ),
)


def without_early_recording_launcher_hooks(test, source):
    for hook, replacement in EARLY_RECORDING_LAUNCHER_HOOKS:
        test.assertEqual(source.count(hook), 1,
                         "Missing, duplicated or changed early-only launcher hook")
        source = source.replace(hook, replacement, 1)
    return source


def without_product_launcher_hooks(test, source):
    source = without_early_recording_launcher_hooks(test, source)
    hooks = [
        ('"PICSHOT_EDITABLE_PRODUCT_MODE", "PICSHOT_EDITABLE_PRODUCT_INPUT", "PICSHOT_EDITABLE_PRODUCT_CERTIFICATE", ', ''),
        ('let launchBeganUptime = ProcessInfo.processInfo.systemUptime\n', ''),
        ('if ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil ||\n       ProcessInfo.processInfo.environment["PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY"] == "1" ||',
         'if ProcessInfo.processInfo.environment["PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY"] == "1" ||'),
        ('        if ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil {\n'
         '            report["launchBeganUptimeSeconds"] = launchBeganUptime\n'
         '            report["finishUptimeSeconds"] = ProcessInfo.processInfo.systemUptime\n'
         '        }\n', ''),
    ]
    for hook, replacement in hooks:
        test.assertEqual(source.count(hook), 1, 'Missing, duplicated or changed product-only launcher hook')
        source = source.replace(hook, replacement, 1)
    return source
