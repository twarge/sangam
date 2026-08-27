import Combine
import Foundation
import SwiftUI

/// The app's persistent preferences — one source of truth behind both the
/// Settings surface and the toolbar's More menu. Views that only lay out by
/// a preference read the same UserDefaults keys through `@AppStorage`;
/// live-meeting behavior (quality, blur) flows through `MeetingController`,
/// which observes this object.
@MainActor
final class AppSettings: ObservableObject {
  static let shared = AppSettings()

  /// Per-source height cap asked of the bridge; 720 matches the web.
  @Published var receiveQuality: Int {
    didSet { UserDefaults.standard.set(receiveQuality, forKey: "receiveQuality") }
  }

  /// Apple-native background blur on the outgoing camera.
  @Published var backgroundBlur: Bool {
    didSet { UserDefaults.standard.set(backgroundBlur, forKey: "backgroundBlur") }
  }

  /// Whether the sidebar and chat panel push the stage aside instead of
  /// floating over it.
  @Published var panelsPushStage: Bool {
    didSet { UserDefaults.standard.set(panelsPushStage, forKey: "panelsPushStage") }
  }

  private init() {
    let defaults = UserDefaults.standard
    let storedQuality = defaults.integer(forKey: "receiveQuality")
    receiveQuality = storedQuality == 0 ? 720 : storedQuality
    backgroundBlur = defaults.bool(forKey: "backgroundBlur")
    panelsPushStage = defaults.bool(forKey: "panelsPushStage")
  }
}

/// The mirrored settings surface: a Settings window on macOS, a sheet on
/// iOS. Everything here also lives in the toolbar's More menu.
struct SettingsView: View {
  @ObservedObject private var settings = AppSettings.shared

  static let qualities: [(label: String, height: Int)] = [
    ("Low (180p)", 180), ("Standard (360p)", 360),
    ("High (720p)", 720), ("Full HD (1080p)", 1080),
  ]

  var body: some View {
    Form {
      Section("Video") {
        Picker("Incoming video quality", selection: $settings.receiveQuality) {
          ForEach(Self.qualities, id: \.height) { quality in
            Text(quality.label).tag(quality.height)
          }
        }
        Toggle("Blur my background", isOn: $settings.backgroundBlur)
      }
      Section("Layout") {
        Picker("Sidebar and chat", selection: $settings.panelsPushStage) {
          Text("Float over the video").tag(false)
          Text("Push the video aside").tag(true)
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Settings")
    #if os(macOS)
      .frame(width: 400)
      .fixedSize(horizontal: false, vertical: true)
    #endif
  }
}
