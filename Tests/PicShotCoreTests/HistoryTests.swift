import XCTest
@testable import PicShotCore
final class HistoryTests:XCTestCase {
    func make(_ n:Int,_ days:Int=0,starred:Bool=false)->CaptureRecord {CaptureRecord(createdAt:Date().addingTimeInterval(-Double(days)*86400),title:"Shot \(n)",filename:"\(n).png",width:100,height:100,byteCount:100,text:"你好 world",starred:starred)}
    func testStorageMetadataRejectsTraversalAndUnboundedRasters(){
        var r=CaptureRecord(title:"ok",filename:UUID().uuidString+".png",width:100,height:100,byteCount:500)
        XCTAssertTrue(r.hasSafeStorageMetadata)
        r.filename="../../private.png";XCTAssertFalse(r.hasSafeStorageMetadata)
        r.filename=UUID().uuidString+".png";r.width=Int.max;XCTAssertFalse(r.hasSafeStorageMetadata)
        r.width=100;r.height=0;XCTAssertFalse(r.hasSafeStorageMetadata)
    }
    func testQuotaAndStars(){let p=RetentionPolicy(maxItems:2,maxBytes:250,maxDays:30);let r=p.retained([make(0,90,starred:true),make(1),make(2,1)]);XCTAssertEqual(r.count,2);XCTAssertTrue(r.contains {$0.starred})}
    func testAgeAndSearch(){XCTAssertTrue(make(1).matches("你好"));XCTAssertTrue(make(1).matches("WORLD"));XCTAssertFalse(make(1).matches("missing"));XCTAssertTrue(RetentionPolicy().retained([make(1,40)]).isEmpty)}
    func testProtectedOverQuota(){XCTAssertEqual(RetentionPolicy(maxItems:1,maxBytes:1).retained([make(0,90,starred:true),make(1)]).count,1)}
}
