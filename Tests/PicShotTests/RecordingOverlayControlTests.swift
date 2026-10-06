import XCTest
import AppKit
@testable import PicShot

@MainActor
final class RecordingOverlayControlTests: XCTestCase {
    func testLiveDragChangesCompositionThenUndoClearAndEscapeAreDeterministic() {
        let state = RecordingCompositionState()
        state.setCanvasSize(CGSize(width: 320, height: 240))
        let controller = RecordingOverlayController(state: state)
        controller.drawing = true; controller.tool = .freehand; controller.width = 7
        controller.begin(at: CGPoint(x: 10, y: 10), resizeCamera: false)
        controller.drag(to: CGPoint(x: 30, y: 40))
        XCTAssertEqual(state.snapshot().annotations.first?.points.last, CGPoint(x: 30, y: 40))
        XCTAssertEqual(controller.annotationCount, 0, "In-progress strokes are visible in output before mouseUp")
        controller.end(at: CGPoint(x: 40, y: 50))
        XCTAssertEqual(controller.annotationCount, 1)
        controller.tool = .rectangle
        controller.begin(at: CGPoint(x: 100, y: 80), resizeCamera: false)
        controller.drag(to: CGPoint(x: 140, y: 110))
        XCTAssertEqual(state.snapshot().annotations.count, 2)
        controller.cancelInteraction()
        XCTAssertFalse(controller.drawing); XCTAssertEqual(state.snapshot().annotations.count, 1)
        controller.clear(); XCTAssertTrue(state.snapshot().annotations.isEmpty)
        controller.undo(); XCTAssertEqual(state.snapshot().annotations.count, 1)
        controller.undo(); XCTAssertTrue(state.snapshot().annotations.isEmpty)
    }

    func testCameraDragResizeAndCropUseSameNormalizedCompositionState() {
        let state = RecordingCompositionState()
        state.setCanvasSize(CGSize(width: 1_000, height: 1_000))
        state.setLayout(RecordingCameraLayout(frame: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)))
        let controller = RecordingOverlayController(state: state)
        controller.cameraEditing = true
        controller.begin(at: CGPoint(x: 300, y: 300), resizeCamera: false)
        controller.end(at: CGPoint(x: 400, y: 400))
        var layout = state.snapshot().cameraLayout
        XCTAssertEqual(layout.frame.minX, 0.3, accuracy: 0.001)
        XCTAssertEqual(layout.frame.minY, 0.3, accuracy: 0.001)
        controller.begin(at: CGPoint(x: 500, y: 300), resizeCamera: true)
        controller.end(at: CGPoint(x: 600, y: 200))
        layout = state.snapshot().cameraLayout
        XCTAssertEqual(layout.frame.width, 0.3, accuracy: 0.001)
        XCTAssertEqual(layout.frame.height, 0.3, accuracy: 0.001)
        controller.setCameraCrop(zoom: 2, horizontal: 1, vertical: 0)
        XCTAssertEqual(state.snapshot().cameraLayout.crop, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        controller.cancelInteraction(); XCTAssertFalse(controller.cameraEditing)
    }

    func testStrokeAndAnnotationCapsRemainRecoverableUsingClear() {
        let controller = RecordingOverlayController(state: RecordingCompositionState())
        controller.drawing = true
        controller.begin(at: .zero, resizeCamera: false)
        for index in 0..<4_200 { controller.drag(to: CGPoint(x: index, y: index)) }
        XCTAssertEqual(controller.state.snapshot().annotations.first?.points.count,
                       RecordingCompositionState.maximumPointsPerStroke)
        controller.end(at: CGPoint(x: 4_200, y: 4_200))
        controller.tool = .rectangle
        for index in 1..<RecordingCompositionState.maximumAnnotations {
            controller.begin(at: CGPoint(x: index, y: index), resizeCamera: false)
            controller.end(at: CGPoint(x: index + 10, y: index + 10))
        }
        controller.begin(at: .zero, resizeCamera: false)
        XCTAssertNotNil(controller.limitMessage)
        XCTAssertEqual(controller.state.snapshot().annotations.count, RecordingCompositionState.maximumAnnotations)
        controller.clear(); XCTAssertNil(controller.limitMessage)
        controller.begin(at: .zero, resizeCamera: false); controller.end(at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(controller.annotationCount, 1)
    }
}
