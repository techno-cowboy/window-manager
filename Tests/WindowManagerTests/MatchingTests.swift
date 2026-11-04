import XCTest
@testable import WindowManager

final class MatchingTests: XCTestCase {
    private func saved(_ title: String, id: UInt32? = nil, match: String = "", display: String = "d") -> SavedWindow {
        var w = SavedWindow(displayKey: display, frame: CGRect(x: 0, y: 0, width: 1, height: 1), title: title, windowID: id)
        w.titleMatch = match
        return w
    }

    /// Re-docking: same windows, but the titles changed (other tab active) and the
    /// z-order flipped. The window number must win.
    func testWindowIDBeatsTitleAndOrder() {
        let s = [saved("Pflanzen", id: 100), saved("Dashboard | sellerboard", id: 200)]
        let live: [(id: CGWindowID?, title: String)] = [(200, "Pflanzen"), (100, "Gmail")]
        XCTAssertEqual(WindowMover.match(live, to: s), [0: 1, 1: 0])
    }

    /// After a browser restart the IDs are new; the title filter identifies the window.
    func testTitleFilterAfterRestart() {
        let s = [saved("Pflanzen", id: 100), saved("Dashboard", id: 200, match: "sellerboard")]
        let live: [(id: CGWindowID?, title: String)] = [(901, "Orders | Sellerboard"), (902, "Pflanzen")]
        XCTAssertEqual(WindowMover.match(live, to: s), [0: 1, 1: 0])
    }

    func testExactTitleThenOrder() {
        let s = [saved("A"), saved("B"), saved("C")]
        let live: [(id: CGWindowID?, title: String)] = [(1, "X"), (2, "B"), (3, "Y")]
        // "B" by title, the rest front-to-back.
        XCTAssertEqual(WindowMover.match(live, to: s), [1: 1, 0: 0, 2: 2])
    }

    /// A saved window with a title filter must not be taken by an arbitrary window.
    func testFilteredWindowIsNotMatchedByOrder() {
        let s = [saved("Dashboard", match: "sellerboard"), saved("Pflanzen")]
        let live: [(id: CGWindowID?, title: String)] = [(1, "Gmail"), (2, "News")]
        XCTAssertEqual(WindowMover.match(live, to: s), [0: 1])
    }

    /// A minimized window keeps its slot instead of handing it to another window.
    func testHiddenWindowKeepsItsSlot() {
        let s = [saved("A", id: 10), saved("B", id: 20)]
        let live: [(id: CGWindowID?, title: String)] = [(30, "C")]
        XCTAssertEqual(WindowMover.match(live, to: s, hiddenIDs: [10]), [0: 1])
    }

    func testExtraWindowsStayUnmatched() {
        let s = [saved("A", id: 1)]
        let live: [(id: CGWindowID?, title: String)] = [(2, "B"), (1, "A")]
        XCTAssertEqual(WindowMover.match(live, to: s), [1: 0])
    }

    func testNormalizeRoundTrip() {
        let screen = CGRect(x: -2040, y: 1142, width: 1920, height: 1050)
        let window = CGRect(x: -2000, y: 1200, width: 900, height: 700)
        let back = WindowMover.denormalize(WindowMover.normalize(window, in: screen), in: screen)
        XCTAssertEqual(back.minX, window.minX, accuracy: 0.001)
        XCTAssertEqual(back.minY, window.minY, accuracy: 0.001)
        XCTAssertEqual(back.width, window.width, accuracy: 0.001)
        XCTAssertEqual(back.height, window.height, accuracy: 0.001)
    }

    // MARK: - Planning (real setup: 3× B24-8 above the MacBook)

    private let left = ScreenRef(key: "6835-2175-811276", systemName: "B24-8 (3)", displayID: 88,
                                 frame: CGRect(x: -2040, y: -1080, width: 1920, height: 1080),
                                 visibleFrame: CGRect(x: -2040, y: -1080, width: 1920, height: 1080), isBuiltin: false)
    private let middle = ScreenRef(key: "6835-2175-811280", systemName: "B24-8 (2)", displayID: 89,
                                   frame: CGRect(x: -120, y: -1080, width: 1920, height: 1080),
                                   visibleFrame: CGRect(x: -120, y: -1080, width: 1920, height: 1080), isBuiltin: false)

