# Contributing

This project is intentionally small: a Swift/AppKit menu bar app plus version-aware patch rules for the Codex VS Code extension.

## Development Setup

Requirements:

- macOS
- Xcode command line tools or Xcode
- SwiftPM
- Node.js, used by the patcher for `node --check`

Build:

```bash
swift build
```

Test:

```bash
swift test
```

Build and run the local `.app` bundle:

```bash
scripts/build-app.sh
open .build/CodexStatusMonitor.app
```

## Engineering Guidelines

- Keep the menu bar app native AppKit unless there is a clear reason to add another UI framework.
- Keep notification delivery on `UNUserNotificationCenter`; do not add script-based notification fallbacks.
- Keep the bundle metadata stable in `Sources/CodexStatusMonitor/Resources/Info.plist`.
- Keep patch rules fail-closed. Unsupported versions must report unsupported rather than patching uncertain anchors.
- Patch rules must be idempotent.
- Patch rules must create backups before writing.
- Patched JavaScript must pass `node --check`.
- Keep state transitions in `StatusStore` deterministic and covered by tests.

## Patch Rule Maintenance

Patch rules live in:

```text
Sources/CodexStatusMonitor/PatchRules.swift
```

The registry is:

```text
PatchRuleRegistry
```

Current rule types:

- `DefaultHostPatchRule`
- `PendingRequestWebviewPatchRule`

When a new VS Code extension version appears:

1. Add the unpacked VSIX or extension directory under `references/vsix-history`.
2. Inspect the new `extension/out/extension.js`.
3. Prefer a stable host event hook before adding webview-specific logic.
4. If the host hook is not enough, add a version-range webview rule.
5. Extend tests so the new version is covered by `PatchRuleTests`.
6. Run:

```bash
swift test
```

## Patch Safety Checklist

Before changing patch logic, verify:

- `check` correctly reports installed and missing states.
- `apply` is idempotent.
- `restore` uses the `.codex-status-monitor.bak` backup.
- unknown versions are not modified.
- every modified JavaScript file passes `node --check`.

## Event Contract

The VS Code patch writes one JSON object per line to:

```text
~/Library/Application Support/CodexStatusMonitor/events.jsonl
```

The app polls this file every 500ms. It starts from the current end of the file, so historical events are only used for the menu's recent-event display and are not replayed into active session state.

Runtime diagnostics are written to:

```text
~/Library/Application Support/CodexStatusMonitor/app.log
```

Expected fields:

```json
{
  "schemaVersion": 1,
  "timestamp": "2026-05-06T00:00:00.000Z",
  "extensionVersion": "26.429.30905",
  "source": "vscode-extension-host",
  "eventType": "codex/event/task_started",
  "conversationId": "conversation-id",
  "requestId": null,
  "requestType": null,
  "status": null
}
```

Additive fields are acceptable. Renaming or removing existing fields requires updating `CodexStatusEvent` and tests.

## State Semantics

Menu bar aggregate state is calculated as:

```text
waiting > running > idle
```

Events that currently map to `waiting`:

- `codex/event/request_user_input`
- `codex/event/exec_approval_request`
- `codex/event/apply_patch_approval_request`
- `codex/event/elicitation_request`
- `codex-status-monitor/pending_request`
- `notifications/tasks/status` with `status == "input_required"`

Events that currently map to `running`:

- `codex/event/task_started`
- `turn/started`
- `item/started`
- `item/agentMessage/delta`
- `item/reasoning/textDelta`
- `item/reasoning/summaryTextDelta`
- `item/plan/delta`
- `notifications/tasks/status` with `status == "working"`

Events that complete or clear a session:

- `codex/event/task_complete`
- `turn/completed`
- `item/completed` with `requestType == "agentMessage"`
- `codex/event/turn_aborted`
- `codex/event/error`
- `codex/event/stream_error`
- `notifications/tasks/status` with terminal status

`item/completed` with `requestType == "userMessage"` is ignored. `item/completed` with `requestType == "commandExecution"` or `requestType == "reasoning"` is also ignored for state completion, because those events commonly occur before Codex starts more work in the same turn.

Completion notifications are emitted only for final completion candidates:

- `codex/event/task_complete`
- `turn/completed`
- `item/completed` with `requestType == "agentMessage"`
- `notifications/tasks/status` with `status == "completed"`

The app delays completion notification delivery briefly and cancels the pending notification if the same conversation emits a new running event before delivery.

## Pull Request Checklist

- Run `swift build`.
- Run `swift test`.
- Run `scripts/build-app.sh` when bundle metadata or app packaging changes.
- If patch logic changed, test against all versions in `references/vsix-history`.
- Update `README.md` if user-facing behavior changed.
- Update this file if contributor workflow changed.
