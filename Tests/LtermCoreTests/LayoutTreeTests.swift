import XCTest
@testable import LtermCore

final class LayoutTreeTests: XCTestCase {
    /// 1 | 2 on the left/right, then 2 split down into 2 / 3.
    private func threePanes() -> LayoutTree {
        var tree = LayoutTree(pane: 1)
        XCTAssertTrue(tree.split(1, axis: .horizontal, newPane: 2))
        XCTAssertTrue(tree.split(2, axis: .vertical, newPane: 3))
        return tree
    }

    func testSplitAddsPaneInReadingOrder() {
        let tree = threePanes()
        XCTAssertEqual(tree.leaves, [1, 2, 3])
        XCTAssertEqual(tree.root, .split(.horizontal, ratio: 0.5, first: .leaf(1),
                                         second: .split(.vertical, ratio: 0.5, first: .leaf(2), second: .leaf(3))))
    }

    func testSplitRejectsUnknownOrDuplicatePane() {
        var tree = threePanes()
        XCTAssertFalse(tree.split(9, axis: .horizontal, newPane: 10))
        XCTAssertFalse(tree.split(1, axis: .horizontal, newPane: 2))
        XCTAssertEqual(tree.count, 3)
    }

    func testRemoveGivesSpaceToSibling() {
        var tree = threePanes()
        XCTAssertTrue(tree.remove(2))
        XCTAssertEqual(tree.root, .split(.horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(3)))
        XCTAssertTrue(tree.remove(1))
        XCTAssertEqual(tree.root, .leaf(3))
        XCTAssertFalse(tree.remove(3), "the last pane stays")
        XCTAssertFalse(tree.remove(42))
    }

    func testFramesFillTheRect() {
        let frames = threePanes().frames(in: Rect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(frames[1], Rect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(frames[2], Rect(x: 50, y: 0, width: 50, height: 25))
        XCTAssertEqual(frames[3], Rect(x: 50, y: 25, width: 50, height: 25))
    }

    func testFramesLeaveGap() {
        var tree = LayoutTree(pane: 1)
        tree.split(1, axis: .horizontal, newPane: 2)
        let frames = tree.frames(in: Rect(x: 0, y: 0, width: 101, height: 10), gap: 1)
        XCTAssertEqual(frames[1]?.width, 50)
        XCTAssertEqual(frames[2]?.x, 51)
        XCTAssertEqual(frames[2]?.width, 50)
        let dividers = tree.dividers(in: Rect(x: 0, y: 0, width: 101, height: 10), gap: 1)
        XCTAssertEqual(dividers.count, 1)
        XCTAssertEqual(dividers[0].rect, Rect(x: 50, y: 0, width: 1, height: 10))
    }

    func testNeighborsByGeometry() {
        let tree = threePanes()
        XCTAssertEqual(tree.neighbor(of: 1, direction: .right), 2, "equal overlap ties go to the first pane in reading order")
        XCTAssertEqual(tree.neighbor(of: 2, direction: .left), 1)
        XCTAssertEqual(tree.neighbor(of: 3, direction: .left), 1)
        XCTAssertEqual(tree.neighbor(of: 2, direction: .down), 3)
        XCTAssertEqual(tree.neighbor(of: 3, direction: .up), 2)
        XCTAssertNil(tree.neighbor(of: 1, direction: .left))
        XCTAssertNil(tree.neighbor(of: 3, direction: .down))
    }

    func testNextAndPreviousWrap() {
        let tree = threePanes()
        XCTAssertEqual(tree.next(after: 3), 1)
        XCTAssertEqual(tree.next(after: 1), 2)
        XCTAssertEqual(tree.previous(before: 1), 3)
    }

    func testResizeMovesNearestMatchingDivider() {
        var tree = threePanes()
        // Pane 3 is in the vertical split; moving down grows the top part.
        XCTAssertTrue(tree.resize(3, direction: .down, by: 0.1))
        // Pane 3 moving right uses the outer horizontal split.
        XCTAssertTrue(tree.resize(3, direction: .right, by: 0.2))
        XCTAssertEqual(tree.root, .split(.horizontal, ratio: 0.7, first: .leaf(1),
                                         second: .split(.vertical, ratio: 0.6, first: .leaf(2), second: .leaf(3))))
        // Pane 1 has no vertical split above it.
        XCTAssertFalse(tree.resize(1, direction: .up))
    }

    func testResizeIsClamped() {
        var tree = LayoutTree(pane: 1)
        tree.split(1, axis: .horizontal, newPane: 2)
        for _ in 0..<30 { tree.resize(1, direction: .left, by: 0.1) }
        guard case .split(_, let ratio, _, _) = tree.root else { return XCTFail() }
        XCTAssertEqual(ratio, LayoutTree.minRatio, accuracy: 1e-9)
    }

    func testSetRatioAtPath() {
        var tree = threePanes()
        tree.setRatio(at: [1], to: 0.25)
        XCTAssertEqual(tree.root, .split(.horizontal, ratio: 0.5, first: .leaf(1),
                                         second: .split(.vertical, ratio: 0.25, first: .leaf(2), second: .leaf(3))))
        XCTAssertEqual(tree.pathTo(3), [1, 1])
    }

    func testLeaderKeymap() {
        XCTAssertEqual(LeaderKeymap.action(for: .character("v")), .splitRight)
        XCTAssertEqual(LeaderKeymap.action(for: .character("L")), .resize(.right))
        XCTAssertEqual(LeaderKeymap.action(for: .character("l")), .focus(.right))
        XCTAssertEqual(LeaderKeymap.action(for: .arrow(.up)), .focus(.up))
        XCTAssertEqual(LeaderKeymap.action(for: .character("7")), .goToTab(7))
        XCTAssertEqual(LeaderKeymap.action(for: .escape), .cancel)
        XCTAssertNil(LeaderKeymap.action(for: .character("0")))
    }
}
