import SwiftUI

// An empty host: XCUITest needs a target app, but every step of the test drives Safari.
@main
struct AuthTestHost: App {
    var body: some Scene { WindowGroup { Text("SOLA auth test host - the test drives Safari") } }
}
