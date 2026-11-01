import XCTest

final class CamlabUITests: XCTestCase {
    @MainActor func testReturningFromBackgroundKeepsCameraUIResponsive() throws {
        let app = launchPortrait()
        for _ in 0..<3 {
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
            let grid = app.buttons["quickGrid"]
            XCTAssertTrue(grid.waitForExistence(timeout: 5))
            let before = grid.value as? String
            grid.tap()
            XCTAssertNotEqual(grid.value as? String, before)
            #if targetEnvironment(simulator)
            // A completed discovery on return, rather than a stuck startup spinner.
            XCTAssertTrue(app.staticTexts["cameraError"].waitForExistence(timeout: 5))
            #endif
        }
    }

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testBuiltInShootingStylesCanBeSelectedInBothOrientations() throws {
        let app = launchPortrait(native: true)
        chooseNatural(app)
        let toggle = app.buttons["openRecipes"]
        XCTAssertLessThanOrEqual(toggle.frame.width, 44)
        let viewfinder = app.otherElements["cameraViewfinder"].firstMatch
        XCTAssertLessThan(abs(toggle.frame.minX - viewfinder.frame.minX), 12)
        chooseStyle("復古", scene: "老街、古物", in: app)
        app.buttons["adjustControls"].tap()
        XCTAssertTrue(app.buttons["comparePreview"].isEnabled)
        app.buttons["收起調整"].tap()
        XCTAssertEqual(app.buttons["openRecipes"].value as? String, "復古")
        XCTAssertTrue(app.buttons["capturePhoto"].isHittable)
        attach(app, "風格拍攝-精簡主畫面")

        toggle.tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["capturePhoto"].isHittable)
        wheel.swipeUp()
        let switched = NSPredicate { _, _ in toggle.value as? String != "復古" }
        expectation(for: switched, evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        wheel.adjust(toPickerWheelValue: "冷調 · 海邊、港口")
        XCTAssertEqual(app.staticTexts["currentStyleName"].label, "冷調")
        wheel.adjust(toPickerWheelValue: "咖啡暖棕 · 咖啡、甜點")
        XCTAssertEqual(toggle.value as? String, "咖啡暖棕")
        XCTAssertEqual(app.staticTexts["currentStyleName"].label, "咖啡暖棕")
        attach(app, "風格選單-完整名稱與適用情境")
        viewfinder.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.4)).tap()
        XCTAssertFalse(wheel.exists)
        app.buttons["adjustControls"].tap()
        XCTAssertEqual(app.buttons["輸入飽和度數值"].value as? String, "-16")
        XCTAssertFalse(app.buttons["更新配方"].isEnabled)
        app.buttons["收起調整"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        chooseNatural(app)
        XCTAssertEqual(app.buttons["openRecipes"].value as? String, "原色")
        XCTAssertTrue(app.buttons["capturePhoto"].isHittable)
        attach(app, "風格拍攝-橫向原色")
    }

    @MainActor func testDetailAdjustmentsAreReachableAndRespectRanges() throws {
        let app = launchPortrait()
        chooseNatural(app)
        app.buttons["adjustControls"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let horizontal = NSPredicate { _, _ in app.frame.width > app.frame.height }
        expectation(for: horizontal, evaluatedWith: app); waitForExpectations(timeout: 5)
        let list = app.scrollViews["recipeParameterList"]
        for (key, title) in [("sharpness", "銳利度"), ("definition", "清晰度"), ("noiseReduction", "降低雜點"), ("vignette", "暈邊")] {
            let option = app.buttons["parameter-\(key)"]
            for _ in 0..<6 {
                if option.isHittable { break }
                list.swipeUp()
            }
            XCTAssertTrue(option.isHittable, title)
            option.tap()
            app.buttons["輸入\(title)數值"].tap()
            XCTAssertEqual(app.buttons["正負號"].isEnabled, key == "vignette")
            app.buttons["4"].tap(); app.buttons["7"].tap()
            if key == "vignette" { app.buttons["正負號"].tap() }
            app.buttons["完成"].tap()
            XCTAssertEqual(app.buttons["輸入\(title)數值"].value as? String, key == "vignette" ? "-47" : "47")
        }
        app.buttons["parameter-definition"].tap()
        attach(app, "細節調整-橫向清晰度")
        XCUIDevice.shared.orientation = .portrait
        let vertical = NSPredicate { _, _ in app.frame.height > app.frame.width }
        expectation(for: vertical, evaluatedWith: app); waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["輸入清晰度數值"].isHittable)
        XCTAssertEqual(app.buttons["輸入清晰度數值"].value as? String, "47")
        XCTAssertTrue(app.sliders["recipeSlider"].isHittable)
        attach(app, "細節調整-直向清晰度")
    }

    @MainActor func testRotationImmediatelyAfterLaunchKeepsCameraResponsive() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let isLandscape = orientation.isLandscape
            let rotated = NSPredicate { _, _ in (app.frame.width > app.frame.height) == isLandscape }
            expectation(for: rotated, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(app.otherElements["cameraViewfinder"].firstMatch.exists)
        }
        #if !targetEnvironment(simulator)
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: app.buttons["capturePhoto"])
        waitForExpectations(timeout: 20)
        #endif
        app.buttons["adjustControls"].tap()
        XCTAssertTrue(app.otherElements["inlineCameraControls"].waitForExistence(timeout: 5))
    }

    @MainActor func testMainControlsKeepTheViewfinderUncluttered() throws {
        let app = launchPortrait()
        chooseNatural(app)
        let adjust = app.buttons["adjustControls"]
        let library = app.buttons["photoLibrary"]
        let shutter = app.buttons["capturePhoto"]
        let lens = app.buttons["cameraLens"]
        XCTAssertLessThan(library.frame.midX, shutter.frame.midX)
        XCTAssertEqual(library.frame.midY, shutter.frame.midY, accuracy: 4)
        XCTAssertGreaterThanOrEqual(library.frame.width, 48)
        XCTAssertTrue(library.isHittable)
        XCTAssertGreaterThan(lens.frame.midX, shutter.frame.midX)
        XCTAssertEqual(shutter.frame.midX, app.frame.midX, accuracy: 24)
        XCTAssertFalse(app.buttons["comparePreview"].exists)
        XCTAssertTrue(app.buttons["匯入相簿照片"].exists)
        let preview = app.otherElements["cameraViewfinder"].firstMatch
        XCTAssertLessThan(preview.frame.minY, app.frame.height * 0.2)
        XCTAssertLessThanOrEqual(adjust.frame.maxY, preview.frame.minY)
        XCTAssertFalse(app.scrollViews["recipeShortcuts"].exists)
        XCTAssertTrue(app.buttons["quickGrid"].isHittable)
        XCTAssertTrue(app.buttons["quickLevel"].isHittable)
        XCTAssertEqual(app.staticTexts["currentStyleName"].frame.midX, app.frame.midX, accuracy: 3)
        XCTAssertTrue(app.buttons["cameraPreferences"].isHittable)
        XCTAssertGreaterThanOrEqual(adjust.frame.width, 44)
        attach(app, "實際介面-直向收合")
        adjust.tap()
        XCTAssertTrue(app.otherElements["inlineCameraControls"].exists)
        let compare = app.buttons["comparePreview"]
        XCTAssertTrue(compare.isHittable)
        compare.tap()
        XCTAssertEqual(compare.label, "返回效果")
        app.buttons["收起調整"].tap()
        adjust.tap()
        XCTAssertEqual(compare.label, "原圖比較")
        attach(app, "實際介面-直向調色")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let horizontal = NSPredicate { _, _ in app.frame.width > app.frame.height }
        expectation(for: horizontal, evaluatedWith: app); waitForExpectations(timeout: 5)
        XCTAssertLessThan(library.frame.midY, shutter.frame.midY)
        XCTAssertTrue(library.isHittable)
        XCTAssertTrue(app.frame.contains(library.frame))
        XCTAssertGreaterThan(lens.frame.midY, shutter.frame.midY)
        XCTAssertEqual(shutter.frame.midY, app.frame.midY, accuracy: 30)
        let controls = app.otherElements["inlineCameraControls"].firstMatch
        XCTAssertLessThanOrEqual(controls.frame.width, 170)
        XCTAssertGreaterThan(controls.frame.height, app.frame.height * 0.8)
        XCTAssertTrue(app.scrollViews["recipeParameterList"].exists)
        attach(app, "實際介面-橫向調色")
        let list = app.scrollViews["recipeParameterList"]
        list.swipeDown()
        let blackPoint = app.buttons["parameter-blackPoint"]
        if !blackPoint.isHittable { list.swipeUp() }
        blackPoint.tap()
        XCTAssertTrue(app.buttons["輸入黑點數值"].waitForExistence(timeout: 3))
    }

    @MainActor func testSimulatorExplainsMissingCameraWithoutReconnectPrompt() throws {
        #if targetEnvironment(simulator)
        let app = launchPortrait()
        let error = app.staticTexts["cameraError"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(error.label.contains("實體 iPhone 或 iPad"))
        XCTAssertTrue(app.buttons["capturePhoto"].exists)
        XCTAssertFalse(app.buttons["capturePhoto"].isEnabled)
        XCTAssertFalse(app.buttons["重新連線"].exists)
        XCTAssertFalse(app.buttons["retryCamera"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["retryCamera"].exists)
        #else
        throw XCTSkip("模擬器限定")
        #endif
    }

    @MainActor func testRecipeSaveAndUnsavedChangesAreDiscardedOnRelaunch() throws {
        let app = launchPortrait()
        chooseNatural(app)
        app.buttons["調整參數"].tap()
        enterSaturation(app, digits: ["2", "0"])
        let name = "測試配方-\(UUID().uuidString.prefix(6))"
        saveNew(app, name: name)
        enterSaturation(app, digits: ["3", "0"])
        XCTAssertEqual(app.buttons["輸入飽和度數值"].value as? String, "30")
        app.terminate(); app.launch()
        app.buttons["調整參數"].tap()
        XCTAssertEqual(app.buttons["輸入飽和度數值"].value as? String, "20")
        XCTAssertTrue(app.buttons["openRecipes"].exists)
        chooseNatural(app)
        XCTAssertEqual(app.buttons["輸入飽和度數值"].value as? String, "0")
        chooseStyle(name, scene: "同系列續拍", in: app)
        XCTAssertEqual(app.buttons["輸入飽和度數值"].value as? String, "20")
    }

    @MainActor func testIntegerKeypadKeepsPreviewAndShutterVisible() throws {
        let app = launchPortrait()
        chooseNatural(app)
        app.buttons["調整參數"].tap()
        app.buttons["輸入飽和度數值"].tap()
        let preview = app.otherElements["cameraViewfinder"].firstMatch
        let controls = app.otherElements["inlineCameraControls"].firstMatch
        XCTAssertTrue(preview.exists && controls.exists)
        XCTAssertGreaterThan(preview.frame.height, app.frame.height * 0.35)
        // Read geometry after the panel/preview transition has settled.
        expectation(for: NSPredicate { _, _ in
            preview.frame.maxY <= controls.frame.minY + 2
        }, evaluatedWith: app)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.buttons["capturePhoto"].isHittable)
        XCTAssertFalse(app.buttons["."].exists)
        app.buttons["2"].tap(); app.buttons["0"].tap()
        XCTAssertEqual(app.staticTexts["numericDraft"].label, "20")
        app.buttons["完成"].tap()
        XCTAssertEqual(app.buttons["輸入飽和度數值"].value as? String, "20")
        attach(app, "直向即時調色")
    }

    @MainActor func testLandscapeControlsAndKeypadLeaveLargePreview() throws {
        let app = launchPortrait()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let horizontal = NSPredicate { _, _ in app.frame.width > app.frame.height }
        expectation(for: horizontal, evaluatedWith: app); waitForExpectations(timeout: 5)
        let preview = app.otherElements["cameraViewfinder"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        // A 4:3 image on a wide phone cannot occupy 65% of total screen
        // width without cropping. Maximize its height and retain its framing.
        XCTAssertGreaterThan(preview.frame.height, app.frame.height * 0.85)
        XCTAssertGreaterThan(preview.frame.width, app.frame.height * 1.1)
        app.buttons["調整參數"].tap()
        XCTAssertGreaterThan(preview.frame.width, app.frame.height * 0.95)
        XCTAssertGreaterThan(preview.frame.height, app.frame.height * 0.7)
        app.buttons["輸入飽和度數值"].tap()
        XCTAssertGreaterThan(preview.frame.width, app.frame.height * 0.95)
        XCTAssertTrue(app.buttons["capturePhoto"].isHittable)
        attach(app, "橫向數字輸入保留預覽")
        app.buttons["完成"].tap()
        app.buttons["adjustControls"].tap()
        XCTAssertGreaterThan(preview.frame.height, app.frame.height * 0.85)
    }

    @MainActor func testLevelGridAndZoomControlsAreReachable() throws {
        let app = launchPortrait()
        let quickGrid = app.buttons["quickGrid"], quickLevel = app.buttons["quickLevel"]
        let initialGrid = quickGrid.value as? String, initialLevel = quickLevel.value as? String
        quickGrid.tap(); quickLevel.tap()
        XCTAssertNotEqual(quickGrid.value as? String, initialGrid)
        XCTAssertNotEqual(quickLevel.value as? String, initialLevel)
        app.buttons["cameraPreferences"].tap()
        let level = app.switches["levelToggle"]
        let grid = app.switches["gridToggle"]
        XCTAssertTrue(level.waitForExistence(timeout: 5))
        let oldLevel = level.value as? String
        level.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertNotEqual(level.value as? String, oldLevel)
        let oldGrid = grid.value as? String
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertNotEqual(grid.value as? String, oldGrid)
        app.buttons["完成"].tap()
        app.buttons["cameraPreferences"].tap()
        XCTAssertNotEqual(level.value as? String, oldLevel)
        XCTAssertNotEqual(grid.value as? String, oldGrid)
        app.buttons["完成"].tap()
        XCTAssertEqual(quickGrid.value as? String, initialGrid)
        XCTAssertEqual(quickLevel.value as? String, initialLevel)
        XCTAssertTrue(app.buttons["變焦 1 倍"].exists)
        XCTAssertFalse(app.sliders["viewfinderZoomSlider"].exists)
        XCTAssertFalse(app.otherElements["inlineCameraControls"].exists)
        XCTAssertTrue(app.buttons["capturePhoto"].isHittable)
        XCTAssertTrue(app.buttons["匯入相簿照片"].exists)
    }

    @MainActor func testPhotoEditorKeepsActionsInsideScreen() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("只使用模擬器相簿中的測試圖片")
        #endif
        let app = launchPortrait()
        app.buttons["匯入相簿照片"].tap()
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "libraryPhoto-")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), app.debugDescription)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["closePhotoEditor"].waitForExistence(timeout: 15))
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let rotated = NSPredicate { _, _ in (app.frame.width > app.frame.height) == orientation.isLandscape }
            expectation(for: rotated, evaluatedWith: app); waitForExpectations(timeout: 5)
            assertEditorActionsVisible(app)
            let preview = app.otherElements["photoEditPreview"].firstMatch
            let controls = app.otherElements["photoEditControls"].firstMatch
            XCTAssertTrue(app.frame.contains(preview.frame))
            XCTAssertTrue(app.frame.contains(controls.frame))
            if orientation.isLandscape {
                XCTAssertLessThanOrEqual(preview.frame.maxX, controls.frame.minX)
            } else {
                XCTAssertLessThanOrEqual(preview.frame.maxY, controls.frame.minY)
            }
            app.buttons["輸入飽和度數值"].tap()
            assertEditorActionsVisible(app)
            let adjustments = app.scrollViews["photoEditAdjustments"]
            for key in ["正負號", "0", "退格", "取消輸入"] {
                let button = app.buttons[key]
                XCTAssertTrue(button.isHittable, key)
                XCTAssertTrue(adjustments.frame.contains(button.frame), key)
            }
            app.buttons["2"].tap()
            XCTAssertEqual(app.staticTexts["numericDraft"].label, "2")
            attach(app, orientation.isLandscape ? "照片編輯-橫向鍵盤" : "照片編輯-直向鍵盤")
            app.buttons["finishNumericInput"].tap()
            XCTAssertTrue(app.buttons["輸入飽和度數值"].waitForExistence(timeout: 3))
            app.buttons["compareEditedPhoto"].tap()
            XCTAssertEqual(app.buttons["compareEditedPhoto"].label, "返回成品")
            app.buttons["compareEditedPhoto"].tap()
        }
        app.buttons["editorRecipes"].tap()
        XCTAssertTrue(app.buttons["recipe-原色"].waitForExistence(timeout: 5))
        app.buttons["recipe-原色"].tap()
        assertEditorActionsVisible(app)
        app.buttons["closePhotoEditor"].tap()
        XCTAssertTrue(app.buttons["capturePhoto"].waitForExistence(timeout: 10))
    }

    @MainActor func testDraggingAtLibraryEdgeContinuesSelectingAfterScrolling() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("只使用模擬器的相簿")
        #endif
        let app = launchPortrait()
        app.buttons["photoLibrary"].tap()
        app.buttons["selectLibraryPhotos"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        let scroll = app.scrollViews["photoLibraryScroll"]
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "libraryPhoto-"))
        XCTAssertTrue(photos.element(boundBy: 5).waitForExistence(timeout: 10))
        let bottom = app.buttons["deleteSelectedPhotos"].frame.minY - 12
        let top = app.navigationBars.firstMatch.frame.maxY
        let viewport = CGRect(x: scroll.frame.minX, y: top, width: scroll.frame.width, height: bottom - top)
        let initiallyVisible = photos.allElementsBoundByIndex.filter {
            viewport.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        let first = try XCTUnwrap(initiallyVisible.first)
        let last = try XCTUnwrap(initiallyVisible.last)
        let startY = first.frame.minY
        let start = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let edge = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: last.frame.midX - scroll.frame.minX, dy: bottom - scroll.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 2)
        let remove = app.buttons["deleteSelectedPhotos"]
        let count = Int(remove.label.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
        XCTAssertGreaterThan(count, initiallyVisible.count)
        XCTAssertFalse(first.exists && first.frame.minY == startY)
        app.buttons["完成"].tap()
    }

    @MainActor func testSelectionModeDragSelectsAndDeselectsPhotoRanges() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("只使用模擬器的相簿")
        #endif
        let app = launchPortrait()
        app.buttons["photoLibrary"].tap()
        app.buttons["selectLibraryPhotos"].tap()
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "libraryPhoto-"))
        XCTAssertTrue(photos.element(boundBy: 5).waitForExistence(timeout: 10))
        let first = photos.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let sixth = photos.element(boundBy: 5).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        first.press(forDuration: 0.05, thenDragTo: sixth)
        let remove = app.buttons["deleteSelectedPhotos"]
        XCTAssertEqual(remove.label, "刪除 6 張照片")
        XCTAssertFalse(app.buttons["closePhotoEditor"].exists)
        for index in 0..<6 { XCTAssertEqual(photos.element(boundBy: index).value as? String, "已選取") }
        let third = photos.element(boundBy: 2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        sixth.press(forDuration: 0.05, thenDragTo: third)
        XCTAssertEqual(remove.label, "刪除 2 張照片")
        let initialY = photos.element(boundBy: 0).frame.minY
        app.scrollViews["photoLibraryScroll"].swipeUp()
        XCTAssertEqual(remove.label, "刪除 2 張照片")
        XCTAssertNotEqual(photos.element(boundBy: 0).frame.minY, initialY)
        app.buttons["完成"].tap()
    }

    @MainActor func testCancellingBatchDeletionKeepsTheSelectedPhotos() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("只使用模擬器的相簿")
        #endif
        let app = launchPortrait()
        app.buttons["photoLibrary"].tap()
        app.buttons["selectLibraryPhotos"].tap()
        let remove = app.buttons["deleteSelectedPhotos"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertFalse(remove.isEnabled)
        let thumbnails = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "libraryPhoto-"))
        XCTAssertTrue(thumbnails.element(boundBy: 1).waitForExistence(timeout: 10))
        for index in 0..<2 {
            thumbnails.element(boundBy: index).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertEqual(remove.label, "刪除 2 張照片")
        remove.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "不允許"])).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 8))
        deny.tap()
        XCTAssertEqual(remove.label, "刪除 2 張照片")
        XCTAssertTrue(remove.isEnabled)
        app.buttons["取消多選"].tap()
        XCTAssertFalse(remove.exists)
        let previewedIdentifier = thumbnails.element(boundBy: 0).identifier
        thumbnails.element(boundBy: 0).press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["開啟照片"].waitForExistence(timeout: 5))
        XCTAssertFalse(remove.exists)
        app.buttons["deletePreviewPhoto"].tap()
        XCTAssertTrue(deny.waitForExistence(timeout: 8))
        deny.tap()
        XCTAssertTrue(app.buttons[previewedIdentifier].waitForExistence(timeout: 5))
        XCTAssertFalse(remove.exists)
        app.buttons["selectLibraryPhotos"].tap()
        thumbnails.element(boundBy: 0).tap()
        XCTAssertEqual(remove.label, "刪除 1 張照片")
        XCTAssertFalse(app.buttons["closePhotoEditor"].exists)
        thumbnails.element(boundBy: 1).tap()
        XCTAssertEqual(remove.label, "刪除 2 張照片")
        thumbnails.element(boundBy: 0).tap()
        XCTAssertEqual(remove.label, "刪除 1 張照片")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["photoLibrary"].isHittable)
    }

    @MainActor func testNativePhotoFlowPreservesSystemVersionAndFitsBothOrientations() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("只使用模擬器相簿中的測試圖片")
        #endif
        let app = launchPortrait(native: true)
        app.buttons["adjustControls"].tap()
        XCTAssertEqual(app.buttons["comparePreview"].label, "原色預覽 · 原生調整")
        XCTAssertFalse(app.buttons["comparePreview"].isEnabled)
        app.buttons["匯入相簿照片"].tap()
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "libraryPhoto-")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["closeNativePhoto"].waitForExistence(timeout: 15))
        let share = app.buttons["shareNativePhoto"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: share)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.buttons["saveEditedPhoto"].exists)
        XCTAssertFalse(app.sliders["recipeSlider"].exists)
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            expectation(for: NSPredicate { _, _ in (app.frame.width > app.frame.height) == orientation.isLandscape }, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            for key in ["closeNativePhoto", "selectNativePhoto", "refreshNativePhoto", "shareNativePhoto"] {
                let button = app.buttons[key]
                XCTAssertTrue(button.isHittable, key)
                XCTAssertTrue(app.frame.contains(button.frame), key)
            }
            XCTAssertTrue(app.frame.contains(app.descendants(matching: .any)["nativePhotoPreview"].firstMatch.frame))
            attach(app, orientation.isLandscape ? "原生照片流程-橫向" : "原生照片流程-直向")
        }
        if app.buttons["refreshNativePhoto"].isEnabled {
            app.buttons["deleteCurrentPhoto"].tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let deny = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "不允許"])).firstMatch
            XCTAssertTrue(deny.waitForExistence(timeout: 8))
            deny.tap()
            XCTAssertTrue(app.buttons["shareNativePhoto"].isHittable)
            app.buttons["refreshNativePhoto"].tap()
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: share)
            waitForExpectations(timeout: 15)
        }
        app.buttons["closeNativePhoto"].tap()
        XCTAssertTrue(app.buttons["capturePhoto"].waitForExistence(timeout: 10))
    }

    @MainActor private func assertEditorActionsVisible(_ app: XCUIApplication) {
        for identifier in ["closePhotoEditor", "saveEditedPhoto", "shareEditedPhoto", "compareEditedPhoto"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.isHittable, identifier)
            XCTAssertTrue(app.frame.contains(button.frame), identifier)
        }
    }

    @MainActor private func launchPortrait(native: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-Camlab.NativePhotosWorkflow", native ? "YES" : "NO"]
        app.launch()
        let vertical = NSPredicate { _, _ in app.frame.height > app.frame.width }
        expectation(for: vertical, evaluatedWith: app); waitForExpectations(timeout: 5)
        return app
    }

    @MainActor private func chooseNatural(_ app: XCUIApplication) {
        chooseStyle("原色", scene: "日常紀錄", in: app)
    }

    @MainActor private func chooseStyle(_ name: String, scene: String, in app: XCUIApplication) {
        let toggle = app.buttons["openRecipes"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        let option = "\(name) · \(scene)"
        if wheel.value as? String != option { wheel.adjust(toPickerWheelValue: option) }
        XCTAssertEqual(toggle.value as? String, name)
        toggle.tap()
        XCTAssertFalse(wheel.exists)
    }
    @MainActor private func enterSaturation(_ app: XCUIApplication, digits: [String]) {
        app.buttons["輸入飽和度數值"].tap()
        for digit in digits { app.buttons[digit].tap() }
        app.buttons["完成"].tap()
    }
    @MainActor private func saveNew(_ app: XCUIApplication, name: String) {
        app.buttons["另存新配方"].tap()
        let alert = app.alerts["另存新配方"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.tap(); alert.textFields.firstMatch.typeText(name)
        alert.buttons["儲存"].tap()
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let captured = XCUIScreen.main.screenshot().image
        // XCUIScreen returns the full device bitmap; express it in the app's
        // interface orientation before exporting, without app-only cropping.
        let bitmap: UIImage
        if let cgImage = captured.cgImage {
            let rotated = app.frame.width > app.frame.height && cgImage.width < cgImage.height
            let orientation: UIImage.Orientation = rotated
                ? (XCUIDevice.shared.orientation == .landscapeLeft ? .left : .right) : .up
            let source = UIImage(cgImage: cgImage, scale: captured.scale, orientation: orientation)
            let size = rotated
                ? CGSize(width: CGFloat(cgImage.height) / captured.scale, height: CGFloat(cgImage.width) / captured.scale)
                : CGSize(width: CGFloat(cgImage.width) / captured.scale, height: CGFloat(cgImage.height) / captured.scale)
            bitmap = UIGraphicsImageRenderer(size: size).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        } else { bitmap = captured }
        let screenshot = XCTAttachment(image: bitmap); screenshot.name = name
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
