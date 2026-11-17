import SwiftUI
import BCModel
import BCStreaming

struct DeviceSidebar: View {
    let rows: [SessionRegistry.Row]
    @Binding var selection: LogDevice.ID?

    var body: some View {
        List(selection: $selection) {
            section("This Mac", kind: .thisMac)
            section("Devices", kind: .physical)
            section("Simulators", kind: .simulator)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func section(_ title: String, kind: LogDevice.Kind) -> some View {
        let matching = rows.filter { $0.device.kind == kind }
        if !matching.isEmpty {
            Section(title) {
                ForEach(matching) { row in
                    DeviceRow(row: row).tag(row.id)
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let row: SessionRegistry.Row

    var body: some View {
        Label {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.device.name)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                // Only while available: a greyed row's last interface is stale.
                if row.isAvailable, let connection = row.device.connection {
                    ConnectionBadge(connection: connection)
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(row.isAvailable ? .primary : .secondary)
        .help(row.isAvailable ? row.device.name : "\(row.device.name) (disconnected)")
    }

    private var subtitle: String? {
        guard row.device.kind != .thisMac, let os = row.device.osVersion else { return nil }
        return os
    }

    private var symbol: String {
        switch row.device.kind {
        case .thisMac: "laptopcomputer"
        case .simulator: "apps.iphone"
        case .physical: (row.device.model ?? "").hasPrefix("iPad") ? "ipad" : "iphone"
        case .file: "doc.text"
        }
    }
}

/// How a physical device is reachable now: on USB (streams prefer it) or over Wi-Fi only.
/// Availability, not the interface a running stream uses.
private struct ConnectionBadge: View {
    let connection: LogDevice.Connection

    var body: some View {
        Image(systemName: connection == .usb ? "cable.connector" : "wifi")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .help(connection == .usb ? "Available over USB" : "Wi-Fi only")
            .accessibilityLabel(connection == .usb ? "USB" : "Wi-Fi")
    }
}
