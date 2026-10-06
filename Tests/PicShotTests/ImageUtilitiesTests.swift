import XCTest
import AppKit
@testable import PicShot
final class ImageUtilitiesTests:XCTestCase {
    func testReadImageSurvivesSourceDeletion() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        let context=CGContext(data:nil,width:17,height:13,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed:1,green:0,blue:0,alpha:1));context.fill(CGRect(x:0,y:0,width:17,height:13));try context.makeImage()!.writePNG(to:url)
        let image=try XCTUnwrap(CGImage.read(url:url));let thumbnail=try XCTUnwrap(CGImage.read(url:url,maxDimension:8))
        try FileManager.default.removeItem(at:url)
        for value in [image,thumbnail]{
            let target=CGContext(data:nil,width:value.width,height:value.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            target.draw(value,in:CGRect(x:0,y:0,width:value.width,height:value.height));let pixel=target.data!.assumingMemoryBound(to:UInt8.self)
            XCTAssertEqual(pixel[0],255);XCTAssertEqual(pixel[1],0);XCTAssertEqual(pixel[3],255)
        }
    }
    func testPNGImageRoundtrip() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png");defer{try? FileManager.default.removeItem(at:url)}
        let context=CGContext(data:nil,width:40,height:30,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.2,green:0.5,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:40,height:30));try context.makeImage()!.writePNG(to:url)
        XCTAssertEqual(CGImage.read(url:url)?.width,40);XCTAssertEqual(CGImage.read(url:url,maxDimension:20)?.width,20)
    }
}
