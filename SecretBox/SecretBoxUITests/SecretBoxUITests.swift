import XCTest

final class SecretBoxUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Focus helper: tap on iOS, click on macOS (brings the element into
    /// focus without an app-activation dance).
    private func activate(_ element: XCUIElement) {
        #if os(iOS)
        element.tap()
        #else
        element.click()
        #endif
    }

    /// Menu-bar tests exercise a macOS-only surface; on the iPhone simulator
    /// they render the side-by-side test panel at an unusable width.
    private func skipUnlessMacOS() throws {
        #if os(iOS)
        throw XCTSkip("Menu-bar surface is macOS-only")
        #endif
    }

    private func launchApp(auth: String = "logged_in",
                           query: String? = nil,
                           extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SECRETBOX_UI_TEST"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_AUTH"] = auth
        if let query {
            app.launchEnvironment["SECRETBOX_UI_TEST_QUERY"] = query
        }
        for (key, value) in extraEnvironment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    /// Scrolls the detail scroll view until the element is hittable.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6) {
        var swipes = 0
        while (!element.exists || !element.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }

    /// Types into an editor that lives in a sheet: the first tap can land
    /// mid-presentation-animation without granting focus, so retry until the
    /// keyboard actually appears before typing.
    private func focusAndType(_ text: String, into element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<3 {
            element.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 4) {
                break
            }
        }
        element.typeText(text)
    }

    /// Dismisses an attached keyboard by scrolling the editor form (it uses
    /// `scrollDismissesKeyboard(.immediately)`). Tapping sheet buttons while
    /// the keyboard avoidance animation is active can silently drop the tap,
    /// so capture flows close the keyboard before saving.
    private func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        let editorScroll = app.scrollViews["editor.scroll"]
        if editorScroll.exists {
            editorScroll.swipeUp(velocity: .fast)
        }
        let keyboardGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [keyboardGone], timeout: 4)
    }

    private func statusTextContains(_ app: XCUIApplication, _ needle: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", needle)
        let match = app.staticTexts.matching(predicate).firstMatch
        return match.waitForExistence(timeout: timeout)
    }

    /// Failure-diagnostics screenshot (exported from the xcresult bundle).
    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLoginFlowOpensDashboard() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SECRETBOX_UI_TEST"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_AUTH"] = "logged_out"
        app.launch()

        let usernameField = app.textFields["login.username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 5))
        activate(usernameField)
        usernameField.typeText("ops")

        let passwordField = app.secureTextFields["login.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        activate(passwordField)
        passwordField.typeText("secret")

        let signInButton = app.buttons["login.signIn"]
        XCTAssertTrue(signInButton.waitForExistence(timeout: 5))
        activate(signInButton)

        XCTAssertTrue(app.textFields["dashboard.searchField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dashboard.capture"].waitForExistence(timeout: 5))
    }

    func testSearchFiltersSeededRecords() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SECRETBOX_UI_TEST"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_AUTH"] = "logged_in"
        app.launchEnvironment["SECRETBOX_UI_TEST_QUERY"] = "billing"
        app.launch()

        // The UI-test bootstrap auto-runs the seeded search, which auto-pushes
        // the detail on iPhone; pop back so the search button is tappable.
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.waitForExistence(timeout: 3) {
            activate(backButton)
        }

        let searchButton = app.buttons["dashboard.searchButton"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5))
        activate(searchButton)

        let resultTitle = app.staticTexts["detail.title"]
        XCTAssertTrue(resultTitle.waitForExistence(timeout: 5))

        let predicate = NSPredicate(format: "value == %@", "Billing Postgres")
        expectation(for: predicate, evaluatedWith: resultTitle)
        waitForExpectations(timeout: 5)
    }

    func testMenuBarSmokeFlowCanSaveAndOpenDashboard() throws {
        try skipUnlessMacOS()
        let app = XCUIApplication()
        app.launchEnvironment["SECRETBOX_UI_TEST"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_AUTH"] = "logged_in"
        app.launchEnvironment["SECRETBOX_UI_TEST_MENU_BAR"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_AUTO_SAVE_PASTED_TEXT"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_PASTED_TEXT"] = "redis://cache.internal:6379"
        app.launch()

        let dashboardButton = app.buttons["menubar.dashboard"]
        XCTAssertTrue(dashboardButton.waitForExistence(timeout: 5))
        activate(dashboardButton)

        let searchField = app.textFields["dashboard.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        let selectedResult = app.buttons.matching(identifier: "selected-result").firstMatch
        XCTAssertTrue(selectedResult.waitForExistence(timeout: 5))

        let detailTitle = app.staticTexts["detail.title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))

        let predicate = NSPredicate(format: "value == %@", "REDIS")
        expectation(for: predicate, evaluatedWith: detailTitle)
        waitForExpectations(timeout: 5)
    }

    func testMenuBarPreviewCanEditAndSaveLocally() throws {
        try skipUnlessMacOS()
        let app = XCUIApplication()
        app.launchEnvironment["SECRETBOX_UI_TEST"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_AUTH"] = "logged_in"
        app.launchEnvironment["SECRETBOX_UI_TEST_MENU_BAR"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_PASTED_TEXT"] = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        app.launch()

        let preview = app.otherElements["menubar.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))

        let field = app.textFields["menubar.previewField.account"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        activate(field)
        field.typeKey("a", modifierFlags: [.command])
        field.typeText("ops-bot-override@example.com")

        let saveButton = app.buttons["menubar.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        activate(saveButton)

        let dashboardButton = app.buttons["menubar.dashboard"]
        XCTAssertTrue(dashboardButton.waitForExistence(timeout: 5))
        activate(dashboardButton)

        let detailTitle = app.staticTexts["detail.title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))

        XCTAssertTrue(app.staticTexts["ops-bot-override@example.com"].waitForExistence(timeout: 5))
    }

    func testMenuBarPreviewFieldOverrideCanSaveEditedHost() throws {
        try skipUnlessMacOS()
        let app = XCUIApplication()
        app.launchEnvironment["SECRETBOX_UI_TEST"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_AUTH"] = "logged_in"
        app.launchEnvironment["SECRETBOX_UI_TEST_MENU_BAR"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_PASTED_TEXT"] = "redis://default:RedisProd#2026@redis-prod.internal:6379/0 env=prod service=order-cache"
        app.launch()

        let preview = app.otherElements["menubar.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))

        let hostField = app.textFields["menubar.previewField.host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 5))
        activate(hostField)
        hostField.typeKey("a", modifierFlags: [.command])
        hostField.typeText("redis-override.internal")

        let saveButton = app.buttons["menubar.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        activate(saveButton)

        let dashboardButton = app.buttons["menubar.dashboard"]
        XCTAssertTrue(dashboardButton.waitForExistence(timeout: 5))
        activate(dashboardButton)

        let detailTitle = app.staticTexts["detail.title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))

        let hostText = app.staticTexts["redis-override.internal"]
        XCTAssertTrue(hostText.waitForExistence(timeout: 5))
    }

    func testMenuBarPreviewFieldsCanExpand() throws {
        try skipUnlessMacOS()
        let app = XCUIApplication()
        app.launchEnvironment["SECRETBOX_UI_TEST"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_AUTH"] = "logged_in"
        app.launchEnvironment["SECRETBOX_UI_TEST_MENU_BAR"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_PASTED_TEXT"] = "service=GitHub username=ops-bot@example.com password=GhOpsBot@2026 url=https://github.com env=prod"
        app.launch()

        let preview = app.otherElements["menubar.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))

        let hiddenField = app.textFields["menubar.previewField.url"]
        XCTAssertFalse(hiddenField.exists)

        let toggle = app.buttons["menubar.previewFieldsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        activate(toggle)

        XCTAssertTrue(hiddenField.waitForExistence(timeout: 5))
    }

    func testQuickCaptureSheetCanOpen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SECRETBOX_UI_TEST"] = "1"
        app.launchEnvironment["SECRETBOX_UI_TEST_AUTH"] = "logged_in"
        app.launch()

        let captureButton = app.buttons["dashboard.capture"]
        XCTAssertTrue(captureButton.waitForExistence(timeout: 5))
        activate(captureButton)

        XCTAssertTrue(app.textViews["capture.paste"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["capture.save"].waitForExistence(timeout: 5))
    }

    // MARK: - Phase 1 iOS smoke chains (capture → search → detail → copy)

    /// Roadmap phase-1 acceptance flow: paste capture → save → search →
    /// detail → copy password, end to end on a compact-width device.
    func testCaptureSaveSearchDetailCopyFlow() throws {
        let app = launchApp()
        defer { app.terminate() }

        let captureButton = app.buttons["dashboard.capture"]
        XCTAssertTrue(captureButton.waitForExistence(timeout: 5))
        activate(captureButton)

        let pasteEditor = app.textViews["capture.paste"]
        XCTAssertTrue(pasteEditor.waitForExistence(timeout: 5))
        focusAndType("redis://default:RedisCompact2026@redis-compact.internal:6379/0 env=prod service=compact-flow", into: pasteEditor, app: app)

        dismissKeyboard(in: app)
        let saveButton = app.buttons["capture.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        scrollTo(saveButton, in: app)
        activate(saveButton)

        // Saving auto-selects the new record: the detail view pushes with the
        // copy action already available.
        let copyPassword = app.buttons["detail.copyPassword"]
        let detailPushed = copyPassword.waitForExistence(timeout: 8)
        if !detailPushed {
            snap(app, "after-save-no-detail")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "hierarchy-after-save"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(detailPushed, "detail must auto-push after saving the capture")

        // Back to the browser, then find the record again through search.
        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        activate(backButton)

        let searchField = app.textFields["dashboard.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        activate(searchField)
        searchField.typeText("compact")
        activate(app.buttons["dashboard.searchButton"])

        // Search auto-selects the first hit, pushing the detail view again.
        XCTAssertTrue(copyPassword.waitForExistence(timeout: 8))
        scrollTo(copyPassword, in: app)
        activate(copyPassword)
        XCTAssertTrue(statusTextContains(app, "Password copied"), "copy status must surface after copying the secret")
    }

    /// Phase-MP chain: pasting credentials with an `otpauth://` URI captures
    /// the TOTP seed, and the detail page renders the live verification code.
    func testCaptureWithOTPAuthShowsLiveCodeAndCopies() throws {
        let app = launchApp()
        defer { app.terminate() }

        let captureButton = app.buttons["dashboard.capture"]
        XCTAssertTrue(captureButton.waitForExistence(timeout: 5))
        activate(captureButton)

        let pasteEditor = app.textViews["capture.paste"]
        XCTAssertTrue(pasteEditor.waitForExistence(timeout: 5))
        focusAndType("service=CompactAuth username=ops@example.com password=AuthSecret2026 otpauth://totp/CompactAuth:ops@example.com?secret=JBSWY3DPEHPK3PXP&issuer=CompactAuth", into: pasteEditor, app: app)

        dismissKeyboard(in: app)
        let saveButton = app.buttons["capture.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        scrollTo(saveButton, in: app)
        activate(saveButton)

        // Saving auto-selects the record: the detail pushes and renders the
        // live verification code from the captured seed.
        let totpCode = app.staticTexts["detail.totpCode"]
        XCTAssertTrue(totpCode.waitForExistence(timeout: 8), "detail must render the live verification code")

        let copyTOTP = app.buttons["detail.totpCopy"]
        scrollTo(copyTOTP, in: app)
        XCTAssertTrue(copyTOTP.exists)
        activate(copyTOTP)
        XCTAssertTrue(statusTextContains(app, "Verification code copied"))
    }

    /// Permission matrix in the editor: enabling read-only locks editing and
    /// deletion from the detail page.
    func testReadOnlyPermissionLocksEditing() throws {
        let app = launchApp()
        defer { app.terminate() }

        let captureButton = app.buttons["dashboard.capture"]
        XCTAssertTrue(captureButton.waitForExistence(timeout: 5))
        activate(captureButton)

        let pasteEditor = app.textViews["capture.paste"]
        XCTAssertTrue(pasteEditor.waitForExistence(timeout: 5))
        focusAndType("service=LockedService username=ops@example.com password=LockedSecret2026", into: pasteEditor, app: app)

        dismissKeyboard(in: app)
        let saveButton = app.buttons["capture.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        scrollTo(saveButton, in: app)
        activate(saveButton)

        // Saving auto-selects the record and pushes its detail; open the
        // editor from it.
        let editButton = app.buttons["detail.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 8))
        scrollTo(editButton, in: app)
        activate(editButton)

        let readOnlyToggle = app.switches["entry.permissionReadOnly"]
        XCTAssertTrue(readOnlyToggle.waitForExistence(timeout: 5), "editor must expose the read-only permission toggle")
        scrollTo(readOnlyToggle, in: app)
        activate(readOnlyToggle)

        let updateButton = app.buttons["entry.save"]
        XCTAssertTrue(updateButton.waitForExistence(timeout: 5))
        scrollTo(updateButton, in: app)
        activate(updateButton)

        // Back on the detail of the now-locked record: edit and delete refuse.
        let lockedEdit = app.buttons["detail.edit"]
        XCTAssertTrue(lockedEdit.waitForExistence(timeout: 8))
        XCTAssertFalse(lockedEdit.isEnabled, "edit must be disabled on a read-only record")

        let lockedDelete = app.buttons["detail.delete"]
        scrollTo(lockedDelete, in: app)
        XCTAssertTrue(lockedDelete.waitForExistence(timeout: 5))
        XCTAssertFalse(lockedDelete.isEnabled, "delete must be disabled on a read-only record")
    }

    /// Settings sheet opens from the compact toolbar and closes cleanly.
    func testSettingsSheetOpensAndCloses() throws {
        let app = launchApp()
        defer { app.terminate() }

        let settingsButton = app.buttons["toolbar.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        activate(settingsButton)

        XCTAssertTrue(app.staticTexts["Server and AI Provider"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        activate(app.buttons["Close"])

        XCTAssertTrue(app.textFields["dashboard.searchField"].waitForExistence(timeout: 5))
    }
}
