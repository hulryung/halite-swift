import XCTest
@testable import DamsonTerminal

/// Tests for the pure tmux layout-string parser (`%layout-change` payload → N-ary tree).
/// No tmux process involved — these strings are the exact format tmux emits (docs §4.9).
final class TmuxLayoutTreeTests: XCTestCase {

    // MARK: - Single pane

    func testSinglePaneWithChecksum() {
        // `e7b2,80x24,0,0,1` — one window-filling pane %1, with a leading checksum.
        let tree = TmuxLayoutTree.parse("e7b2,80x24,0,0,1")
        XCTAssertEqual(tree, .leaf(pane: TmuxPaneID(1), width: 80, height: 24, x: 0, y: 0))
    }

    func testSinglePaneWithoutChecksum() {
        // A bare cell (no checksum prefix) parses identically.
        let tree = TmuxLayoutTree.parse("80x24,0,0,1")
        XCTAssertEqual(tree, .leaf(pane: TmuxPaneID(1), width: 80, height: 24, x: 0, y: 0))
    }

    // MARK: - Horizontal split (left/right, `{…}`)

    func testHorizontalSplitTwoPanes() {
        // The docs §4.9 example: two side-by-side panes.
        let tree = TmuxLayoutTree.parse("e7b2,80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        XCTAssertEqual(tree, .split(
            orientation: .horizontal, width: 80, height: 24, x: 0, y: 0,
            children: [
                .leaf(pane: TmuxPaneID(1), width: 40, height: 24, x: 0, y: 0),
                .leaf(pane: TmuxPaneID(2), width: 39, height: 24, x: 41, y: 0),
            ]
        ))
        XCTAssertEqual(tree?.paneIDs, [TmuxPaneID(1), TmuxPaneID(2)])
    }

    // MARK: - Vertical split (top/bottom, `[…]`)

    func testVerticalSplitTwoPanes() {
        let tree = TmuxLayoutTree.parse("abcd,80x24,0,0[80x12,0,0,1,80x11,0,13,2]")
        XCTAssertEqual(tree, .split(
            orientation: .vertical, width: 80, height: 24, x: 0, y: 0,
            children: [
                .leaf(pane: TmuxPaneID(1), width: 80, height: 12, x: 0, y: 0),
                .leaf(pane: TmuxPaneID(2), width: 80, height: 11, x: 0, y: 13),
            ]
        ))
    }

    // MARK: - N-ary group (3 children)

    func testThreeWayHorizontalSplit() {
        let tree = TmuxLayoutTree.parse("0001,90x24,0,0{30x24,0,0,1,30x24,31,0,2,28x24,62,0,3}")
        guard case let .split(orientation, _, _, _, _, children)? = tree else {
            return XCTFail("expected split")
        }
        XCTAssertEqual(orientation, .horizontal)
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(tree?.paneIDs, [TmuxPaneID(1), TmuxPaneID(2), TmuxPaneID(3)])
    }

    // MARK: - Nested splits

    func testNestedSplit() {
        // A vertical split whose bottom child is itself a horizontal split:
        // top pane %1 full width; bottom row split into %2 | %3.
        let s = "ffff,80x24,0,0[80x12,0,0,1,80x11,0,13{40x11,0,13,2,39x11,41,13,3}]"
        let tree = TmuxLayoutTree.parse(s)
        guard case let .split(outerOrient, _, _, _, _, outerChildren)? = tree else {
            return XCTFail("expected outer split")
        }
        XCTAssertEqual(outerOrient, .vertical)
        XCTAssertEqual(outerChildren.count, 2)
        XCTAssertEqual(outerChildren[0], .leaf(pane: TmuxPaneID(1), width: 80, height: 12, x: 0, y: 0))
        guard case let .split(innerOrient, _, _, _, _, innerChildren) = outerChildren[1] else {
            return XCTFail("expected inner split")
        }
        XCTAssertEqual(innerOrient, .horizontal)
        XCTAssertEqual(innerChildren.count, 2)
        XCTAssertEqual(tree?.paneIDs, [TmuxPaneID(1), TmuxPaneID(2), TmuxPaneID(3)])
    }

    // MARK: - Malformed input resilience

    // MARK: - totalCellSize (resize negotiation)

    func testTotalCellSizeSinglePane() {
        let tree = TmuxLayoutTree.parse("e7b2,80x24,0,0,1")!
        let size = tree.totalCellSize { _ in (cols: 100, rows: 40) }
        XCTAssertEqual(size?.cols, 100)
        XCTAssertEqual(size?.rows, 40)
    }

    func testTotalCellSizeHorizontalAddsDividerColumn() {
        // Two side-by-side panes %1, %2 each measured 40×24 → 40 + 40 + 1 border = 81 cols,
        // rows = max(24, 24) = 24.
        let tree = TmuxLayoutTree.parse("e7b2,80x24,0,0{40x24,0,0,1,39x24,41,0,2}")!
        let size = tree.totalCellSize { _ in (cols: 40, rows: 24) }
        XCTAssertEqual(size?.cols, 81)
        XCTAssertEqual(size?.rows, 24)
    }

    func testTotalCellSizeVerticalAddsDividerRow() {
        // Two stacked panes %1, %2 each 80×12 → cols = max(80,80) = 80, rows = 12+12+1 = 25.
        let tree = TmuxLayoutTree.parse("abcd,80x24,0,0[80x12,0,0,1,80x11,0,13,2]")!
        let size = tree.totalCellSize { _ in (cols: 80, rows: 12) }
        XCTAssertEqual(size?.cols, 80)
        XCTAssertEqual(size?.rows, 25)
    }

    func testTotalCellSizeNilUntilAllLeavesMeasured() {
        // If a pane has no measured size yet, the whole computation is withheld.
        let tree = TmuxLayoutTree.parse("e7b2,80x24,0,0{40x24,0,0,1,39x24,41,0,2}")!
        let size = tree.totalCellSize { pane in pane == TmuxPaneID(1) ? (cols: 40, rows: 24) : nil }
        XCTAssertNil(size)
    }

    func testTotalCellSizeNestedThreeWay() {
        // Vertical outer: top %1 (80×12) over a horizontal row of %2|%3 (each 40×11).
        // Inner row cols = 40+40+1 = 81, rows = 11. Outer cols = max(80, 81) = 81,
        // rows = 12 + 11 + 1 divider = 24.
        let s = "ffff,80x24,0,0[80x12,0,0,1,80x11,0,13{40x11,0,13,2,39x11,41,13,3}]"
        let tree = TmuxLayoutTree.parse(s)!
        let sizes: [TmuxPaneID: (cols: Int, rows: Int)] = [
            TmuxPaneID(1): (80, 12), TmuxPaneID(2): (40, 11), TmuxPaneID(3): (40, 11),
        ]
        let size = tree.totalCellSize { sizes[$0] }
        XCTAssertEqual(size?.cols, 81)
        XCTAssertEqual(size?.rows, 24)
    }

    func testMalformedReturnsNil() {
        XCTAssertNil(TmuxLayoutTree.parse(""))
        XCTAssertNil(TmuxLayoutTree.parse("garbage"))
        XCTAssertNil(TmuxLayoutTree.parse("80x24"))          // no offsets/id
        XCTAssertNil(TmuxLayoutTree.parse("80x24,0,0"))      // no id and no group
        XCTAssertNil(TmuxLayoutTree.parse("80x24,0,0{40x24,0,0,1}"))  // single-child group
        XCTAssertNil(TmuxLayoutTree.parse("80x24,0,0{40x24,0,0,1"))   // unterminated group
        XCTAssertNil(TmuxLayoutTree.parse("e7b2,80x24,0,0,1,trailing"))  // trailing junk
    }
}
