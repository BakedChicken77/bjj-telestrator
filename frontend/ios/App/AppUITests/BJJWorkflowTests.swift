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
        if app.buttons["home.reviews"].waitForExistence(timeout: 10) {
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["home.reviews"])
            waitForExpectations(timeout: 60)
            app.buttons["home.reviews"].tap()
        }
        let review = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "review.")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 60), app.debugDescription)
        review.tap()
        XCTAssertTrue(app.buttons["editor.cues"].waitForExistence(timeout: 20))
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: app.buttons["editor.export"])
        waitForExpectations(timeout: 30)
    }
    func testOptionalTipsCustomValidationAndLandscapeDismissal() throws {
        app.launchEnvironment["BJJ_UI_TEST_TIPS"] = "1"
        app.launch()
        let support = app.buttons["tips.open"]
        XCTAssertTrue(support.waitForExistence(timeout: 60))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: support)
        waitForExpectations(timeout: 30)
        if !support.isHittable { app.swipeUp() }
        support.tap()
        let five = app.buttons["tips.five"]
        XCTAssertTrue(five.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: five)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(five.label, "Tip $5.00")
        XCTAssertTrue(app.buttons["tips.custom"].exists)
        let portrait = XCTAttachment(screenshot: app.screenshot())
        portrait.name = "native-tips-portrait"; portrait.lifetime = .keepAlways; add(portrait)
        app.buttons["tips.custom"].tap()
        let amount = app.textFields["tips.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        amount.tap(); amount.typeText("11")
        XCTAssertFalse(app.buttons["tips.confirm"].isEnabled)
        amount.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "10")
        XCTAssertTrue(app.buttons["tips.confirm"].isEnabled)
        XCTAssertEqual(app.buttons["tips.confirm"].label, "Tip $10.00")
        app.buttons["tips.keyboard.done"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in self.app.frame.width > self.app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        let close = app.buttons["tips.close"].firstMatch
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: close)
        waitForExpectations(timeout: 10)
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "native-tips-custom-landscape"; landscape.lifetime = .keepAlways; add(landscape)
        close.tap()
        XCTAssertTrue(support.waitForExistence(timeout: 10))
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
    func testInspectorCollapseCanvasCancelDeleteAndUndo() throws {
        app.launch(); openReview()
        app.segmentedControls.buttons["Draw"].tap()
        let canvas = app.otherElements["editor.video"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        let label = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cue.strip.")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10)); label.tap()
        let collapse = app.buttons["cue.properties.collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 10))
        let before = canvas.frame.height
        collapse.tap(); XCTAssertGreaterThan(canvas.frame.height, before)
        collapse.tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)))
        XCTAssertTrue(app.buttons["cue.properties.save"].exists)
        app.buttons["cue.properties.cancel"].tap()
        label.tap()
        let delete = app.buttons["cue.properties.delete"]
        let form = app.descendants(matching: .any)["cue.properties.form"].firstMatch
        XCTAssertTrue(form.exists)
        for _ in 0..<10 { if delete.isHittable { break }; form.swipeUp() }
        XCTAssertTrue(delete.isHittable); delete.tap()
        XCTAssertFalse(label.exists)
        app.buttons["Undo"].tap()
        XCTAssertTrue(label.waitForExistence(timeout: 10))
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
