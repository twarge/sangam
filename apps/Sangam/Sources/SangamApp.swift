import SwiftUI

@main
struct SangamApp: App {
  var body: some Scene {
    WindowGroup {
      RootView()
    }
    #if os(macOS)
      .windowStyle(.hiddenTitleBar)
      .defaultSize(width: 1100, height: 700)
      .windowResizability(.contentMinSize)
    #endif
  }
}
