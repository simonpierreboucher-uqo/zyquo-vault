import SwiftUI
import ZyquoVaultUI

@main
struct ZyquoVaultApp: App {
    var body: some Scene {
        WindowGroup("Zyquo Vault") {
            RootView()
        }
        .windowResizability(.contentMinSize)
    }
}
