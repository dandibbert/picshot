"""Restore only the reviewed retirement insertions before hashing old workload."""


def without_product_retirement_waits(test, source):
    def replace(before, after):
        nonlocal source
        test.assertEqual(source.count(before), 1, 'Retirement scope changed: ' + before[:90])
        source = source.replace(before, after)

    replace('''            var retirements = run!.retirementObservations
            run = nil
            _ = try await EditableProductRetirement.wait(cycle: 0, phase: "fixed-run-released", deadline: deadline,
                observe: { retirementState(fixedOwnership, run: nil) }, record: { evidence in
                    if retirements.count == 30 { retirements.append(evidence) }
                    else { retirements[30] = evidence }
                    // Evidence is scalars only; preserve the original observation
                    // even when cancellation or the bounded retirement wait fails.
                    report["retirementObservations"] = try scalar(retirements)
                })''', '''            run = nil
            try await wait(deadline) { fixedOwnership.alive == 0 && drained() }''')
    replace('''                report["retirementObservations"] = try scalar(current.retirementObservations)
''', '')
    replace('''            try await run.retire("seed-closed", deadline: deadline)''',
        '''            try await wait(deadline) { run.observation.editorCount == 0 && run.observation.alive == 0 && run.observation.attachedWindowCount == 0 && drained() }''')
    replace('''            try await run.retire("group-hidden-released", deadline: deadline)''',
        '''            try await wait(deadline) { run.observation.alive == 0 && run.observation.attachedWindowCount == 0 && run.session.livePinCount == 0 && drained() }''')
    replace('''            try await run.retire("cycle-released", deadline: deadline)''',
        '''            try await wait(deadline) { run.observation.alive == 0 && run.observation.attachedWindowCount == 0 && run.session.livePinCount == 0 && drained() }''')
    replace('''            report["retirementObservations"] = try scalar(run.retirementObservations)
''', '')
    return source


def without_provider_test_observer(test, source):
    hooks = [
        ('''    /// Explicit test construction only. Observe the actual provider before
    /// CGImage may copy it; process/environment configurations always set nil.
    let providerObserverForTesting: ((CGDataProvider) -> Void)?
''', ''),
        ('''         failureInjection: DrawingRaster.FailureInjection = .none,
         providerObserverForTesting: ((CGDataProvider) -> Void)? = nil) {''',
         '''         failureInjection: DrawingRaster.FailureInjection = .none) {'''),
        ('''        self.providerObserverForTesting = providerObserverForTesting
''', ''),
        ('''        providerObserverForTesting = nil
''', ''),
        ('''            configuration.providerObserverForTesting?(provider)
''', ''),
    ]
    for hook, replacement in hooks:
        test.assertEqual(source.count(hook), 1, 'Test observer scope changed: ' + hook)
        source = source.replace(hook, replacement)
    return source
