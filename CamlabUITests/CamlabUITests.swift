import XCTest

final class CamlabUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testBuiltInShootingStylesCanBeSelectedInBothOrientations() throws {
        let app = launchPortrait(native: true)
        chooseNatural(app)
        let vintage = app.buttons["套用復古"]
        XCTAssertTrue(vintage.waitForExistence(timeout: 5))
        vintage.tap()
        XCTAssertTrue(app.buttons["comparePreview"].isEnabled)
        XCTAssertEqual(app.buttons["openRecipes"].value as? String, "復古")
        XCTAssertTrue(app.buttons["capturePhoto"].isHittable)
        attach(app, "風格拍攝-復古快捷列")

        app.buttons["allShootingStyles"].tap()
        let names = ["復古", "暖調底片", "日系清透", "電影", "經典黑白", "柔光人像", "夕陽", "冷調", "鮮明", "霧感", "城市街拍", "咖啡暖棕"]
        for name in names {
            let button = app.buttons["recipe-\(name)"]
            for _ in 0..<8 {
                if button.isHittable { break }
                app.scrollViews["shootingStyleList"].swipeUp()
            }
            XCTAssertTrue(button.isHittable, name)
        }
        app.buttons["recipe-咖啡暖棕"].tap()
        XCTAssertEqual(app.buttons["openRecipes"].value as? String, "咖啡暖棕")
        app.buttons["adjustControls"].tap()
        XCTAssertEqual(app.buttons["輸入飽和度數值"].value as? String, "-16")
        XCTAssertFalse(app.buttons["更新配方"].isEnabled)
        app.buttons["收起調整"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        app.buttons["openRecipes"].tap()
        app.buttons["recipe-原色"].tap()
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

    @MainActor func testMainControlsMatchMockPositions() throws {
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
        XCTAssertTrue(app.buttons["comparePreview"].exists)
        XCTAssertTrue(app.buttons["匯入相簿照片"].exists)
        let preview = app.otherElements["cameraViewfinder"].firstMatch
        XCTAssertLessThan(preview.frame.minY, app.frame.height * 0.2)
        XCTAssertLessThan(adjust.frame.minY - preview.frame.maxY, 95)
        XCTAssertTrue(app.scrollViews["recipeShortcuts"].exists)
        attach(app, "實際介面-直向收合")
        adjust.tap()
        XCTAssertTrue(app.otherElements["inlineCameraControls"].exists)
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

    @MainActor func testSimulatorExplainsMissingCameraAndCanRetry() throws {
        #if targetEnvironment(simulator)
        let app = launchPortrait()
        let error = app.staticTexts["cameraError"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(error.label.contains("實體 iPhone 或 iPad"))
        XCTAssertTrue(app.buttons["capturePhoto"].exists)
        XCTAssertFalse(app.buttons["capturePhoto"].isEnabled)
        app.buttons["重新連線"].tap()
        XCTAssertTrue(error.waitForExistence(timeout: 10))
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
        app.buttons["選擇配方"].tap()
        XCTAssertTrue(app.buttons["recipe-\(name)"].exists)
        app.buttons["recipe-原色"].tap()
        XCTAssertEqual(app.buttons["輸入飽和度數值"].value as? String, "0")
        app.buttons["選擇配方"].tap()
        app.buttons["recipe-\(name)"].tap()
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
        XCTAssertLessThanOrEqual(preview.frame.maxY, controls.frame.minY + 2)
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
        app.buttons["收起調整"].tap()
        XCTAssertGreaterThan(preview.frame.height, app.frame.height * 0.85)
    }

    @MainActor func testLevelGridAndZoomControlsAreReachable() throws {
        let app = launchPortrait()
        let levelOn = app.buttons["開啟水平線"]
        if levelOn.exists { levelOn.tap() }
        XCTAssertTrue(app.buttons["關閉水平線"].exists)
        app.buttons["關閉水平線"].tap()
        XCTAssertTrue(app.buttons["開啟水平線"].exists)
        let gridOn = app.buttons["開啟九宮格"]
        if gridOn.exists { gridOn.tap() }
        XCTAssertTrue(app.buttons["關閉九宮格"].exists)
        app.buttons["openZoom"].tap()
        XCTAssertTrue(app.otherElements["inlineCameraControls"].exists)
        XCTAssertTrue(app.buttons["輸入變焦數值"].exists)
        #if targetEnvironment(simulator)
        XCTAssertTrue(app.staticTexts["10×"].exists)
        #endif
        XCTAssertTrue(app.buttons["匯入相簿照片"].exists)
    }

    @MainActor func testPhotoEditorKeepsActionsInsideScreen() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("只使用模擬器相簿中的測試圖片")
        #endif
        let app = launchPortrait()
        app.buttons["匯入相簿照片"].tap()
        let photo = app.images["PXGGridLayout-Info"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), app.debugDescription)
        // The system picker exposes thumbnail frames but may report no hit point
        // across its remote accessibility process. Tap the resolved frame center.
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

    @MainActor func testNativePhotoFlowPreservesSystemVersionAndFitsBothOrientations() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("只使用模擬器相簿中的測試圖片")
        #endif
        let app = launchPortrait(native: true)
        XCTAssertEqual(app.buttons["comparePreview"].label, "原色預覽 · 原生調整")
        XCTAssertFalse(app.buttons["comparePreview"].isEnabled)
        app.buttons["匯入相簿照片"].tap()
        let photo = app.images["PXGGridLayout-Info"].firstMatch
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
        XCTAssertTrue(app.buttons["選擇配方"].waitForExistence(timeout: 10))
        app.buttons["選擇配方"].tap(); app.buttons["recipe-原色"].tap()
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
