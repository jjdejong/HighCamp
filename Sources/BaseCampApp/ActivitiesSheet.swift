import BaseCampCore
import SwiftUI

/// Lists the activities stored on the Edge and imports the chosen ones as tracks.
struct ActivitiesSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(DeviceStore.self) private var device
    @Environment(\.dismiss) private var dismiss

    @State private var files: [DeviceFile] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var importingID: UInt32?
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 420)
        .task {
            await reload()
        }
    }

    private var header: some View {
        HStack {
            Text("Activities on Edge")
                .font(.headline)
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await reload() }
            }
            .labelStyle(.iconOnly)
            .disabled(isLoading)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Reading Garmin/Activities…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView(
                "Could not read the device",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if files.isEmpty {
            ContentUnavailableView(
                "No activities",
                systemImage: "bicycle",
                description: Text("Garmin/Activities on the device is empty.")
            )
        } else {
            List(files) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                        Text(Format.bytes(file.size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if importingID == file.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Import") {
                            Task { await importFile(file) }
                        }
                        .disabled(importingID != nil)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            files = try await device.activities()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func importFile(_ file: DeviceFile) async {
        importingID = file.id
        importError = nil
        do {
            let track = try await device.track(for: file)
            store.addTrack(track)
        } catch {
            importError = "Could not import \(file.name). \(error.localizedDescription)"
        }
        importingID = nil
    }
}
