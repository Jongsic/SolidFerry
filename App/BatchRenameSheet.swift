import DeviceCore
import SwiftUI
import TransferKit

struct BatchRenameRequest: Identifiable {
    let id = UUID()
    let entries: [RemoteEntry]
    /// Names in the folder that aren't being renamed.
    let others: Set<String>
}

/// Rename several items at once: rules on the left are applied in order and previewed;
/// nothing changes until Rename.
struct BatchRenameSheet: View {
    let request: BatchRenameRequest
    let browser: BrowserModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.batchRenameRules) private var savedRules = Data()
    @State private var rules = BatchRenameRules()
    @State private var running: (done: Int, total: Int)?
    @State private var failure: String?

    private var rows: [BatchRenameRow] {
        BatchRename.preview(request.entries.map { ($0.name, $0.isDirectory) }, rules: rules, others: request.others)
    }

    var body: some View {
        let rows = rows
        let changing = rows.filter(\.changes).count
        let problems = rows.filter { $0.problem != nil }.count
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(request.entries.count) Items").appFont(.headline)
            HStack(alignment: .top, spacing: 16) {
                ruleForm.scaledFrame(width: 300)
                previewList(rows)
            }
            HStack {
                if let failure {
                    Text(failure).foregroundStyle(.red).lineLimit(2)
                } else if let running {
                    ProgressView(value: Double(running.done), total: Double(max(running.total, 1))).frame(width: 120)
                    Text("Renaming \(running.done) of \(running.total)…").foregroundStyle(.secondary).monospacedDigit()
                } else if problems > 0 {
                    Label("Fix the names marked in red to continue.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("\(changing) of \(request.entries.count) names change").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset Rules") { rules = BatchRenameRules() }
                    .disabled(running != nil)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running != nil)
                Button("Rename") { Task { await apply(rows) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problems > 0 || changing == 0 || running != nil)
            }
        }
        .padding(20)
        .scaledFrame(width: 820, height: 520)
        .textArea(.panels)
        .scaledButtons()
        .onAppear {
            if let saved = try? JSONDecoder().decode(BatchRenameRules.self, from: savedRules) { rules = saved }
        }
        .onChange(of: rules) { _, new in savedRules = (try? JSONEncoder().encode(new)) ?? Data() }
    }

    private var ruleForm: some View {
        Form {
            Section("Find and Replace") {
                TextField("Find", text: $rules.find)
                TextField("Replace with", text: $rules.replace)
                Toggle("Regular expression", isOn: $rules.useRegex)
                Toggle("Match case", isOn: $rules.matchCase)
            }
            Section("Add Text") {
                TextField("Before name", text: $rules.prefix)
                TextField("After name", text: $rules.suffix)
                LabeledContent("Letter case") {
                    MenuChoice(selection: $rules.caseChange, items: [
                        .option(.unchanged, String(localized: "Unchanged")), .option(.lower, String(localized: "lowercase")),
                        .option(.upper, String(localized: "UPPERCASE")), .option(.title, String(localized: "Title Case")),
                    ])
                }
            }
            Section {
                Toggle("Add numbers", isOn: $rules.numbering)
                if rules.numbering {
                    LabeledContent("Position") {
                        MenuChoice(selection: $rules.numberPosition, items: [
                            .option(.before, String(localized: "Before name")), .option(.after, String(localized: "After name")),
                            .option(.replace, String(localized: "Instead of name")),
                        ])
                    }
                    Stepper(value: $rules.start, in: 0...999_999) {
                        LabeledContent("Start at") { Text(verbatim: "\(rules.start)").monospacedDigit() }
                    }
                    Stepper(value: $rules.step, in: 1...1000) {
                        LabeledContent("Step") { Text(verbatim: "\(rules.step)").monospacedDigit() }
                    }
                    Stepper(value: $rules.digits, in: 1...10) {
                        LabeledContent("Digits") { Text(verbatim: "\(rules.digits)").monospacedDigit() }
                    }
                    if rules.numberPosition != .replace {
                        TextField("Separator", text: $rules.separator)
                    }
                }
            } header: {
                Text("Numbers")
            } footer: {
                Text("Numbered in the order shown in the window.").appFont(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Change extensions too", isOn: $rules.includeExtension)
            }
        }
        .formStyle(.grouped)
        .disabled(running != nil)
    }

    private func previewList(_ rows: [BatchRenameRow]) -> some View {
        Table(rows.enumerated().map { PreviewRow(id: $0.offset, element: $0.element) }) {
            TableColumn("Current Name") { pair in
                Text(pair.element.oldName).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("New Name") { pair in
                HStack(spacing: 4) {
                    if pair.element.problem != nil {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    Text(pair.element.newName).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(pair.element.problem != nil ? AnyShapeStyle(.red)
                                         : pair.element.changes ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .help(problemText(pair.element.problem) ?? "")
            }
        }
    }

    private struct PreviewRow: Identifiable {
        let id: Int
        let element: BatchRenameRow
    }

    private func problemText(_ problem: BatchRenameRow.Problem?) -> String? {
        switch problem {
        case nil: nil
        case .invalid: String(localized: "This name can’t be used.")
        case .duplicate: String(localized: "Another item would get the same name.")
        case .taken: String(localized: "An item with this name is already in the folder.")
        case .badPattern: String(localized: "The search pattern isn’t valid.")
        }
    }

    private func apply(_ rows: [BatchRenameRow]) async {
        let steps = BatchRename.steps(rows)
        running = (0, steps.count)
        failure = nil
        let error = await browser.batchRename(steps) { done in running = (done, steps.count) }
        running = nil
        if let error {
            failure = error
        } else {
            dismiss()
        }
    }
}
