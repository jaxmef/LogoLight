import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = AppModel.shared
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.restoreOnQuit()
    }
}

@main
struct LogoLightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Don't observe the model here: that rebuilds the open popover on every change.

    var body: some Scene {
        // Not "apple.logo": Apple doesn't allow that symbol as a third-party app's icon.
        MenuBarExtra("LogoLight", systemImage: "lightbulb.max") {
            MenuContent(model: AppModel.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Logo").font(.headline)

            Picker("Mode", selection: $model.choice) {
                ForEach(AppModel.Choice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.isSupported)

            if model.choice.drivesPWM {
                if model.choice == .music {
                    Text("Pulses with what your Mac is playing. Slider = peak brightness.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: $model.percent, in: 0...100)
                        .disabled(!model.isSupported)
                        .accessibilityLabel(model.choice == .music ? "Peak brightness" : "Brightness")
                        .accessibilityValue("\(Int(model.percent.rounded())) percent")
                    Image(systemName: "sun.max").foregroundStyle(.secondary).accessibilityHidden(true)
                    if model.choice == .custom {
                        Text("\(Int(model.percent.rounded())) %")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)   // fixed, so the slider doesn't shift
                            .accessibilityHidden(true)                // the slider announces it
                    }
                }
                if let hint = model.musicHint {
                    Text(hint).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(model.choice == .system ? "Follows the display brightness, like macOS."
                                             : "The logo stays dark while LogoLight is running.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Quit LogoLight (logo returns to Default)") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)   // keeps the popover from re-measuring to a different height
        .onAppear { model.refreshStatus() }
    }
}
