import AppKit

enum EditorOutputProjectionError: LocalizedError {
    case busy, invalidOwner, tooLarge
    var errorDescription: String? {
        switch self {
        case .busy: return "正在生成另一张装饰图片，请等待完成或取消后重试。"
        case .invalidOwner: return "图片已更改，本次输出已取消，请重试。"
        case .tooLarge: return "装饰输出的合成图片和工作内存合计超过 512 MiB，请减小阴影、裁剪或关闭装饰。原图导出不受此附加限制。"
        }
    }
}

/// A global one-job lease. Reservation happens BEFORE flattening, so rejected
/// requests do not allocate snapshots or form an unbounded operation backlog.
/// Cancellation clears queued input immediately but holds admission until the
/// operation is finished AND its main-actor completion has drained.
@MainActor
final class EditorOutputProjection {
    static let shared = EditorOutputProjection()
    static let combinedWorkingByteLimit = 512 * 1_024 * 1_024
    @MainActor final class Ticket {
        let id = UUID()
        let sourceWidth: Int, sourceHeight: Int
        let decoration: ImageOutputDecoration
        let rendererLimits: ImageOutputDecorationLimits
        let knownWorkingBytes: Int
        /// Conservative upper reservation includes queried native scratch.
        let reservedBytes = EditorOutputProjection.combinedWorkingByteLimit
        let cancellation = ImageExportCancellation()
        fileprivate var input: ImageExportJobInput<CGImage>?
        fileprivate var operation: Operation?
        fileprivate var started = false
        fileprivate init(width: Int, height: Int, decoration: ImageOutputDecoration,
                         limits: ImageOutputDecorationLimits, knownWorkingBytes: Int) {
            sourceWidth = width; sourceHeight = height; self.decoration = decoration
            rendererLimits = limits; self.knownWorkingBytes = knownWorkingBytes
        }
        func cancel() { cancellation.cancel(); input?.clear(); operation?.cancel() }
    }
    let queue: OperationQueue
    private(set) var activeTicket: Ticket?
    private(set) var startedCount = 0
    private(set) var completedCount = 0
    var isBusy: Bool { activeTicket != nil }
    var reservedBytes: Int { activeTicket?.reservedBytes ?? 0 }
    private init() {
        // A canceled palette may still be in a native full-frame normalization.
        // Its worker and final projection must never overlap. This serializes
        // these two paths only, not other app rendering/encoding work.
        queue = ImageOutputDecorationPalette.previewQueue
    }

    func reserve(width: Int, height: Int, decoration: ImageOutputDecoration) throws -> Ticket {
        guard activeTicket == nil else { throw EditorOutputProjectionError.busy }
        guard width > 0, height > 0, width <= Self.combinedWorkingByteLimit / 4 / height else {
            throw EditorOutputProjectionError.tooLarge
        }
        let inputBytes = width * height * 4
        var limits = ImageOutputDecorationLimits.standard
        limits.maximumWorkingBytes = Self.combinedWorkingByteLimit - inputBytes
        guard limits.maximumWorkingBytes >= 4 else { throw EditorOutputProjectionError.tooLarge }
        let layout: ImageOutputDecorationLayout
        do { layout = try .make(width: width, height: height, decoration: decoration, limits: limits) }
        catch ImageOutputDecorationError.tooLarge { throw EditorOutputProjectionError.tooLarge }
        let ticket = Ticket(width: width, height: height, decoration: decoration, limits: limits,
            knownWorkingBytes: inputBytes + layout.workingBytes)
        activeTicket = ticket; return ticket
    }

    /// Release a reservation only if no operation ever took ownership of it.
    func abandon(_ ticket: Ticket) {
        guard activeTicket === ticket, !ticket.started else { return }
        ticket.cancel(); activeTicket = nil
    }

    func start(_ ticket: Ticket, image: CGImage,
               completion: @escaping @MainActor (Result<CGImage, Error>) -> Void) throws {
        guard activeTicket === ticket, !ticket.started, !ticket.cancellation.isCancelled,
              image.width == ticket.sourceWidth, image.height == ticket.sourceHeight,
              image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.bytesPerRow == image.width * 4 else {
            abandon(ticket); throw EditorOutputProjectionError.invalidOwner
        }
        ticket.started = true; startedCount += 1
        let input = ImageExportJobInput(image), result = EditorProjectionResultHolder()
        let cancellation = ticket.cancellation, decoration = ticket.decoration, limits = ticket.rendererLimits
        ticket.input = input
        let operation = BlockOperation {
            guard let image = input.take() else { return }
            result.store(autoreleasepool {
                Result {
                    do {
                        return try ImageOutputDecorationRenderer.project(flattened: image, decoration: decoration,
                            cancellation: cancellation, limits: limits)
                    } catch ImageOutputDecorationError.tooLarge { throw EditorOutputProjectionError.tooLarge }
                }
            })
        }
        operation.completionBlock = { [weak self, weak ticket] in
            input.clear()
            DispatchQueue.main.async { [weak self, weak ticket] in
                guard let self, let ticket else { return }
                // CompletionBlock runs after isFinished; input/render locals have
                // left scope. The lease is not relinquished on cancel() alone.
                ticket.input = nil; ticket.operation = nil
                guard self.activeTicket === ticket else { return }
                let finished = result.take() ?? .failure(CancellationError())
                self.activeTicket = nil; self.completedCount += 1
                completion(ticket.cancellation.isCancelled ? .failure(CancellationError()) : finished)
            }
        }
        ticket.operation = operation; queue.addOperation(operation)
    }
}

private final class EditorProjectionResultHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CGImage, Error>?
    func store(_ value: Result<CGImage, Error>) { lock.lock(); result = value; lock.unlock() }
    func take() -> Result<CGImage, Error>? {
        lock.lock(); defer { lock.unlock() }; let value = result; result = nil; return value
    }
}

enum ImageEditorOutputRoute: String, CaseIterable {
    case copy, history, pin, quickSave, saveCopy, applyToPin, recognition, translation, export
}
