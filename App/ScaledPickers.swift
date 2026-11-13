import AppKit
import SwiftUI

// SwiftUI's segmented and menu Pickers keep macOS's own text size whatever `.font` says, so
// these are macOS's controls with their font set to the area's size (see `scaledButtons`).

/// One of a few options, side by side (macOS's segmented control).
struct SegmentedChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        SegmentedControl(selection: $selection, options: options).fixedSize()
    }
}

/// One of a list of options, in a pop-up menu.
struct MenuChoice<Value: Hashable>: View {
    enum Item {
        case option(Value, String, enabled: Bool = true)
        case divider
    }

    @Binding var selection: Value
    let items: [Item]
    var weight: NSFont.Weight = .regular

    var body: some View {
        PopUpControl(selection: $selection, items: items, weight: weight).fixedSize()
    }
}

/// The control size whose usual text is closest to `size`.
private func nsControlSize(forText size: Double) -> NSControl.ControlSize {
    if size > 17, #available(macOS 26, *) { return .extraLarge }
    return size <= 11 ? .small : size <= 13 ? .regular : .large
}

private struct SegmentedControl<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: [], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentStyle = .automatic
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        let size = context.environment.textScale.size(.body)
        control.font = .systemFont(ofSize: size)
        control.controlSize = nsControlSize(forText: size)
        control.segmentCount = options.count
        for (index, option) in options.enumerated() {
            control.setLabel(option.title, forSegment: index)
            control.setWidth(0, forSegment: index) // fit the label
        }
        control.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
        control.isEnabled = context.environment.isEnabled
        control.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: SegmentedControl

        init(_ parent: SegmentedControl) { self.parent = parent }

        @objc func changed(_ control: NSSegmentedControl) {
            guard parent.options.indices.contains(control.selectedSegment) else { return }
            parent.selection = parent.options[control.selectedSegment].value
        }
    }
}

private struct PopUpControl<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let items: [MenuChoice<Value>.Item]
    let weight: NSFont.Weight

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let size = context.environment.textScale.size(.body)
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        button.font = font
        button.controlSize = nsControlSize(forText: size)
        button.menu?.font = font
        button.removeAllItems()
        var selected: NSMenuItem?
        for (index, item) in items.enumerated() {
            switch item {
            case .divider:
                button.menu?.addItem(.separator())
            case .option(let value, let title, let enabled):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.tag = index
                menuItem.isEnabled = enabled
                button.menu?.addItem(menuItem)
                if value == selection { selected = menuItem }
            }
        }
        button.select(selected)
        button.isEnabled = context.environment.isEnabled
        button.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: PopUpControl

        init(_ parent: PopUpControl) { self.parent = parent }

        @objc func changed(_ button: NSPopUpButton) {
            guard let tag = button.selectedItem?.tag, parent.items.indices.contains(tag),
                  case .option(let value, _, _) = parent.items[tag] else { return }
            parent.selection = value
        }
    }
}