    /// Crest rule as saved: two windows on different displays, placement "keep position"
    /// (inherited from a layout of the first version).
    private func crestRule(_ placement: Placement) -> Rule {
        Rule(bundleID: "com.pauldavis.crest", appName: "Crest", displayKey: middle.key, placement: placement, windows: [
            saved("Dashboard | sellerboard", id: 90649, display: middle.key),
            saved("Pflanzen", id: 90783, display: left.key),
        ])
    }

    /// Regression: with "keep position", every window went to the app's main display,
    /// so the second Crest window never reached its own display.
    func testEachWindowGoesToItsOwnDisplayWithKeepPosition() {
        let live: [(id: CGWindowID?, title: String, frame: CGRect)] = [
            (90783, "Pflanzen", CGRect(x: -578, y: -987, width: 1920, height: 1050)),        // mostly on middle
            (90649, "Dashboard | sellerboard", CGRect(x: -120, y: -1050, width: 1920, height: 1050)), // already right
        ]
        let plan = WindowMover.plan(live, rule: crestRule(.keepRelative), screens: [left, middle])
        XCTAssertEqual(Array(plan.frames.keys), [0], "only Pflanzen needs to move")
        let f = plan.frames[0]!
        XCTAssertTrue(left.frame.contains(f), "Pflanzen must land on the left display, got \(f)")
    }

    func testEachWindowGoesToItsOwnDisplayWithMaximize() {
        let live: [(id: CGWindowID?, title: String, frame: CGRect)] = [
            (90783, "Pflanzen", CGRect(x: 0, y: -1000, width: 800, height: 600)),
            (90649, "Dashboard | sellerboard", CGRect(x: 100, y: -900, width: 800, height: 600)),
        ]
        let plan = WindowMover.plan(live, rule: crestRule(.maximize), screens: [left, middle])
        XCTAssertEqual(plan.frames[0], left.visibleFrame)
        XCTAssertEqual(plan.frames[1], middle.visibleFrame)
    }

    func testSavedPositionUsesEachWindowsDisplay() {
        let live: [(id: CGWindowID?, title: String, frame: CGRect)] = [
            (90649, "Dashboard | sellerboard", CGRect(x: -2040, y: -1080, width: 1920, height: 1080)),
            (90783, "Pflanzen", CGRect(x: -120, y: -1080, width: 1920, height: 1080)),
        ]
        let plan = WindowMover.plan(live, rule: crestRule(.saved), screens: [left, middle])
        XCTAssertEqual(plan.frames[0], middle.visibleFrame)
        XCTAssertEqual(plan.frames[1], left.visibleFrame)
    }

    /// A window that matches nothing goes to the rule's main display.
    func testUnmatchedWindowGoesToMainDisplay() {
        let rule = Rule(bundleID: "x", appName: "X", displayKey: middle.key, placement: .keepRelative,
                        windows: [saved("A", id: 1, match: "only-this", display: left.key)])
        let live: [(id: CGWindowID?, title: String, frame: CGRect)] = [(2, "Other", CGRect(x: -2000, y: -1000, width: 800, height: 600))]
        let plan = WindowMover.plan(live, rule: rule, screens: [left, middle])
        XCTAssertTrue(middle.frame.contains(plan.frames[0]!))
    }

    /// Layouts saved by the previous version (savedFrames) still load.
    func testDecodesPreviousFormat() throws {
        let json = """
        {"bundleID":"com.pauldavis.crest","appName":"Crest","displayKey":"6835-2175-811276",
         "placement":"saved","enabled":true,
         "savedFrames":[[[0.1,0.2],[0.5,0.5]],[[0,0],[1,1]]]}
        """
        let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        XCTAssertEqual(rule.windows.count, 2)
        XCTAssertEqual(rule.windows[0].displayKey, "6835-2175-811276")
        XCTAssertEqual(rule.windows[0].frame, CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5))

        let reencoded = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(reencoded.windows.map(\.frame), rule.windows.map(\.frame))
    }
}
