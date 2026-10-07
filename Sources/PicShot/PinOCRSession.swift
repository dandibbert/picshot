import Foundation
import CoreGraphics

struct PinOCRKey: Sendable, Equatable {
    let revision: UInt
    let options: RecognitionOptions
}

enum PinOCRConsumer: Hashable, Sendable {
    case selection, copyAll, resultWindow
}

enum PinOCRState: Equatable {
    case idle, queued, recognizing, ready, failed, suspended, closed
}

enum PinOCRError: LocalizedError {
    case queueFull, sourceUnavailable, imageTooLarge

    var errorDescription: String? {
        switch self {
        case .queueFull: return "本地识别正在忙碌，请稍后重试。"
        case .sourceUnavailable: return "贴图已不可用。"
        case .imageTooLarge: return "本地识别最多支持 3200 万像素。请先裁剪图片。"
        }
    }
}

/// One bounded result for one pin revision/language. The image provider must capture its pin
/// weakly; neither queued work nor a cached result owns a raster. This type never changes
/// window focus, selection or the pasteboard. Only explicit consumers perform those actions.
@MainActor final class PinOCRSession {
    typealias Recognizer = @Sendable (CGImage, RecognitionOptions) async throws -> RecognitionResult
    typealias Completion = (Result<RecognitionResult, Error>) -> Void

    let id = UUID()
    private(set) var key: PinOCRKey
    private(set) var cachedResult: RecognitionResult?
    private(set) var state: PinOCRState = .idle
    /// Observers read key/state/cachedResult and must weakly capture their UI owner.
    /// Updates carry no presentation side effects and may occur synchronously.
    var onChange: (() -> Void)?
    fileprivate private(set) var generation = UUID()
    fileprivate let recognize: Recognizer
    private let imageProvider: () -> CGImage?
    private let scheduler: PinOCRScheduler
    private var automaticWanted = false
    private var subscribers: [PinOCRConsumer: Subscriber] = [:]
    private struct Subscriber {
        let id: UUID
        let completion: Completion
    }

    init(revision: UInt = 0, options: RecognitionOptions = RecognitionOptions(),
         scheduler: PinOCRScheduler? = nil, imageProvider: @escaping () -> CGImage?,
         recognize: @escaping Recognizer = { try await RecognitionService.recognize($0, options: $1) }) {
        key = PinOCRKey(revision: revision, options: options)
        self.scheduler = scheduler ?? .shared
        self.imageProvider = imageProvider
        self.recognize = recognize
    }

    deinit {
        // Main-actor deinitialization is not guaranteed in Swift 5 mode. The cancellation
        // message owns only the scheduler and identity, never this session or its source.
        let scheduler = scheduler, id = id
        Task { @MainActor in scheduler.cancel(sessionID: id) }
    }

    /// A changed source invalidates both geometry and text. Same-key updates are harmless.
    func update(revision: UInt, options: RecognitionOptions? = nil) {
        guard state != .closed else { return }
        let next = PinOCRKey(revision: revision, options: options ?? key.options)
        guard key != next else { return }
        let suspended = state == .suspended
        key = next
        invalidate(nextState: suspended ? .suspended : .idle)
    }

    /// No task is created for a waiting automatic request. Restoration can enqueue a whole
    /// group without capturing that group's images in OCR closures or asynchronous tasks.
    func scheduleAutomatic() {
        guard acceptsWork, cachedResult == nil else { return }
        automaticWanted = true
        scheduler.submit(self, explicit: !subscribers.isEmpty)
    }

    /// At most one subscriber per UI purpose (three total). Replacing a purpose cancels its
    /// previous subscription; a late cancellation can only cancel its own returned token.
    /// Cached results and errors may invoke completion synchronously.
    @discardableResult
    func request(_ consumer: PinOCRConsumer, completion: @escaping Completion) -> UUID {
        let token = UUID()
        install(token, consumer: consumer, completion: completion)
        return token
    }

