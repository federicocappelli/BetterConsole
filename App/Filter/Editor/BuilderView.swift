import SwiftUI
import UniformTypeIdentifiers
import BCFilter

/// The editor's visual builder (ES §8.2, §13.1): nested groups of condition and saved-filter
/// rows. Disabled while the text has an error (R14), so a builder change never discards
/// text being fixed.
struct BuilderView: View {
    let state: FilterEditorState

    var body: some View {
        VStack(spacing: 0) {
            if state.model.textError != nil {
                Label(EditorText.errorLabel, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.08))
                Divider()
            }
            GeometryReader { proxy in
                // At least as wide as the pane; wider rows scroll sideways from the leading edge.
                ScrollView([.vertical, .horizontal]) {
                    GroupView(state: state, node: state.model.root, depth: 0)
                        .padding(12)
                        .frame(minWidth: proxy.size.width, alignment: .topLeading)
                }
                .disabled(state.model.textError != nil)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// A group: the kind menu, ⧉ and ⋯, its members, then the add bar.
private struct GroupView: View {
    let state: FilterEditorState
    let node: EditorNode
    let depth: Int

    private var model: FilterEditorModel { state.model }
    private var isRoot: Bool { depth == 0 }
    private static let edgeColors: [Color] = [.accentColor, .orange, .purple, .teal, .pink, .green]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                MemberRow(state: state, node: child, parent: node.id, index: index, depth: depth + 1)
            }
            AddBar(state: state, groupID: node.id, count: node.children.count)
        }
        .padding(.vertical, 6)
        .padding(.leading, isRoot ? 6 : 10)
        .padding(.trailing, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isRoot ? 0.0 : 0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.35)))
        .overlay(alignment: .leading) {
            if !isRoot {
                UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6)
                    .fill(Self.edgeColors[(depth - 1) % Self.edgeColors.count])
                    .frame(width: 3)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if !isRoot { DragHandle(id: node.id) }
            Menu {
                ForEach(GroupKind.allCases, id: \.self) { kind in
                    Button(kind.title) { model.setGroupKind(node.id, kind) }
                }
            } label: {
                Text(node.kind.groupKind?.title ?? "")
            }
            .fixedSize()
            .help("How the members combine")
            Spacer(minLength: 12)
            if !isRoot {
                Button { model.duplicate(node.id) } label: { Image(systemName: "plus.square.on.square") }
                    .buttonStyle(.borderless)
                    .help("Duplicate")
                Menu {
                    Button("Delete") { model.delete(node.id) }
                    Button("Ungroup") { model.ungroup(node.id) }
                    Divider()
                    MoveButtons(model: model, id: node.id)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        .padding(.leading, isRoot ? 0 : 2)
    }
}

/// One member of a group, selectable, draggable from its handle, and a drop target that
/// inserts the dragged row before it.
private struct MemberRow: View {
    let state: FilterEditorState
    let node: EditorNode
    let parent: UUID
    let index: Int
    let depth: Int

    @State private var isTargeted = false

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(state.selectedNodeID == node.id ? Color.accentColor.opacity(0.18) : .clear))
            .overlay(alignment: .top) {
                if isTargeted {
                    Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { select() }
            .dropDestination(for: BuilderDrag.self) { items, _ in
                guard let id = items.first?.id, id != node.id else { return false }
                state.model.move(id, to: parent, index: index)
                return true
            } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .group:
            AnyView(GroupView(state: state, node: node, depth: depth))
        case .condition(let condition):
            ConditionRow(state: state, id: node.id, condition: condition)
        case .link(let target):
            LinkRow(state: state, id: node.id, target: target)
        }
    }

    private func select() {
        state.selectionFromText = false
        state.selectedNodeID = node.id
    }
}

/// ⋮⋮ to drag the row to another place (ES §8.2).
struct DragHandle: View {
    let id: UUID

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.tertiary)
            .frame(width: 14, height: 20)
            .contentShape(Rectangle())
            .draggable(BuilderDrag(id: id))
            .help("Drag to move")
    }
}

struct MoveButtons: View {
    let model: FilterEditorModel
    let id: UUID

    var body: some View {
        let location = model.location(of: id)
        let count = location.flatMap { model.node($0.parent)?.children.count } ?? 0
        Button("Move Up") { model.move(id, by: -1) }
            .disabled((location?.index ?? 0) == 0)
        Button("Move Down") { model.move(id, by: 1) }
            .disabled((location?.index ?? count) >= count - 1)
    }
}

/// ＋ Condition  ＋ Group  ＋ Saved filter; dropping a row here moves it to the group's end.
private struct AddBar: View {
    let state: FilterEditorState
    let groupID: UUID
    let count: Int

    @State private var isTargeted = false

    private var model: FilterEditorModel { state.model }

    var body: some View {
        HStack(spacing: 14) {
            Button("＋ Condition") {
                if let id = model.add(.condition(FilterEditorModel.newCondition), to: groupID) {
                    state.selectedNodeID = id
                }
            }
            let canAddGroup = model.canAddGroup(to: groupID)
            Button("＋ Group") {
                if let id = model.add(.group(.allOf), to: groupID) { state.selectedNodeID = id }
            }
            .disabled(!canAddGroup)
            .help(canAddGroup ? "Add a group" : EditorText.tooDeep)
            let choices = model.linkChoices
            Menu("＋ Saved filter") {
                ForEach(choices) { filter in
                    Button(filter.name) {
                        if let id = model.add(.link(filter.id), to: groupID) { state.selectedNodeID = id }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(choices.isEmpty)
            .help(choices.isEmpty ? "No saved filter can be added here" : "Match a saved filter")
        }
        .buttonStyle(.borderless)
        .padding(.top, 2)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : .clear)
        .dropDestination(for: BuilderDrag.self) { items, _ in
            guard let id = items.first?.id else { return false }
            model.move(id, to: groupID, index: count)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
