import XCTest
import CoreGraphics
import CoreText
import CoreImage
@testable import PicShot
final class RecognitionTests:XCTestCase {
    func testOfflineOCRReadsNativeTextFixture() async throws {
        let context=CGContext(data:nil,width:1000,height:220,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:1000,height:220));context.textPosition=CGPoint(x:40,y:95)
        let font=CTFontCreateWithName("Helvetica-Bold" as CFString,64,nil)
        let text=NSAttributedString(string:"PicShot Local Capture",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)])
        CTLineDraw(CTLineCreateWithAttributedString(text),context)
        let result=try await RecognitionService.recognize(context.makeImage()!)
        XCTAssertTrue(result.text.lowercased().contains("picshot"),result.text)
        XCTAssertTrue(result.text.lowercased().contains("capture"),result.text)
    }
    func testOfflineQRPayloadRecognition() async throws {
        let payload="picshot:test:local-only"
        let filter=CIFilter(name:"CIQRCodeGenerator")!;filter.setValue(Data(payload.utf8),forKey:"inputMessage");filter.setValue("M",forKey:"inputCorrectionLevel")
        let code=try XCTUnwrap(filter.outputImage).transformed(by:CGAffineTransform(scaleX:10,y:10))
        let canvas=CIImage(color:CIColor.white).cropped(to:code.extent.insetBy(dx:-40,dy:-40))
        let image=try XCTUnwrap(CIContext().createCGImage(code.composited(over:canvas),from:canvas.extent))
        let result=try await RecognitionService.recognize(image)
        XCTAssertTrue(result.barcodes.contains(payload),result.barcodes.description)
    }
}
