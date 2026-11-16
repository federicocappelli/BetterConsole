import SwiftUI
import BCFilter

/// One chip in the filter bar. Clicking a condition opens its menu; while `isEditing` it is
/// an inline text field for the value instead. Clicking an Advanced rule or a link opens the
/// filter editor; their context menu removes them.
struct BubbleView: View {
    let bubble: Bubble
    let isSelected: Bool
    let isEditing: Bool
    /// A saved filter's name, or nil when it no longer exists (a missing link).
    let linkName: (UUID) -> String?
    let onOpenEditor: () -> Void
    let onChange: (Bubble) -> Void
    let onRemove: () -> Void
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void

    var body: some View {
        switch bubble.content {
        case .advanced(let expression):
            Button(action: onOpenEditor) {
                Chip(style: .advanced, isSelected: isSelected) {
                    Text("Advanced rule")
                }
            }
            .chipButton()
            .contextMenu { editorMenu }
            .help("\(ExpressionSummary.text(expression))\nClick to edit in the filter editor.")
        case .link(let id, let include):
            let name = linkName(id)
            Button(action: onOpenEditor) {
                Chip(style: name == nil ? .invalid : include ? .include : .exclude, isSelected: isSelected) {
                    if !include { Text("⊘") }
                    if let name {
                        Text("FILTER")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(name).truncationMode(.middle)
                    } else {
                        Text(EditorText.missingFilter).foregroundStyle(.red)
                    }
                }
            }
            .chipButton()
            .contextMenu { editorMenu }
            .accessibilityLabel(EditorText.linkBubble(name: name, include: include))
            .help(
                name == nil
                    ? "\(EditorText.missingLinkHelp). Click to fix it in the filter editor."
                    : "Click to edit in the filter editor.")
        case .condition(let condition, let include):
            if isEditing {
                ValueEditor(initial: condition.value) { value in
                    if let value, !value.isEmpty, value != condition.value {
                        var edited = condition
                        edited.value = value
                        onChange(Bubble(id: bubble.id, content: .condition(edited, include: include)))
                    }
                    onEndEditing()
                }
            } else {
                Menu {
                    menu(condition, include: include)
                } label: {
                    Chip(
                        style: condition.valueProblem != nil ? .invalid : include ? .include : .exclude,
                        isSelected: isSelected
                    ) {
                        label(condition, include: include)
                    }
                    // Disabled (ES §13.6): dimmed and struck through, as it applies nothing.
                    .opacity(condition.isEnabled ? 1 : 0.5)
                }
                .chipMenu()
                .optionalHelp(
                    condition.valueProblem
                        ?? (condition.isEnabled ? nil : "Disabled: this condition isn't applied."))
            }
        }
    }

    /// Advanced rule and link bubbles: open the editor or remove.
    @ViewBuilder
    private var editorMenu: some View {
        Button("Edit in Filter Editor", action: onOpenEditor)
        Divider()
        Button("Remove", action: onRemove)
    }

    /// A disabled condition strikes through every part, not just the value.
    @ViewBuilder
    private func label(_ c: FilterCondition, include: Bool) -> some View {
        let struck = !c.isEnabled
        if !include {
            Text("⊘").strikethrough(struck)
            Text("not").italic().strikethrough(struck)
        }
        Text(c.field.title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .strikethrough(struck)
        if c.field == .extra { Text(c.key ?? "").foregroundStyle(.secondary).strikethrough(struck) }
        Text(c.match.title(for: c.field)).foregroundStyle(.secondary).strikethrough(struck)
        Text(c.match == .between ? "\(c.value) – \(c.upperValue ?? "")" : c.value)
            .strikethrough(struck)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private func menu(_ c: FilterCondition, include: Bool) -> some View {
        Menu("Field") {
            ForEach(Self.barFields(current: c.field), id: \.self) { field in
                Toggle(field.title, isOn: checked(c.field == field) {
                    update(c.movedTo(field), include: include)
                })
            }
        }
        Menu("Match") {
            ForEach(c.field.allowedMatches, id: \.self) { match in
                Toggle(match.title(for: c.field), isOn: checked(c.match == match) {
                    var edited = c
                    edited.match = match
                    update(edited, include: include)
                })
            }
        }
        Divider()
        Toggle("Include", isOn: checked(include) { update(c, include: true) })
        Toggle("Exclude", isOn: checked(!include) { update(c, include: false) })
        Button(c.isEnabled ? "Disable" : "Enable") { onChange(BubbleEditing.toggled(bubble)) }
        Divider()
        if c.field == .type {
            Menu("Edit Value") {
                ForEach(FilterCondition.typeValues, id: \.self) { value in
                    Toggle(value.capitalized, isOn: checked(c.value.lowercased() == value) {
                        var edited = c
                        edited.value = value
                        update(edited, include: include)
                    })
                }
            }
        } else {
            Button("Edit Value…", action: onBeginEditing)
        }
        Divider()
        Button("Remove", action: onRemove)
    }

    /// Fields the bar can edit. Extra data and Time of day need the key / end editors of
    /// later tasks, so they are offered only as the bubble's current field (e.g. imported).
    private static func barFields(current: FilterField) -> [FilterField] {
        FilterField.allCases.filter { ![.extra, .timeOfDay].contains($0) || $0 == current }
    }

    private func update(_ c: FilterCondition, include: Bool) {
        let content = Bubble.Content.condition(c, include: include)
        guard content != bubble.content else { return }
        onChange(Bubble(id: bubble.id, content: content))
    }

    /// A menu checkmark that runs `action` when picked.
    private func checked(_ isOn: Bool, action: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isOn }, set: { _ in action() })
    }
}

/// The capsule drawn for a bubble.
private struct Chip<Content: View>: View {
    enum Style { case include, exclude, invalid, advanced }

    let style: Style
    let isSelected: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .font(.callout)
            .lineLimit(1)
            .frame(maxWidth: 360)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(fill))
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.accentColor : stroke, lineWidth: isSelected ? 2 : 1))
            .contentShape(Capsule())
    }

    private var fill: Color {
        switch style {
        case .include: Color.accentColor.opacity(0.15)
        case .exclude: Color.secondary.opacity(0.15)
        case .invalid: Color.red.opacity(0.2)
        case .advanced: Color.purple.opacity(0.15)
        }
    }

    private var stroke: Color {
        switch style {
        case .include: Color.accentColor.opacity(0.4)
        case .exclude: Color.secondary.opacity(0.4)
        case .invalid: Color.red
        case .advanced: Color.purple.opacity(0.4)
        }
    }
}

/// Inline value editor: Return or leaving the field commits, Escape cancels (nil).
private struct ValueEditor: View {
    let onDone: (String?) -> Void
    @State private var value: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(initial: String, onDone: @escaping (String?) -> Void) {
        self.onDone = onDone
        _value = State(initialValue: initial)
    }

    var body: some View {
        TextField("Value", text: $value)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(minWidth: 140, maxWidth: 360)
            .fixedSize()
            .focused($focused)
            .onSubmit { finish(value) }
            .onExitCommand { finish(nil) }
            .onAppear { focused = true }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(value) }
            }
    }

    private func finish(_ result: String?) {
        guard !finished else { return }
        finished = true
        onDone(result?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension View {
    /// A bubble-shaped menu button: the label as drawn, no arrow.
    fileprivate func chipMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    /// A bubble-shaped button: the label as drawn.
    fileprivate func chipButton() -> some View {
        buttonStyle(.plain).fixedSize()
    }

    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
