# Codex Status Monitor

Native macOS menu bar app for monitoring the OpenAI Codex VS Code extension.

Codex can pause on confirmation prompts while the user is focused elsewhere. This app keeps the current Codex state visible in the menu bar and sends a system notification when a turn completes.

## Features

- Native macOS AppKit menu bar app.
- Aggregated Codex state in the menu bar:
  - `idle`
  - `running`
  - `waiting`
- Multi-session aware: any waiting session takes priority over running sessions.
- System notification when a Codex turn completes.
- Manual `Reset Status` fallback for stale state after VS Code or Codex crashes.
- Built-in VS Code extension patch installer/repair action.
- Version-aware patch strategy:
  - stable host event hook first
  - version-range webview fallback for pending request UI
  - unsupported versions fail closed instead of modifying unknown bundles

## Supported Platform

- macOS only.
- VS Code and VS Code Insiders extension directories:
  - `~/.vscode/extensions/openai.chatgpt-*`
  - `~/.vscode-insiders/extensions/openai.chatgpt-*`
- Initial patch rule coverage:
  - `openai.chatgpt` `26.406.x` through `26.5429.x`
  - includes the locally observed `26.429.30905`

## Build

```bash
swift build
```

Build an `.app` bundle:

```bash
scripts/build-app.sh
```

The bundle is generated at:

```text
.build/CodexStatusMonitor.app
```

## Run Locally

Open the generated app bundle directly:

```bash
open .build/CodexStatusMonitor.app
```

The app runs as a menu bar accessory and does not show a Dock icon. The build script ad-hoc signs the local bundle.

## Notifications

The app sends completion notifications through `UNUserNotificationCenter`.

If notifications do not appear:

1. Open the menu bar item.
2. Check the `Notifications: ...` line.
3. Click `Open Notification Settings`.
4. Enable notifications for `Codex Status Monitor`.

## Install or Repair the VS Code Patch

1. Start `CodexStatusMonitor.app`.
2. Open the menu bar item.
3. Click `Install/Repair VSCode Patch`.
4. Reload the VS Code window or restart VS Code so the extension host reloads.

The patch writes events to:

```text
~/Library/Application Support/CodexStatusMonitor/events.jsonl
```

The app polls this JSONL file every 500ms and updates menu bar state from newly appended events. On launch it only preloads the last 20 events for the `Recent events` menu; it does not replay old events into active session state.

## Patch Behavior

The patcher modifies the installed VS Code extension bundle in place.

- It backs up modified files next to the original file using:

```text
.codex-status-monitor.bak
```

- It validates patched JavaScript with:

```bash
node --check
```

- It is intended to be idempotent. Running `Install/Repair VSCode Patch` repeatedly should not keep changing files.
- It does not silently patch unsupported versions.

Patch event coverage includes:

- `codex/event/task_started`
- `codex/event/task_complete`
- `codex/event/turn_aborted`
- `codex/event/error`
- `codex/event/stream_error`
- `codex/event/request_user_input`
- `codex/event/exec_approval_request`
- `codex/event/apply_patch_approval_request`
- `codex/event/elicitation_request`
- `turn/started`
- `turn/completed`
- `item/started`
- `item/agentMessage/delta`
- `item/reasoning/textDelta`
- `item/reasoning/summaryTextDelta`
- `item/plan/delta`
- `item/completed` for final `agentMessage` completion
- MCP task status `input_required`
- webview pending request fallback for plan confirmation and similar UI prompts

`item/completed` events for `userMessage`, `commandExecution`, and `reasoning` are not treated as final turn completion. This avoids clearing `running` or firing a completion notification while Codex is still executing follow-up work.

## State Semantics

The aggregate menu bar state is:

```text
waiting > running > idle
```

`waiting` means at least one active session is blocked on user action, including approval requests, plan confirmation, plan mode choices, or other pending request UI.

Completion notifications are sent for final turn completion candidates only:

- `codex/event/task_complete`
- `turn/completed`
- `item/completed` with `requestType == "agentMessage"`
- `notifications/tasks/status` with `status == "completed"`

Notifications are delayed briefly and cancelled if the same conversation starts running again before delivery. This filters out intermediate completion-looking events in multi-step turns.

## Test

```bash
swift test
```

Current test coverage includes:

- single-session state transitions
- multi-session aggregation priority
- `input_required` mapping to `waiting`
- current extension `item/*` event names
- command/reasoning/user message completion edge cases
- turn completion callback
- JSONL polling for events appended after app startup
- patch rule selection across VSIX fixtures in `Tests/Fixtures/vsix`
- host patch idempotence on a temporary copied extension

## Repository Layout

```text
Sources/CodexStatusMonitor/
  AppDelegate.swift          Menu bar UI and app lifecycle
  EventTailer.swift          JSONL file tailing
  ExtensionLocator.swift     VS Code extension discovery
  Models.swift               Shared state/event models
  PatchInstaller.swift       Patch orchestration
  PatchRules.swift           Host and webview patch rules
  Paths.swift                App support paths
  StatusStore.swift          State reducer and aggregation

Tests/CodexStatusMonitorTests/
  EventTailerTests.swift
  PatchRuleTests.swift
  StatusStoreTests.swift

scripts/
  build-app.sh
```

## Notes

- VS Code extension updates replace the patched bundle. Run `Install/Repair VSCode Patch` again after extension upgrades.
- If state looks stale, use `Reset Status` from the menu.
- The app currently stores state in memory and reconstructs future state from new events only.
