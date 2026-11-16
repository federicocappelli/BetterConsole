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
            VStack(alignment: .leading, spacing: 1) {
                Text(row.device.name)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
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
