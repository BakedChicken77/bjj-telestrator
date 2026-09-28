import XCTest

final class BJJWorkflowTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        // This workflow includes cold launch, import, relaunch and a real export.
        // Keep each control's bounded wait; allow simulator scheduling overhead.
        executionTimeAllowance = 240
        app = XCUIApplication()
        app.launchEnvironment["BJJ_UI_TEST_SESSION"] = UUID().uuidString
        XCUIDevice.shared.orientation = .portrait
    }
    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "native-ui-failure"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }
    private func openReview() {
        let review = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "review.")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 60), app.debugDescription)
        review.tap()
        XCTAssertTrue(app.buttons["editor.cues"].waitForExistence(timeout: 20))
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: app.buttons["editor.export"])
        waitForExpectations(timeout: 30)
    }
    func testDrawUndoReopenAndExport() throws {
        app.launch(); openReview()
        app.segmentedControls.buttons["Draw"].tap()
        let canvas = app.otherElements["editor.video"]
        XCTAssertTrue(canvas.exists)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.48))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55)))
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        app.buttons["Redo"].tap()
        app.buttons["editor.cues"].tap()
        XCTAssertTrue(app.buttons["Edit arrow properties"].waitForExistence(timeout: 10))
        app.buttons["cues.done"].tap()
        app.buttons["editor.done"].tap()
        app.terminate(); app.launch(); openReview()
        app.buttons["editor.cues"].tap()
        XCTAssertTrue(app.buttons["Edit arrow properties"].waitForExistence(timeout: 10))
        app.buttons["cues.done"].tap()
        app.buttons["editor.export"].tap()
        let export = app.buttons["export.start"]
        if !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout: 10)); export.tap()
        XCTAssertTrue(app.navigationBars["Export ready"].waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(app.buttons["Share / Save to Files"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "native-ui-export-ready"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["export.done"].tap()
        XCTAssertTrue(app.buttons["editor.done"].waitForExistence(timeout: 10))
        app.buttons["editor.done"].tap()
    }
    func testCueLabelOpensVisibleVideoRangeEditor() throws {
        app.launch(); openReview()
        app.segmentedControls.buttons["Draw"].tap()
        let canvas = app.otherElements["editor.video"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        let label = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cue.strip.")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10)); label.tap()
        let start = app.descendants(matching: .any)["cue.range.start"].firstMatch
        let end = app.descendants(matching: .any)["cue.range.end"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription); XCTAssertTrue(end.exists)
        XCTAssertGreaterThan(canvas.frame.height, 100)
        XCTAssertLessThanOrEqual(canvas.frame.maxY, start.frame.minY)
        let oldValue = start.value as? String
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: start.coordinate(withNormalizedOffset: CGVector(dx: 2, dy: 0.5)))
        XCTAssertNotEqual(start.value as? String, oldValue)
        let editedValue = start.value as? String
        let portrait = XCTAttachment(screenshot: app.screenshot())
        portrait.name = "native-cue-range-portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        let save = app.buttons["cue.properties.save"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: save)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(start.value as? String, editedValue, "Rotation must preserve the draft")
        XCTAssertLessThanOrEqual(canvas.frame.maxX, start.frame.minX)
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "native-cue-range-landscape"; landscape.lifetime = .keepAlways; add(landscape)
        save.tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(label.waitForExistence(timeout: 10)); label.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10)); XCTAssertEqual(start.value as? String, editedValue)
        app.buttons["cue.properties.cancel"].tap()
        app.buttons["editor.done"].tap()
    }
    func testCueEndHandleCancellationPreservesSavedTiming() throws {
        app.launch(); openReview()
        app.segmentedControls.buttons["Draw"].tap()
        let canvas = app.otherElements["editor.video"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        let label = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cue.strip.")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10)); label.tap()
        let end = app.descendants(matching: .any)["cue.range.end"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        let savedEnd = try XCTUnwrap(end.value as? String)
        end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: end.coordinate(withNormalizedOffset: CGVector(dx: -1, dy: 0.5)))
        XCTAssertNotEqual(end.value as? String, savedEnd)
        XCTAssertGreaterThan(canvas.frame.height, 100)
        XCTAssertLessThanOrEqual(canvas.frame.maxY, end.frame.minY)
        app.buttons["cue.properties.cancel"].tap()
        XCTAssertTrue(label.waitForExistence(timeout: 10)); label.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        XCTAssertEqual(end.value as? String, savedEnd, "Cancel must discard the end-handle draft")
        app.buttons["cue.properties.cancel"].tap()
        app.buttons["editor.done"].tap()
    }
    func testNativeSheetsRemainDismissibleAfterRotation() throws {
        app.launch(); openReview()
        app.buttons["Narration"].tap()
        XCTAssertTrue(app.switches["Mute original"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        let done = app.buttons["narration.done"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: done)
        waitForExpectations(timeout: 10)
        done.tap()
        XCUIDevice.shared.orientation = .portrait
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.navigationBars["Export video"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["editor.done"].waitForExistence(timeout: 10))
    }
}
