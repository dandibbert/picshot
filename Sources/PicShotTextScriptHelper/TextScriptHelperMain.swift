import Foundation
import Darwin
import PicShotTextScriptCore

@main
enum TextScriptHelperMain {
    static func main() {
        do {
            try TextScriptResourceLimits.install()
            guard CommandLine.arguments.count == 1 else { throw TextScriptDiagnostic.invalidRequest }
            try TextScriptPipeIO.prepare()
            let request = try TextScriptProtocol.decodeRequest(TextScriptPipeIO.readRequest())
            let response: TextScriptResponse
            do {
                switch request.operation {
                case .transform:
                    guard let source = request.source, let text = request.text else { throw TextScriptDiagnostic.invalidRequest }
                    response = .success(requestID: request.requestID, output: try TextScriptEngine.transform(source: source, text: text))
                case .capabilityProbe:
                    guard let probe = request.probe else { throw TextScriptDiagnostic.invalidRequest }
                    response = .success(requestID: request.requestID, probe: TextScriptCapabilityProbe.run(requestID: request.requestID, request: probe))
                }
            } catch let diagnostic as TextScriptDiagnostic {
                response = .failure(requestID: request.requestID, diagnostic: diagnostic)
            } catch {
                response = .failure(requestID: request.requestID, diagnostic: .runtimeUnavailable)
            }
            try response.validate(for: request)
            try TextScriptPipeIO.writeResponse(TextScriptProtocol.encodeResponse(response))
            exit(EXIT_SUCCESS)
        } catch let diagnostic as TextScriptDiagnostic {
            TextScriptPipeIO.fixedDiagnostic(diagnostic)
            exit(EXIT_FAILURE)
        } catch {
            TextScriptPipeIO.fixedDiagnostic(.invalidRequest)
            exit(EXIT_FAILURE)
        }
    }
}
