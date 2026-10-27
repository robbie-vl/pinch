import SwiftUI

/// The VM's CPUs and memory. Colima keeps them in its own config, so Pinch stores nothing: it
/// shows what Colima reports, and a sheet applies changes with a start.
struct RuntimeResourcesSection: View {
  let store: ContainerStore

  @State private var isEditing = false
  @State private var errorMessage: String?

  var body: some View {
    Section("Colima") {
      if let runtime = store.snapshot?.runtime, let current = runtime.resources {
        LabeledContent("CPUs", value: "\(current.cpus)")
        LabeledContent("Memory", value: current.memoryLabel)

        HStack {
          Spacer()
          if store.runtimeTransition != nil {
            ProgressView()
              .controlSize(.small)
          }
          Button("Change…") {
            isEditing = true
          }
          .disabled(store.isBusy)
          .sheet(isPresented: $isEditing) {
            RuntimeResourcesSheet(
              current: current,
              isRunning: runtime.state == .running,
              isBusy: store.isBusy,
              onApply: { resources in Task { await apply(resources) } }
            )
          }
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      } else {
        Text(
          store.snapshot != nil
            ? "Start Colima from the menu bar once to set its resources here."
            : store.refreshError ?? "Checking Colima…"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func apply(_ resources: RuntimeResources) async {
    errorMessage = nil
    do {
      try await store.applyResources(resources)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

/// Edits a copy of the allocation, so Cancel, the only other way out, leaves Colima untouched.
private struct RuntimeResourcesSheet: View {
  let current: RuntimeResources
  /// Live, so the confirming button names what a click will do now, not when the sheet opened.
  let isRunning: Bool
  let isBusy: Bool
  let onApply: (RuntimeResources) -> Void

  @State private var resources: RuntimeResources
  @Environment(\.dismiss) private var dismiss

  private static let cpuRange = 1...ProcessInfo.processInfo.processorCount
  private static let memoryGiBRange =
    1...Double(Int64(ProcessInfo.processInfo.physicalMemory) / RuntimeResources.bytesPerGiB)

  init(
    current: RuntimeResources, isRunning: Bool, isBusy: Bool,
    onApply: @escaping (RuntimeResources) -> Void
  ) {
    self.current = current
    self.isRunning = isRunning
    self.isBusy = isBusy
    self.onApply = onApply
    _resources = State(initialValue: current)
  }

  var body: some View {
    Form {
      Section {
        // The value before the arrows, as System Settings sets its steppers.
        LabeledContent("CPUs") {
          HStack {
            Text("\(resources.cpus)")
            Stepper("CPUs", value: $resources.cpus, in: Self.cpuRange)
              .labelsHidden()
          }
        }
        LabeledContent("Memory") {
          HStack {
            Text(resources.memoryLabel)
            // Whole GiB steps from wherever Colima's allocation starts, which may be fractional.
            Stepper(
              "Memory",
              onIncrement: Self.memoryGiBRange.contains(resources.memoryGiBAbove)
                ? { resources.memoryGiB = resources.memoryGiBAbove } : nil,
              onDecrement: Self.memoryGiBRange.contains(resources.memoryGiBBelow)
                ? { resources.memoryGiB = resources.memoryGiBBelow } : nil
            )
            .labelsHidden()
          }
        }
      } footer: {
        Text(
          isRunning
            ? "Colima restarts the VM to apply these, which stops its containers."
            : "Colima starts the VM to apply these."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 360)
    .fixedSize(horizontal: false, vertical: true)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          dismiss()
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(isRunning ? "Apply & Restart" : "Apply & Start") {
          onApply(resources)
          dismiss()
        }
        .disabled(isBusy || resources == current)
      }
    }
  }
}
