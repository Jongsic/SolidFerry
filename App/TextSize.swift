import SwiftUI

/// Parts of the window whose text size can be set separately.
enum TextArea: String, CaseIterable, Identifiable {
    case fileList, sidebar, pathBar, statusBar, panels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fileList: String(localized: "File list")
        case .sidebar: String(localized: "Sidebar")
        case .pathBar: String(localized: "Path bar")
        case .statusBar: String(localized: "Status and progress bars")
        case .panels: String(localized: "Dialogs and panels")
        }
    }
}

enum TextPreset: String, CaseIterable, Identifiable {
    /// macOS's usual sizes.
    case standard
    /// Nothing smaller than 16 pt (1em on the web).
    case large
    case extraLarge
    case custom

    var id: String { rawValue }

    /// Body size and smallest size; nil for custom.
    var sizes: (base: Double, minimum: Double)? {
        switch self {
        case .standard: (TextScale.macBody, 0)
        case .large: (16, 16)
        case .extraLarge: (19, 18)
        case .custom: nil
        }
    }
}

/// Text sizes for the whole app, saved on this Mac.
@MainActor @Observable
final class TextSettings {
    static let shared = TextSettings()

    private(set) var preset: TextPreset
    private(set) var bases: [TextArea: Double]
    private(set) var minimum: Double

    private let defaults = UserDefaults.standard

    private init() {
        preset = defaults.string(forKey: SettingsKey.textPreset).flatMap(TextPreset.init) ?? .standard
        minimum = defaults.object(forKey: SettingsKey.textMinimum) as? Double ?? 0
        var bases: [TextArea: Double] = [:]
        for area in TextArea.allCases { bases[area] = defaults.object(forKey: SettingsKey.textSize(area.rawValue)) as? Double ?? TextScale.macBody }
        self.bases = bases
    }

    func scale(for area: TextArea) -> TextScale {
        TextScale(base: bases[area] ?? TextScale.macBody, minimum: minimum)
    }

    func apply(_ preset: TextPreset) {
        self.preset = preset
        defaults.set(preset.rawValue, forKey: SettingsKey.textPreset)
        guard let sizes = preset.sizes else { return }
        for area in TextArea.allCases { setBase(sizes.base, for: area) }
        setMinimum(sizes.minimum)
    }

    /// Changing one size makes the setup custom.
    func setCustomBase(_ size: Double, for area: TextArea) {
        setBase(size, for: area)
        markCustom()
    }

    func setCustomMinimum(_ size: Double) {
        setMinimum(size)
        markCustom()
    }

    private func markCustom() {
        preset = .custom
        defaults.set(TextPreset.custom.rawValue, forKey: SettingsKey.textPreset)
    }

    private func setBase(_ size: Double, for area: TextArea) {
        bases[area] = size
        defaults.set(size, forKey: SettingsKey.textSize(area.rawValue))
    }

    private func setMinimum(_ size: Double) {
        minimum = size
        defaults.set(size, forKey: SettingsKey.textMinimum)
    }
}

/// Sizes for one area: every text style grows with the body size, and none goes below the
/// minimum.
struct TextScale: Equatable {
    /// macOS's body text size, the base at the standard setting.
    static let macBody: Double = 13

    var base: Double = macBody
    var minimum: Double = 0

    /// How much bigger than macOS's body text.
    var factor: Double { base / Self.macBody }

    func size(_ style: Font.TextStyle) -> Double {
        max(Self.macDefault(style) * factor, minimum).rounded()
    }

    /// macOS's point sizes for the text styles.
    private static func macDefault(_ style: Font.TextStyle) -> Double {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }
}

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue = TextScale()
}

extension EnvironmentValues {
    var textScale: TextScale {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

extension View {
    /// Text below uses this area's sizes (plain text gets its body size).
    func textArea(_ area: TextArea) -> some View {
        modifier(TextAreaModifier(area: area))
    }

    /// A text style at the current area's size.
    func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(AppFontModifier(style: style, weight: weight, design: design))
    }

    /// Push buttons below follow the area's text size (macOS keeps their title at its own size
    /// whatever `.font` says). Not for a whole window: toolbar buttons would turn into push buttons.
    func scaledButtons() -> some View {
        buttonStyle(ScaledButtonStyle())
    }

    /// A fixed width that grows with the text size.
    func scaledFrame(width: CGFloat, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(ScaledFrameModifier(width: width, height: height, alignment: alignment))
    }
}

private struct TextAreaModifier: ViewModifier {
    let area: TextArea

    func body(content: Content) -> some View {
        let scale = TextSettings.shared.scale(for: area)
        content
            .environment(\.textScale, scale)
            .font(.system(size: scale.size(.body)))
    }
}

private struct AppFontModifier: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        let defaultWeight: Font.Weight = style == .headline ? .bold : .regular
        content.font(.system(size: scale.size(style), weight: weight ?? defaultWeight, design: design))
    }
}

private struct ScaledFrameModifier: ViewModifier {
    let width: CGFloat
    let height: CGFloat?
    let alignment: Alignment
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        content.frame(width: width * max(1, scale.factor), height: height.map { $0 * max(1, scale.factor) }, alignment: alignment)
    }
}

/// A push button whose title is the area's size, and whose bezel is the control size that fits
/// it. A button that asked for a small control keeps its smaller text.
struct ScaledButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScaledPushButton(configuration: configuration)
    }
}

private struct ScaledPushButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    @Environment(\.textScale) private var scale
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let size = scale.size(controlSize == .small || controlSize == .mini ? .subheadline : .body)
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.font(.system(size: size))
        }
        .buttonStyle(.automatic) // the platform's push button, not this style again
        .controlSize(size <= 11 ? .small : size <= 13 ? .regular : size <= 17 ? .large : .extraLarge)
    }
}
