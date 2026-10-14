import XCTest
@testable import ExplorerCore

final class TabPlacementTests: XCTestCase {
    func testDropsAtBothEndsAndAcrossNeighbours() {
        XCTAssertEqual(TabPlacement.destination(from: 0, before: 4, count: 4), 3)
        XCTAssertEqual(TabPlacement.destination(from: 3, before: 0, count: 4), 0)
        XCTAssertEqual(TabPlacement.destination(from: 1, before: 3, count: 4), 2)
        XCTAssertEqual(TabPlacement.destination(from: 2, before: 1, count: 4), 1)
    }
    func testDropsOnEitherSideOfSelfDoNotChangeOrder() {
        for count in 1...20 {
            for source in 0..<count {
                XCTAssertEqual(TabPlacement.destination(from: source, before: source, count: count), source)
                XCTAssertEqual(TabPlacement.destination(from: source, before: source + 1, count: count), source)
            }
        }
    }
    func testEverySlotPreservesIdentityAndRelativeOrderOfOtherTabs() throws {
        for count in 1...20 {
            let original = (0..<count).map { _ in UUID() }
            for source in original.indices {
                for slot in 0...count {
                    var result = original
                    let destination = try XCTUnwrap(TabPlacement.destination(from: source, before: slot, count: count))
                    let moved = result.remove(at: source); result.insert(moved, at: destination)
                    XCTAssertEqual(result.count, count)
                    XCTAssertEqual(Set(result), Set(original))
                    XCTAssertEqual(result.filter { $0 != moved }, original.filter { $0 != moved })
                    XCTAssertEqual(result[destination], original[source])
                }
            }
        }
    }
    func testInvalidAndStaleSlotsAreRejected() {
        for (source, slot, count) in [(-1, 0, 2), (2, 0, 2), (0, -1, 2), (0, 3, 2), (0, 0, 0)] {
            XCTAssertNil(TabPlacement.destination(from: source, before: slot, count: count))
        }
    }
    func testOnlyUnacceptedReleaseOutsideWindowDetaches() {
        XCTAssertTrue(TabPlacement.shouldDetach(accepted: false, cancelled: false, mouseReleased: true, outsideSourceWindow: true))
        // Returning to the source, dropping onto another tab bar, Escape, and
        // ending a drag while its mouse button is held must never tear off.
        XCTAssertFalse(TabPlacement.shouldDetach(accepted: false, cancelled: false, mouseReleased: true, outsideSourceWindow: false))
        XCTAssertFalse(TabPlacement.shouldDetach(accepted: true, cancelled: false, mouseReleased: true, outsideSourceWindow: true))
        XCTAssertFalse(TabPlacement.shouldDetach(accepted: false, cancelled: true, mouseReleased: true, outsideSourceWindow: true))
        XCTAssertFalse(TabPlacement.shouldDetach(accepted: false, cancelled: false, mouseReleased: false, outsideSourceWindow: true))
    }
}
