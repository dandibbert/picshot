import CoreGraphics
import CoreImage
import Foundation

/// A smoke-only render-task memory target. This is not a process/RSS limit.
enum EffectContextPolicy: String, CaseIterable, Sendable {
    case reference
    case memory32
    static let productionDefault: Self = .reference

    /// Apple defines CIContextOption.memoryTarget in megabytes, not bytes.
    /// nil means the framework default is left unspecified, not zero/unlimited.
    var configuredMemoryTargetMegabytes: Int? { self == .memory32 ? 32 : nil }
    var contextOptions: [CIContextOption: Any] {
        var options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let target = configuredMemoryTargetMegabytes { options[.memoryTarget] = target }
        return options
    }
}

/// Scalar observations only. Neither this value nor its tracker retains an image,
/// filter, context, render closure, or output provider. Counts do not measure RSS,
/// framework scratch/cache residency, GPU memory, or a memory improvement.
struct EffectContextSnapshot: Codable, Equatable {
    let configuredMemoryTargetMegabytes: Int?
    let configuredCacheIntermediates: Bool?
    let contextOptionCount: Int
    let contextCount: Int
    var attemptCount = 0
    var publishCount = 0
    var failureCount = 0
}

final class EffectContextTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EffectContextSnapshot
    /// Captures scalar inputs from the exact dictionary passed to CIContext.
    /// Core Image's resulting internal memory budget has no readback here.
    fileprivate init(options: [CIContextOption: Any]?, contextCount: Int) {
        value = EffectContextSnapshot(configuredMemoryTargetMegabytes: options?[.memoryTarget] as? Int,
                                      configuredCacheIntermediates: options?[.cacheIntermediates] as? Bool,
                                      contextOptionCount: options?.count ?? 0, contextCount: contextCount)
    }
    func snapshot() -> EffectContextSnapshot {
        lock.lock(); defer { lock.unlock() }; return value
    }
    fileprivate func update(_ body: (inout EffectContextSnapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(&value)
    }
}

/// One immutable CIContext per configuration, shared by all calls. Production
/// uses only `process`, whose environment is selected once on first access.
/// CIContext supports concurrent rendering; only the scalar tracker needs a lock.
/// The sole candidate difference is .memoryTarget: 32. Color management, alpha,
/// working/output formats, backend selection and createCGImage remain defaults.
final class EffectContextConfiguration: @unchecked Sendable {
    enum Failure: Error, Equatable { case invalidConfiguration, renderFailed, injectedRender }
    enum FailureInjection: Sendable { case none, render }

    static let process = EffectContextConfiguration(environment: ProcessInfo.processInfo.environment)
    let tracker: EffectContextTracker
    private let selection: Result<EffectContextPolicy, Failure>
    private let context: CIContext?
    private let failureInjection: FailureInjection

    init(policy: EffectContextPolicy, failureInjection: FailureInjection = .none) {
        let options = policy.contextOptions
        selection = .success(policy)
        context = CIContext(options: options)
        tracker = EffectContextTracker(options: options, contextCount: 1)
        self.failureInjection = failureInjection
    }

    init(environment: [String: String]) {
        failureInjection = .none
        do {
            let policy = try Self.selection(environment: environment)
            let options = policy.contextOptions
            selection = .success(policy)
            context = CIContext(options: options)
            tracker = EffectContextTracker(options: options, contextCount: 1)
        } catch {
            selection = .failure(.invalidConfiguration)
            context = nil
            tracker = EffectContextTracker(options: nil, contextCount: 0)
        }
    }

    func selectedPolicy() throws -> EffectContextPolicy { try selection.get() }

    static func selection(environment: [String: String]) throws -> EffectContextPolicy {
        let keys = environment.keys.filter { $0.hasPrefix("PICSHOT_EFFECT_CONTEXT") }
        guard keys.allSatisfy({ $0 == "PICSHOT_EFFECT_CONTEXT_POLICY" }) else {
            throw Failure.invalidConfiguration
        }
        guard let raw = environment["PICSHOT_EFFECT_CONTEXT_POLICY"] else { return .productionDefault }
        guard environment["PICSHOT_SMOKE_TEST"] == "1",
              let report = environment["PICSHOT_SMOKE_REPORT"], report.hasPrefix("/"), !report.contains("\0"),
              let policy = EffectContextPolicy(rawValue: raw) else { throw Failure.invalidConfiguration }
        return policy
    }

    /// A nil patch propagates through the renderer's existing fail-closed path.
    /// There is no fallback to reference or to the unmodified input image.
    func renderEffectPatch(_ image: CIImage, _ region: CGRect) -> CGImage? {
        try? render(image, from: region)
    }

    func render(_ image: CIImage, from region: CGRect) throws -> CGImage {
        tracker.update { $0.attemptCount += 1 }
        do {
            _ = try selectedPolicy()
            guard let context else { throw Failure.invalidConfiguration }
            if failureInjection == .render { throw Failure.injectedRender }
            guard let result = context.createCGImage(image, from: region) else { throw Failure.renderFailed }
            tracker.update { $0.publishCount += 1 }
            return result
        } catch {
            tracker.update { $0.failureCount += 1 }
            throw error
        }
    }
}
