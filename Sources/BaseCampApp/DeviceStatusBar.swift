import BaseCampMTP
import SwiftUI

/// Bottom bar showing whether a Garmin device is connected, with its storage.
struct DeviceStatusBar: View {
    @Environment(DeviceStore.self) private var device

    var body: some View {
        HStack(spacing: 10) {
            statusContent
            Spacer(minLength: 8)
            Button {
                device.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("Read the device again, or try again to open one that could not be opened")
            .disabled(device.state == .searching)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch device.state {
        case .searching:
            ProgressView()
                .controlSize(.small)
            Text("Reading the Garmin device…")
                .foregroundStyle(.secondary)
        case .disconnected:
            Image(systemName: "cable.connector.slash")
                .foregroundStyle(.secondary)
            Text("No device. Connect the Edge over USB in MTP mode.")
                .foregroundStyle(.secondary)
        case .connected(let name, let storages):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(name)
                .fontWeight(.medium)
            ForEach(storages, id: \.id) { storage in
                Text("\(storage.name): \(Format.bytes(storage.freeBytes)) free")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
