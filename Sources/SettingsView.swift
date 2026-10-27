import ServiceManagement
import SwiftUI

struct SettingsView: View {
  let store: ContainerStore

  @State private var launchAtLoginStatus = SMAppService.mainApp.status
  @State private var isChangingLaunchAtLogin = false
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section {
        // A second Text in a Form toggle's label is the system's subtitle style.
        Toggle(isOn: launchAtLoginBinding) {
          Text("Open Pinch at Login")
          Text("Keep container controls available after you sign in.")
        }
        .disabled(isChangingLaunchAtLogin)

        if launchAtLoginStatus == .requiresApproval {
          LabeledContent {
            Button("Open Login Items") {
              SMAppService.openSystemSettingsLoginItems()
            }
          } label: {
            Text("Pinch is disabled in System Settings.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }

      RuntimeResourcesSection(store: store)
    }
    .formStyle(.grouped)
    .frame(width: 440)
    .fixedSize(horizontal: false, vertical: true)
    // The popover polls only while it's open, so load the VM's current allocation here.
    .task {
      await store.refresh()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      launchAtLoginStatus = SMAppService.mainApp.status
    }
  }

  private var launchAtLoginBinding: Binding<Bool> {
    Binding(
      get: { launchAtLoginStatus == .enabled },
      set: { shouldOpenAtLogin in
        Task { await setLaunchAtLogin(shouldOpenAtLogin) }
      }
    )
  }

  @MainActor
  private func setLaunchAtLogin(_ shouldOpenAtLogin: Bool) async {
    guard !isChangingLaunchAtLogin else {
      return
    }

    isChangingLaunchAtLogin = true
    errorMessage = nil
    defer {
      launchAtLoginStatus = SMAppService.mainApp.status
      isChangingLaunchAtLogin = false
    }

    do {
      if shouldOpenAtLogin {
        try SMAppService.mainApp.register()
      } else {
        try await SMAppService.mainApp.unregister()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