    func result(for consumer: PinOCRConsumer, options: RecognitionOptions? = nil) async throws -> RecognitionResult {
        try Task.checkCancellation()
        if let options { update(revision: key.revision, options: options) }
        let token = UUID()
        let value: RecognitionResult = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                install(token, consumer: consumer) { continuation.resume(with: $0) }
                // onCancel may run before installation; this check closes that race.
                if Task.isCancelled { cancelRequest(token) }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelRequest(token) }
        })
        try Task.checkCancellation()
        return value
    }

    func cancelRequest(_ token: UUID) {
        guard let consumer = subscribers.first(where: { $0.value.id == token })?.key,
              let subscriber = subscribers.removeValue(forKey: consumer) else { return }
        reconcileDemand()
        subscriber.completion(.failure(CancellationError()))
    }

    func cancelRequest(for consumer: PinOCRConsumer) {
        if let token = subscribers[consumer]?.id { cancelRequest(token) }
    }

    /// Use for hide, group switch, click-through and modal editing. Cancels subscriptions
    /// immediately and drops the cached document; executing work keeps its slot until exit.
    func suspend() {
        guard state != .closed else { return }
        invalidate(nextState: .suspended)
    }

    /// Resuming alone never starts OCR or changes focus. The owner can scheduleAutomatic()
    /// once the pin is visible and interactive again.
    func resume() { if state == .suspended { state = .idle; onChange?() } }

    func close() {
        guard state != .closed else { return }
        invalidate(nextState: .closed)
        onChange = nil
    }

    private var acceptsWork: Bool { state != .closed && state != .suspended }

    private func install(_ token: UUID, consumer: PinOCRConsumer, completion: @escaping Completion) {
        guard acceptsWork else { completion(.failure(CancellationError())); return }
        if let cachedResult { completion(.success(cachedResult)); return }
        let old = subscribers.updateValue(Subscriber(id: token, completion: completion), forKey: consumer)
        scheduler.submit(self, explicit: true)
        old?.completion(.failure(CancellationError()))
    }

    private func reconcileDemand() {
        if subscribers.isEmpty && !automaticWanted {
            generation = UUID()
            scheduler.cancel(sessionID: id)
            if acceptsWork { state = cachedResult == nil ? .idle : .ready }
            onChange?()
        } else { scheduler.submit(self, explicit: !subscribers.isEmpty) }
    }

    private func invalidate(nextState: PinOCRState) {
        generation = UUID()
        cachedResult = nil
        automaticWanted = false
        state = nextState
        let cancelled = Array(subscribers.values)
        subscribers.removeAll()
        scheduler.cancel(sessionID: id)
        cancelled.forEach { $0.completion(.failure(CancellationError())) }
        onChange?()
    }

    fileprivate func accepts(_ generation: UUID) -> Bool {
        acceptsWork && self.generation == generation && (automaticWanted || !subscribers.isEmpty)
    }

    fileprivate func queued(_ generation: UUID) {
        if accepts(generation) { state = .queued; onChange?() }
    }

    fileprivate func admittedImage(_ generation: UUID) throws -> CGImage {
        guard accepts(generation), let image = imageProvider(), accepts(generation) else {
            throw PinOCRError.sourceUnavailable
        }
        guard PinImageRenderer.allowsRasterSize(width: image.width, height: image.height) else {
            throw PinOCRError.imageTooLarge
        }
        return image
    }

    fileprivate func admitted(_ generation: UUID) {
        if accepts(generation) { state = .recognizing; onChange?() }
    }

    fileprivate func finish(_ result: Result<RecognitionResult, Error>, generation: UUID) {
        guard accepts(generation) else { return }
        automaticWanted = false
        switch result {
        case .success(let result): cachedResult = result; state = .ready
        case .failure: state = .failed
        }
        let completed = Array(subscribers.values)
        subscribers.removeAll()
        onChange?()
        // A completion can synchronously edit/close its pin. Do not deliver another old
        // result after that callback changes the source or lifetime generation.
        for subscriber in completed {
            if self.generation == generation && acceptsWork { subscriber.completion(result) }
            else { subscriber.completion(.failure(CancellationError())) }
        }
    }
}

struct PinOCRResourceSnapshot: Equatable {
    let activeJobs: Int
    let automaticJobs: Int
    let waitingSessions: Int
    let admittedJobs: Int
    let releasedJobs: Int
    let cancelledJobs: Int
    let rejectedJobs: Int
}

/// A small front queue ahead of RecognitionService's existing global 2-active/4-waiting
/// admission. A single automatic job leaves room for interactive requests. At most two
/// admitted jobs own a raster; cancelled running jobs remain accounted until they return.
@MainActor final class PinOCRScheduler {
    static let shared = PinOCRScheduler()
    static let maximumActiveJobs = 2
    static let maximumAutomaticJobs = 1
    static let maximumWaitingSessions = 32

