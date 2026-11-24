import DeviceCore
import SwiftUI

extension View {
    /// Keeps `connection` on the device's open connection: a dialog opened over one goes on
    /// with the new one when it changes (ADB ↔ MTP), so its options and comparison are for the
    /// connection the transfer will use. While none is open, the last one stays.
    func followsConnection(of deviceID: String, _ connection: Binding<(any DeviceFileSystem)?>) -> some View {
        modifier(FollowsConnection(deviceID: deviceID, connection: connection))
    }
}

private struct FollowsConnection: ViewModifier {
    let deviceID: String
    @Binding var connection: (any DeviceFileSystem)?
    @Environment(TransferQueue.self) private var queue

    func body(content: Content) -> some View {
        content.onChange(of: queue.fileSystem(of: deviceID).map(ObjectIdentifier.init), initial: true) {
            if let now = queue.fileSystem(of: deviceID) { connection = now }
        }
    }
}
