import XCTest

final class AnnotateTests: XCTestCase {
    func testRectFromDragAnyDirection() {
        let r = AnnotateLogic.rect(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 10, y: 100))
        XCTAssertEqual(r, CGRect(x: 10, y: 40, width: 40, height: 60))
        let square = AnnotateLogic.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 30, y: -10), square: true)
        XCTAssertEqual(square, CGRect(x: 0, y: -30, width: 30, height: 30))
    }

    func testArrowSnapsTo45Degrees() {
        let p = AnnotateLogic.snapped(CGPoint(x: 100, y: 8), from: .zero)
        XCTAssertEqual(p.y, 0, accuracy: 0.001)
        XCTAssertEqual(p.x, hypot(100, 8), accuracy: 0.001)
    }

    func testHollowRectHitsOnlyEdges() {
        var mark = Mark(kind: .rect)
        mark.rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        mark.width = 4
        XCTAssertTrue(mark.hit(CGPoint(x: 1, y: 50), tolerance: 4))
        XCTAssertFalse(mark.hit(CGPoint(x: 50, y: 50), tolerance: 4))
        mark.filled = true
        XCTAssertTrue(mark.hit(CGPoint(x: 50, y: 50), tolerance: 4))
    }

    func testArrowHitAndMove() {
        var mark = Mark(kind: .arrow)
        mark.start = .zero
        mark.end = CGPoint(x: 100, y: 0)
        XCTAssertTrue(mark.hit(CGPoint(x: 50, y: 3), tolerance: 5))
        XCTAssertFalse(mark.hit(CGPoint(x: 50, y: 30), tolerance: 5))
        let moved = mark.moved(by: CGSize(width: 10, height: 20))
        XCTAssertEqual(moved.start, CGPoint(x: 10, y: 20))
        XCTAssertEqual(moved.bounds, CGRect(x: 10, y: 20, width: 100, height: 0))
    }

    func testNextStepNumberAndTopHit() {
        var a = Mark(kind: .step)
        a.number = 2
        a.rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        var b = Mark(kind: .mosaic)
        b.rect = CGRect(x: 0, y: 0, width: 50, height: 50)
        XCTAssertEqual(AnnotateLogic.nextStepNumber([a, b]), 3)
        XCTAssertEqual(AnnotateLogic.nextStepNumber([]), 1)
        XCTAssertEqual(AnnotateLogic.topHit([a, b], at: CGPoint(x: 5, y: 5), tolerance: 2), b.id)
    }

    func testVisionRectFlipsY() {
        let r = AnnotateLogic.imageRect(fromVision: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1),
                                        size: CGSize(width: 1000, height: 500))
        XCTAssertEqual(r.minX, 100, accuracy: 0.001)
        XCTAssertEqual(r.minY, 100, accuracy: 0.001)
        XCTAssertEqual(r.width, 200, accuracy: 0.001)
        XCTAssertEqual(r.height, 50, accuracy: 0.001)
    }

    private func kinds(_ text: String, _ set: Set<SensitiveKind> = [.phone, .email, .idNumber, .bankCard, .secret]) -> [SensitiveKind] {
        SensitiveText.matches(in: text, kinds: set).map(\.kind)
    }

    private func found(_ text: String, _ set: Set<SensitiveKind> = [.phone, .email, .idNumber, .bankCard, .secret]) -> [String] {
        SensitiveText.matches(in: text, kinds: set).map { String(text[$0.range]) }
    }

    func testPhoneNumbers() {
        XCTAssertEqual(found("电话 13812345678 找我"), ["13812345678"])
        XCTAssertEqual(found("+86 138-1234-5678"), ["+86 138-1234-5678"])
        XCTAssertEqual(found("订单号 2138123456789"), [])
    }

    func testEmailAndSecrets() {
        XCTAssertEqual(found("联系 hanson@example.com 谢谢"), ["hanson@example.com"])
        XCTAssertEqual(kinds("key: sk-abcdefghijklmnopqrstuv"), [.secret])
        XCTAssertEqual(kinds("ghp_ABCDEFGHIJKLMNOPQRSTUVWX12"), [.secret])
    }

    func testIDNumberAndBankCard() {
        XCTAssertEqual(kinds("身份证 11010519491231002X"), [.idNumber])
        XCTAssertEqual(found("卡号 4111 1111 1111 1111"), ["4111 1111 1111 1111"])
        // Luhn 不通过的不算银行卡。
        XCTAssertEqual(kinds("4111 1111 1111 1112", [.bankCard]), [])
    }

    func testOnlyRequestedKinds() {
        XCTAssertEqual(kinds("13812345678 a@b.com", [.email]), [.email])
        XCTAssertEqual(found("  你好 世界 ", [.allText]), ["你好 世界"])
    }

    func testLuhn() {
        XCTAssertTrue(SensitiveText.luhn("4111111111111111"))
        XCTAssertFalse(SensitiveText.luhn("4111111111111112"))
        XCTAssertFalse(SensitiveText.luhn("1234"))
    }
}