    @MainActor private final class Job {
        let id = UUID()
        let sessionID: UUID
        let generation: UUID
        weak var session: PinOCRSession?
        var explicit: Bool
        var cancelled = false
        var task: Task<Void, Never>?
        init(_ session: PinOCRSession, explicit: Bool) {
            sessionID = session.id; generation = session.generation
            self.session = session; self.explicit = explicit
        }
        var isCurrent: Bool { session?.accepts(generation) == true }
    }

    private var waiting: [Job] = []
    private var active: [UUID: Job] = [:]
    private var pumping = false
    private var admittedJobs = 0
    private var releasedJobs = 0
    private var cancelledJobs = 0
    private var rejectedJobs = 0

    var resourceSnapshot: PinOCRResourceSnapshot {
        pruneWaiting()
        return PinOCRResourceSnapshot(activeJobs: active.count,
                                      automaticJobs: active.values.filter { !$0.explicit }.count,
                                      waitingSessions: waiting.count, admittedJobs: admittedJobs,
                                      releasedJobs: releasedJobs, cancelledJobs: cancelledJobs,
                                      rejectedJobs: rejectedJobs)
    }

    fileprivate func submit(_ session: PinOCRSession, explicit: Bool) {
        guard session.accepts(session.generation) else { return }
        if let job = active.values.first(where: { $0.sessionID == session.id && $0.generation == session.generation }) {
            // Promotion is sticky for a running job. Downgrading after an explicit
            // subscriber cancels could turn two already-running jobs into background work.
            job.explicit = job.explicit || explicit
            pump()
            return
        }
        pruneWaiting()
        if let job = waiting.first(where: { $0.sessionID == session.id && $0.generation == session.generation }) {
            job.explicit = explicit
        } else {
            if waiting.count >= Self.maximumWaitingSessions {
                // A full background queue must not reject a new explicit user action.
                if explicit, let index = waiting.lastIndex(where: { !$0.explicit }) {
                    let evicted = waiting.remove(at: index)
                    rejectedJobs += 1
                    evicted.session?.finish(.failure(PinOCRError.queueFull), generation: evicted.generation)
                } else {
                    rejectedJobs += 1
                    session.finish(.failure(PinOCRError.queueFull), generation: session.generation)
                    return
                }
            }
            waiting.append(Job(session, explicit: explicit))
            session.queued(session.generation)
        }
        pump()
    }

    fileprivate func cancel(sessionID: UUID) {
        waiting.removeAll { $0.sessionID == sessionID }
        for job in active.values where job.sessionID == sessionID && !job.cancelled {
            job.cancelled = true
            cancelledJobs += 1
            job.task?.cancel()
        }
        pump()
    }

    private func pruneWaiting() { waiting.removeAll { !$0.isCurrent } }

    private func pump() {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        pruneWaiting()
        while active.count < Self.maximumActiveJobs {
            let index: Int?
            if let explicit = waiting.firstIndex(where: { $0.explicit }) { index = explicit }
            else if active.values.filter({ !$0.explicit }).count < Self.maximumAutomaticJobs { index = waiting.indices.first }
            else { index = nil }
            guard let index else { break }
            let job = waiting.remove(at: index)
            guard let session = job.session, job.isCurrent else { continue }
            do {
                let image = try session.admittedImage(job.generation)
                let recognize = session.recognize, options = session.key.options, jobID = job.id
                active[jobID] = job
                admittedJobs += 1
                job.task = Task(priority: job.explicit ? .userInitiated : .utility) { [weak self] in
                    let result: Result<RecognitionResult, Error>
                    do {
                        try Task.checkCancellation()
                        let value = try await recognize(image, options)
                        try Task.checkCancellation()
                        result = .success(value)
                    } catch { result = .failure(error) }
                    self?.finish(jobID: jobID, result: result)
                }
                session.admitted(job.generation)
            } catch {
                session.finish(.failure(error), generation: job.generation)
            }
        }
    }

    private func finish(jobID: UUID, result: Result<RecognitionResult, Error>) {
        guard let job = active.removeValue(forKey: jobID) else { return }
        job.task = nil
        releasedJobs += 1
        job.session?.finish(result, generation: job.generation)
        pump()
    }
}
