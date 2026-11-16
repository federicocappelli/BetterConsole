import SwiftUI
import BCFilter

/// One chip in the filter bar. Clicking it opens its menu; while `isEditing` it is an inline
/// text field for the value instead.
struct BubbleView: View {
    let bubble: Bubble
    let isSelected: Bool
    let isEditing: Bool
    let onChange: (Bubble) -> Void
    let onRemove: () -> Void
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void

    var body: some View {
        switch bubble.content {
        case .advanced(let expression):
            Menu {
                Button("Remove", action: onRemove)
            } label: {
                Chip(style: .advanced, isSelected: isSelected) {
                    Text("Advanced rule")
                }
            }
            .chipMenu()
            .help(ExpressionSummary.text(expression))
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
                }
                .chipMenu()
                .optionalHelp(condition.valueProblem)
            }
        }
    }

    @ViewBuilder
    private func label(_ c: FilterCondition, include: Bool) -> some View {
        if !include {
            Text("⊘")
            Text("not").italic()
        }
        Text(c.field.title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        Text(c.match.title).foregroundStyle(.secondary)
        Text(c.value)
            .strikethrough(!include)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private func menu(_ c: FilterCondition, include: Bool) -> some View {
        Menu("Field") {
            ForEach(FilterField.allCases, id: \.self) { field in
                Toggle(field.title, isOn: checked(c.field == field) {
                    update(c.movedTo(field), include: include)
                })
            }
        }
        Menu("Match") {
            ForEach(c.field.allowedMatches, id: \.self) { match in
                Toggle(match.title, isOn: checked(c.match == match) {
                    var edited = c
                    edited.match = match
                    update(edited, include: include)
                })
            }
        }
        Divider()
        Toggle("Include", isOn: checked(include) { update(c, include: true) })
        Toggle("Exclude", isOn: checked(!include) { update(c, include: false) })
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

    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
