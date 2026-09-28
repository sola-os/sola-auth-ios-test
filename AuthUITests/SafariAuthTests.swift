import XCTest

/// Drives Safari on an iPhone simulator (Face ID enrolled, matches sent by the workflow) against a
/// DISPOSABLE SOLA HQ test instance with an empty database and one throwaway user.
///
/// Phone side = Safari in the simulator. "Laptop" side = an ephemeral URLSession in this test process,
/// i.e. a second browser session with its own cookie jar, running headless on the macOS runner.
///
/// Inputs (xcodebuild passes TEST_RUNNER_<NAME> to the test as <NAME>):
///   AUTH_BASE_URL   the test instance, e.g. https://auth-test.example
///   AUTH_LOGIN_URL  a single-use sign-in link for the throwaway user (minted by the workflow)
final class SafariAuthTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var base: String { (env["AUTH_BASE_URL"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var web: XCUIElement { safari.webViews.firstMatch }
    private static var setupCode = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCTAssertFalse(base.isEmpty, "AUTH_BASE_URL is not set")
    }

    // MARK: - the flow

    func test1_PasskeyThenPhoneApprovalInSafari() throws {
        let login = env["AUTH_LOGIN_URL"] ?? ""
        XCTAssertFalse(login.isEmpty, "AUTH_LOGIN_URL is not set")

        XCTContext.runActivity(named: "sign in with the throwaway user's one-time link") { _ in
            open(login)
            // Safari's first launch can still be busy (Start Page); wait for the link page or HQ itself,
            // and press "Sign in" when Safari got the scanner-safe confirmation page.
            let signIn = web.buttons["Sign in"]
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline && !signIn.exists && !waitWebText(containing: "SOLA", timeout: 1) { }
            if signIn.exists { signIn.tap(); sleep(3) }
            shot("01-signed-in-by-link")
            open(base + "/api/me")
            XCTAssertTrue(waitWebText(containing: "\"authenticated\":true", timeout: 30), "the one-time link did not sign Safari in")
        }

        XCTContext.runActivity(named: "register a passkey (Face ID)") { _ in
            open(base + "/#passkeys")
            shot("02-passkeys-and-phone")
            tapWebButton("Add a passkey on this device")
            confirmSystemSheet("03-passkey-sheet", timeout: 8)
            XCTAssertTrue(waitWebText(containing: "Passkey added", timeout: 40), "passkey was not added")
            shot("04-passkey-added")
        }

        XCTContext.runActivity(named: "mint a phone set-up code") { _ in
            tapWebButton("Set up a phone")
            let code = webText(matching: "^[A-Z0-9]{4}-[A-Z0-9]{4}$")
            XCTAssertNotNil(code, "no set-up code shown")
            SafariAuthTests.setupCode = code ?? ""
            shot("05-setup-code")
        }

        XCTContext.runActivity(named: "sign out, then sign in with the passkey") { _ in
            open(base + "/auth/logout")
            tapWebButton("Sign in with a passkey")
            confirmSystemSheet("06-passkey-signin-sheet")
            sleep(4)
            shot("07-after-passkey-signin")
            open(base + "/api/me")
            XCTAssertTrue(waitWebText(containing: "\"authenticated\":true", timeout: 20), "not signed in after the passkey")
            shot("08-api-me-authenticated")
        }

        XCTContext.runActivity(named: "SOLA Authenticator: enrol this phone with the set-up code") { _ in
            open(base + "/auth/logout")
            open(base + "/authenticator/")
            let field = web.textFields["set-up code"]
            XCTAssertTrue(field.waitForExistence(timeout: 25), "no set-up code field")
            shot("09-authenticator-setup")
            field.tap()
            field.typeText(SafariAuthTests.setupCode)
            tapWebButton("Continue")
            let create = web.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Create the device key")).firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 20), "no create-key button")
            create.tap()
            confirmSystemSheet("10-device-key-sheet")
            XCTAssertTrue(waitWebText(containing: "This phone is set up", timeout: 40), "enrolment failed")
            shot("11-authenticator-enrolled")
        }

        let laptop = Laptop(base: base)

        XCTContext.runActivity(named: "laptop starts 'approve on my phone'; approve in Safari with the code") { _ in
            let start = laptop.call("POST", "/api/phone-login/start", json: ["username": ""])
            XCTAssertEqual(start.status, 200)
            let code = start.body["code"] as? String ?? ""
            let requestId = start.body["requestId"] as? String ?? ""
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(waitWebText(containing: "Sign-in request", timeout: 30), "the request did not show on the phone")
            shot("12-phone-request")
            let input = web.textFields["code from the sign-in screen"]
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            input.tap()
            input.typeText(code)
            tapWebButton("Approve with Face ID")
            confirmSystemSheet("13-approve-sheet")
            XCTAssertTrue(waitWebText(containing: "Approved", timeout: 40), "approval not confirmed on the phone")
            shot("14-phone-approved")
            XCTAssertEqual(laptop.waitStatus(requestId), "approved")
            let me = laptop.call("GET", "/api/me")
            XCTAssertEqual(me.body["authenticated"] as? Bool, true, "laptop not signed in")
        }

        XCTContext.runActivity(named: "deny path") { _ in
            sleep(9) // the finished card clears
            let laptop2 = Laptop(base: base)
            let start = laptop2.call("POST", "/api/phone-login/start", json: ["username": ""])
            let requestId = start.body["requestId"] as? String ?? ""
            XCTAssertTrue(waitWebText(containing: "Sign-in request", timeout: 30))
            tapWebButton("Deny")
            confirmSystemSheet("15-deny-sheet")
            XCTAssertTrue(waitWebText(containing: "Denied", timeout: 40), "deny not confirmed on the phone")
            shot("16-phone-denied")
            XCTAssertEqual(laptop2.waitStatus(requestId), "denied")
            XCTAssertNotEqual(laptop2.call("GET", "/api/me").body["authenticated"] as? Bool, true)
        }
    }

    /// Home Screen install is best effort: iOS UI for it differs between versions.
    func test2_AddToHomeScreen() throws {
        open(base + "/authenticator/")
        // iOS 26 Safari keeps Share in the "More" (...) menu.
        var share = safari.buttons["Share"]
        if !share.waitForExistence(timeout: 5) {
            let more = safari.buttons["More"]
            if more.waitForExistence(timeout: 10) { more.tap(); shot("20-more-menu") }
            share = safari.buttons["Share"].exists ? safari.buttons["Share"] : safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Share'")).firstMatch
        }
        guard share.waitForExistence(timeout: 10) else { shot("20-no-share"); throw XCTSkip("no Share button found") }
        share.tap()
        sleep(2)
        shot("20-share-sheet")
        var add = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Add to Home Screen'")).firstMatch
        if !add.waitForExistence(timeout: 5) { add = safari.cells["Add to Home Screen"] }
        var tries = 0
        while !add.exists && tries < 4 { safari.swipeUp(); tries += 1; add = safari.buttons["Add to Home Screen"].exists ? safari.buttons["Add to Home Screen"] : safari.cells["Add to Home Screen"] }
        guard add.exists else { shot("20-share-sheet"); throw XCTSkip("no 'Add to Home Screen' in the share sheet") }
        add.tap()
        let confirm = safari.buttons["Add"]
        guard confirm.waitForExistence(timeout: 10) else { shot("21-add-dialog"); throw XCTSkip("no Add button") }
        shot("21-add-to-home-screen")
        confirm.tap()
        sleep(3)
        XCUIDevice.shared.press(.home)
        let icon = springboard.icons["SOLA Auth"]
        guard icon.waitForExistence(timeout: 15) else { shot("22-home"); throw XCTSkip("icon not found on the Home Screen") }
        shot("22-home-screen-icon")
        icon.tap()
        sleep(5)
        shot("23-standalone-web-app")
    }

    // MARK: - helpers

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func open(_ url: String) {
        XCUIDevice.shared.system.open(URL(string: url)!)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 30), "Safari did not come to the foreground")
        sleep(3)
    }

    private func tapWebButton(_ label: String, timeout: TimeInterval = 30) {
        let b = web.buttons[label]
        if !b.waitForExistence(timeout: timeout) {
            shot("missing-" + label)
            let tree = XCTAttachment(string: safari.debugDescription)
            tree.name = "tree-missing-" + label; tree.lifetime = .keepAlways; add(tree)
            XCTFail("no button '\(label)'")
            return
        }
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: b)
        wait(for: [enabled], timeout: timeout)
        b.tap()
    }

    private func waitWebText(containing text: String, timeout: TimeInterval) -> Bool {
        let q = safari.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        return q.waitForExistence(timeout: timeout)
    }

    private func webText(matching regex: String, timeout: TimeInterval = 25) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for t in web.staticTexts.allElementsBoundByIndex {
                let label = t.label.trimmingCharacters(in: .whitespaces)
                if label.range(of: regex, options: .regularExpression) != nil { return label }
            }
            sleep(1)
        }
        return nil
    }

    /// The system passkey sheet ("Add a passkey?" / "Sign in with passkey?"). It is a remote view of the
    /// AuthenticationServices agent, not part of Safari's tree. Face ID is matched by the workflow's notifyutil loop.
    private let agents = ["com.apple.AuthenticationServicesCore.AuthenticationServicesAgent",
                          "com.apple.AuthenticationServicesUI.AuthenticationServicesUIService",
                          "com.apple.springboard"]
    private func confirmSystemSheet(_ name: String, timeout: TimeInterval = 20) {
        let labels = ["Add Passkey", "Continue", "Sign In", "Use Passkey", "Save Passkey", "Save", "Create Passkey"]
        let apps = [safari] + agents.map { XCUIApplication(bundleIdentifier: $0) }
        let deadline = Date().addingTimeInterval(timeout)
        sleep(2)
        while Date() < deadline {
            for app in apps {
                for label in labels {
                    let b = app.buttons[label]
                    if b.exists && b.isHittable && !web.buttons[label].exists {
                        shot(name)
                        b.tap()
                        return
                    }
                }
            }
            usleep(500_000)
        }
        // Not reachable through accessibility: find the sheet's filled blue primary button in the screenshot
        // (scanning up from the bottom at the button's left edge, where there is no text) and tap it.
        shot(name + "-pixel-tap")
        let y = primaryButtonY() ?? 0.86
        XCUIApplication(bundleIdentifier: "com.apple.springboard").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)).tap()
    }

    private func primaryButtonY() -> CGFloat? {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage, let data = cg.dataProvider?.data,
              let p = CFDataGetBytePtr(data) else { return nil }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        let x = Int(Double(cg.width) * 0.15)
        var y = Int(Double(cg.height) * 0.97)
        while y > cg.height / 2 {
            let o = y * bpr + x * bpp
            let a = Int(p[o]), g = Int(p[o + 1]), b = Int(p[o + 2])
            let blue = g > 90 && g < 170 && ((a < 70 && b > 200) || (b < 70 && a > 200))
            if blue {
                var top = y
                while top > 0 {
                    let q = (top - 1) * bpr + x * bpp
                    let a2 = Int(p[q]), g2 = Int(p[q + 1]), b2 = Int(p[q + 2])
                    if !(g2 > 90 && g2 < 170 && ((a2 < 70 && b2 > 200) || (b2 < 70 && a2 > 200))) { break }
                    top -= 1
                }
                return CGFloat(y + top) / 2 / CGFloat(cg.height)
            }
            y -= 2
        }
        return nil
    }

    // MARK: - the "laptop": a separate browser session, headless

    private final class Laptop {
        let session: URLSession
        let base: String
        init(base: String) {
            let c = URLSessionConfiguration.ephemeral
            c.httpCookieAcceptPolicy = .always
            c.httpShouldSetCookies = true
            session = URLSession(configuration: c)
            self.base = base
        }

        func call(_ method: String, _ path: String, json: [String: Any]? = nil) -> (status: Int, body: [String: Any]) {
            var r = URLRequest(url: URL(string: base + path)!)
            r.httpMethod = method
            r.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/140.0 sola-test-2026-09-28 ios-ci-laptop", forHTTPHeaderField: "User-Agent")
            if let j = json {
                r.httpBody = try? JSONSerialization.data(withJSONObject: j)
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let box = ResultBox()
            let done = DispatchSemaphore(value: 0)
            session.dataTask(with: r) { data, response, _ in
                box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let d = data, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { box.body = o }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 30)
            return (box.status, box.body)
        }

        func waitStatus(_ requestId: String, timeout: TimeInterval = 40) -> String {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let s = call("GET", "/api/phone-login/status?id=" + requestId)
                if let st = s.body["status"] as? String, st != "pending" { return st }
                if s.status == 410 { return "gone" }
                sleep(2)
            }
            return "timeout"
        }
    }

    private final class ResultBox { var status = 0; var body: [String: Any] = [:] }
}
