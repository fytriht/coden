---
name: add-patch-strategy
description: Upgrade Codex Status Monitor patch strategy for new OpenAI Codex VS Code extension versions or changed plugin structure. Use when patch anchors fail, a new openai.chatgpt extension version needs support, patch-config.json needs a new strategy, or PatchRuleTests fixtures must be refreshed.
---

# Add Patch Strategy

Use this skill to upgrade the Codex Status Monitor patch strategy after the OpenAI Codex VS Code extension changes structure.

## How to Use

Invoke the skill when a new Codex VS Code extension version breaks the existing patch or when plugin structure changes.

In Codex, ask:

```text
使用 add-patch-strategy 升级 patch 策略
```

In Claude Code, ask from this repository:

```text
/add-patch-strategy 升级 patch 策略
```

By default, use the newest installed extension under `~/.vscode/extensions/openai.chatgpt-*/extension`. If slash invocation is unavailable, use a natural-language request that mentions `add-patch-strategy`.

If the extension is installed somewhere else, include the explicit extension root path in the request.

The agent should then run the workflow below, update the repository, and report:

- selected extension version
- fixture path created or reused
- patch strategy changes
- validation results

You can also run the bundled helper scripts directly for inspection:

```bash
.agents/skills/add-patch-strategy/scripts/analyze-extension.sh
.agents/skills/add-patch-strategy/scripts/prepare-fixture.sh
```

`analyze-extension.sh` is read-only. `prepare-fixture.sh` writes only the minimal fixture under `Tests/Fixtures/vsix`. Both scripts accept an optional explicit extension root path.

## Inputs

Default to the newest local extension directory matching `~/.vscode/extensions/openai.chatgpt-*/extension`. The root must contain `package.json` and `out/extension.js`.

Common locations:

```bash
~/.vscode/extensions/openai.chatgpt-*/extension
Tests/Fixtures/vsix/openai.chatgpt-*/extension
```

If the user provides a VSIX instead, unpack it first, then continue with the unpacked `extension` directory.

## Workflow

1. Run `git status --short` first. Do not modify staged state unless the user explicitly asks.
2. Identify the extension root. If the user did not provide one, use the newest `~/.vscode/extensions/openai.chatgpt-*/extension`.
3. Identify the extension version from `package.json`.
4. Run `scripts/analyze-extension.sh` from this skill to inspect the default newest extension, or pass `<extension-root>` when using an explicit path:
   - host entry anchors in `out/extension.js`
   - webview asset bundles that mention `pendingRequest` and `implementPlan`
   - candidate bridge variables and pending request function anchors
5. Prefer updating config over Swift logic:
   - Update `Sources/CodexStatusMonitor/Resources/patch-config.json` when existing rule types can express the new structure.
   - Also update `PatchConfigLoader.hardcodedDefault()` in `Sources/CodexStatusMonitor/PatchConfig.swift` if the bundled fallback would otherwise diverge.
6. Modify `Sources/CodexStatusMonitor/PatchRules.swift` only when the config schema or existing rule types cannot safely express the new structure.
7. If the version is new, run `scripts/prepare-fixture.sh` from this skill to create or refresh the minimal fixture under `Tests/Fixtures/vsix`; pass `<extension-root>` when using an explicit path.
8. Extend tests only as needed. Preserve these invariants:
   - unsupported or unknown versions fail closed
   - `check` reports supported/missing and installed states accurately
   - `apply` is idempotent
   - backups use `.codex-status-monitor.bak`
   - every modified JavaScript file passes `node --check`
9. Run `swift test`.

## Strategy Rules

Keep the host hook first. The host rule observes stable MCP and webview-dispatched notifications and should be preferred over webview-specific parsing.

Use a webview rule only for events that the host hook cannot observe directly. When adding webview anchors:

- Use the shortest anchor that is still specific to the pending request function.
- Include version-range-specific anchors in `patch-config.json` instead of widening a fragile anchor globally.
- Keep `versionRange` half-open when replacing a strategy: old strategy `to` should equal new strategy `from`.
- Keep `bridgeExpression` limited to variables confirmed in the target webview bundle.

## Fixture Rules

Fixtures must be minimal. Keep only:

- `extension/package.json`
- `extension/out/extension.js`
- the specific `extension/webview/assets/*.js` bundle that contains the webview pending request anchor

Do not commit full unpacked extensions.

## Validation Checklist

Before final response, confirm:

- `git status --short` shows only intended files.
- `swift test` passed.
- If scripts were used, report the extension version and selected fixture path.
- If validation could not run, state the exact blocker.
