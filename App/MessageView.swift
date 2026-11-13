import SwiftUI

/// A message in place of content ("No Devices", "Empty Folder"): ContentUnavailableView's
/// layout, at the area's text size (ContentUnavailableView keeps macOS's own sizes).
struct MessageView<Actions: View>: View {
    let title: Text
    let systemImage: String
    var description: Text?
    @ViewBuilder var actions: () -> Actions
    @Environment(\.textScale) private var scale

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 36 * max(1, scale.factor)))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            title.appFont(.title2, weight: .semibold)
            if let description {
                description.foregroundStyle(.secondary)
            }
            actions()
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .scaledFrame(width: 460)
        .scaledButtons()
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension MessageView where Actions == EmptyView {
    init(_ title: Text, systemImage: String, description: Text? = nil) {
        self.init(title: title, systemImage: systemImage, description: description) { EmptyView() }
    }
}
