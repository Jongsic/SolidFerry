import SwiftUI

/// The two ways to connect a device, side by side: the cable (how to, since plugging in is all
/// it takes) and Wi-Fi (New Wireless Connection).
struct ConnectOptions: View {
    @Environment(\.openWindow) private var openWindow
    @State private var showingUSB = false

    var body: some View {
        HStack(spacing: 12) {
            ConnectTile(title: Text("USB Cable"), systemImage: "cable.connector",
                        detail: Text("Plug the device into this Mac")) { showingUSB = true }
                .popover(isPresented: $showingUSB, arrowEdge: .bottom) { USBSteps() }
            ConnectTile(title: Text("Wi-Fi"), systemImage: "wifi",
                        detail: Text("On the same network as this Mac")) { openWindow(id: WindowID.wireless) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ConnectTile: View {
    let title: Text
    let systemImage: String
    let detail: Text
    let action: () -> Void
    @Environment(\.textScale) private var scale

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 24 * max(1, scale.factor)))
                    .frame(height: 30 * max(1, scale.factor))
                title.appFont(.body, weight: .semibold)
                detail.appFont(.callout).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(TileButtonStyle())
        .scaledFrame(width: 180)
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Tile(configuration: configuration) }

    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10)
            configuration.label
                .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0.035)))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

/// What connecting with a cable takes.
private struct USBSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect with a USB cable").appFont(.headline)
            Label("Connect the device to this Mac with a USB cable.", systemImage: "1.circle")
            Label("Unlock the device and choose “File transfer” in its USB notification.", systemImage: "2.circle")
            Text("With USB debugging on, the device connects without choosing “File transfer”.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .scaledFrame(width: 320, alignment: .leading)
        .padding(16)
        .textArea(.panels)
    }
}
