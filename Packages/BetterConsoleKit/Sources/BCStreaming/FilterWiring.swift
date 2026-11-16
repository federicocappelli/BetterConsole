import BCFilter

/// Keeps each session's filter in step with `workspace` (filters spec §9): a session created
/// when its device appears (at launch, or on its return after its empty session was dropped)
/// starts with the device's current filter state, and an expression the workspace changes
/// (an edit, a selection, a save reaching other devices) reaches the device's live session.
@MainActor
public func connect(registry: SessionRegistry, workspace: FilterWorkspace) {
    registry.onSessionCreated = { [workspace] session in
        session.setFilter(workspace.state(for: session.device.id).expression)
    }
    workspace.onExpressionChange = { [weak registry] id, expression in
        registry?.session(for: id)?.setFilter(expression)
    }
}
