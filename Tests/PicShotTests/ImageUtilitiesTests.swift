import XCTest
import AppKit
@testable import PicShot
final class ImageUtilitiesTests:XCTestCase {
    func testPNGImageRoundtrip() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png");defer{try? FileManager.default.removeItem(at:url)}
        let context=CGContext(data:nil,width:40,height:30,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.2,green:0.5,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:40,height:30));try context.makeImage()!.writePNG(to:url)
        XCTAssertEqual(CGImage.read(url:url)?.width,40);XCTAssertEqual(CGImage.read(url:url,maxDimension:20)?.width,20)
    }
}
