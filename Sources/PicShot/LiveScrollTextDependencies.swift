import Foundation
import PicShotCore

/// Synchronous adoption is intentional: the route releases its rendered raster
/// before awaiting the runner's terminal event. AppMain owns the active runner,
/// including phase retries and cancellation drainage.
@MainActor
struct LiveScrollTextDependencies {
    let definitions: () throws -> [TextScriptDefinition]
    let start: (UUID, UUID, TextScriptDefinition, ChainCapture, @escaping (CaptureChainSnapshot) -> Void) throws -> Void
    let cancel: (UUID) -> Void

    init(definitions: @escaping () throws -> [TextScriptDefinition],
         start: @escaping (UUID, UUID, TextScriptDefinition, ChainCapture, @escaping (CaptureChainSnapshot) -> Void) throws -> Void,
         cancel: @escaping (UUID) -> Void) {
        self.definitions = definitions; self.start = start; self.cancel = cancel
    }
}
