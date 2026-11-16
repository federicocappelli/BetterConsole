import SwiftUI
import BCFilter

/// ☑ Field ▾ Match ▾ value ⋯ (ES §8.2). A disabled row is dimmed and struck through; an
/// invalid value is red with the problem as its help.
struct ConditionRow: View {
    let state: FilterEditorState
    let id: UUID
    let condition: FilterCondition

    private var model: FilterEditorModel { state.model }

    var body: some View {
        HStack(spacing: 6) {
            DragHandle(id: id)
            Toggle("", isOn: Binding(get: { condition.isEnabled }, set: { model.setEnabled(id, $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(condition.isEnabled ? "Switch this condition off" : "Switch this condition on")
            Group {
                fieldMenu
                matchMenu
                ValueEditor(
                    condition: condition,
                    onChange: { model.update(id, condition: $0, coalescing: $1) },
                    onEndTyping: { model.endCoalescing() })
            }
            .strikethrough(!condition.isEnabled)
            .opacity(condition.isEnabled ? 1 : 0.45)
            Spacer(minLength: 4)
            Menu {
                Button("Duplicate") { model.duplicate(id) }
                Button("Delete") { model.delete(id) }
                Button("Wrap in Group") { model.wrapInGroup(id) }
                    .disabled(!model.canWrap(id))
                Divider()
                MoveButtons(model: model, id: id)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

    private var fieldMenu: some View {
        Menu {
            ForEach(FilterField.allCases, id: \.self) { field in
                Button(field.title) { model.update(id, condition: condition.movedTo(field)) }
            }
        } label: {
            Text(condition.field.title)
        }
        .fixedSize()
    }

    private var matchMenu: some View {
        Menu {
            ForEach(condition.field.allowedMatches, id: \.self) { match in
                Button(match.title(for: condition.field)) {
                    var changed = condition
                    changed.match = match
                    // Leaving regex on Type turns the value back into a Type.
                    model.update(id, condition: changed.movedTo(changed.field))
                }
            }
        } label: {
            Text(condition.match.title(for: condition.field))
        }
        .fixedSize()
    }
}

/// The value editor for the condition's field (ES §8.2): a Type menu in `log`'s order, two
/// times for Time of day, a key and a value for Extra data, otherwise one text field.
private struct ValueEditor: View {
    let condition: FilterCondition
    /// The changed condition, and whether it comes from typing (one undo step per run, R16).
    let onChange: (FilterCondition, _ typing: Bool) -> Void
    /// Typing ended: the field lost focus or was submitted.
    let onEndTyping: () -> Void

    @FocusState private var focus: PartialKeyPath<FilterCondition>?

    private var problem: String? { condition.valueProblem }

    var body: some View {
        Group {
            switch condition.field {
            case .type where condition.match != .regex:
                Menu {
                    ForEach(FilterCondition.typeValues, id: \.self) { value in
                        Button(value.capitalized) { set(\.value, value, typing: false) }
                    }
                } label: {
                    Text(condition.value.capitalized)
                }
                .fixedSize()
            case .timeOfDay:
                field("HH:mm", \.value, width: 80)
                Text("–")
                field("HH:mm", \.upperValueText, width: 80)
            case .extra:
                field("Key", \.keyText, width: 90)
                field("Value", \.value, width: 150)
            default:
                field("Value", \.value, width: 190)
            }
        }
        .help(problem ?? "")
        .onChange(of: focus) { onEndTyping() }
    }

    private func field(_ prompt: String, _ path: WritableKeyPath<FilterCondition, String>, width: CGFloat) -> some View {
        TextField(prompt, text: Binding(get: { condition[keyPath: path] }, set: { set(path, $0, typing: true) }))
            .textFieldStyle(.roundedBorder)
            .focused($focus, equals: path)
            .onSubmit(onEndTyping)
            .foregroundStyle(problem == nil ? Color.primary : Color.red)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(problem == nil ? Color.clear : Color.red, lineWidth: 1))
            .frame(minWidth: width * 0.6, idealWidth: width, maxWidth: width)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func set(_ path: WritableKeyPath<FilterCondition, String>, _ value: String, typing: Bool) {
        var changed = condition
        changed[keyPath: path] = value
        if changed != condition { onChange(changed, typing) }
    }
}

private extension FilterCondition {
    var upperValueText: String {
        get { upperValue ?? "" }
        set { upperValue = newValue }
    }

    var keyText: String {
        get { key ?? "" }
        set { key = newValue }
    }
}

/// "Matches saved filter [name ▾]"; a deleted filter reads red "Missing filter" (ES §8.2).
struct LinkRow: View {
    let state: FilterEditorState
    let id: UUID
    let target: UUID

    private var model: FilterEditorModel { state.model }

    var body: some View {
        let status = model.linkStatus(target)
        HStack(spacing: 6) {
            DragHandle(id: id)
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            Text("Matches saved filter")
            Menu {
                ForEach(model.linkChoices) { filter in
                    Button(filter.name) { model.setLink(id, to: filter.id) }
                }
            } label: {
                switch status {
                case .ok(let name): Text(name)
                // The red label beside the menu says the filter is missing.
                case .missing: Text("Choose…")
                case .loop: Text(state.library.filter(id: target)?.name ?? "Choose…")
                }
            }
            .fixedSize()
            switch status {
            case .ok: EmptyView()
            case .missing:
                Text(EditorText.missingFilter)
                    .foregroundStyle(.red)
                    .help(EditorText.missingLinkHelp)
            case .loop:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(EditorText.includesItself(state.filterName))
            }
            Spacer(minLength: 4)
            Menu {
                Button("Duplicate") { model.duplicate(id) }
                Button("Delete") { model.delete(id) }
                Button("Wrap in Group") { model.wrapInGroup(id) }
                    .disabled(!model.canWrap(id))
                Divider()
                MoveButtons(model: model, id: id)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }
}
