#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [extension-root]" >&2
  exit 2
}

default_extension_root() {
  node <<'NODE'
const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".vscode", "extensions");
let candidates = [];
try {
  for (const entry of fs.readdirSync(dir)) {
    if (!entry.startsWith("openai.chatgpt-")) continue;
    const root = path.join(dir, entry);
    const pkg = path.join(root, "package.json");
    const host = path.join(root, "out", "extension.js");
    if (!fs.existsSync(pkg) || !fs.existsSync(host)) continue;
    const json = JSON.parse(fs.readFileSync(pkg, "utf8"));
    candidates.push({ root, version: String(json.version || "0.0.0") });
  }
} catch {}

function parts(v) {
  return v.split(".").map((x) => Number.parseInt(x, 10) || 0);
}

candidates.sort((a, b) => {
  const aa = parts(a.version);
  const bb = parts(b.version);
  for (let i = 0; i < Math.max(aa.length, bb.length); i += 1) {
    const d = (bb[i] || 0) - (aa[i] || 0);
    if (d) return d;
  }
  return b.root.localeCompare(a.root);
});

if (candidates[0]) console.log(candidates[0].root);
NODE
}

if [[ $# -gt 1 ]]; then
  usage
fi

if [[ $# -eq 1 ]]; then
  root="${1%/}"
else
  root="$(default_extension_root)"
  if [[ -z "$root" ]]; then
    echo "error: no installed Codex extension found under ~/.vscode/extensions/openai.chatgpt-*" >&2
    echo "       pass an explicit extension root if the extension is installed elsewhere" >&2
    exit 1
  fi
fi

package_json="$root/package.json"
host_js="$root/out/extension.js"
assets_dir="$root/webview/assets"

if [[ ! -f "$package_json" ]]; then
  echo "error: package.json not found under $root" >&2
  exit 1
fi

if [[ ! -f "$host_js" ]]; then
  echo "error: out/extension.js not found under $root" >&2
  exit 1
fi

version="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); console.log(p.version || "unknown")' "$package_json")"

echo "Extension root: $root"
echo "Version: $version"
echo "Host bundle: $host_js"
echo

echo "Host anchor candidates:"
if grep -n -o 'handleMcpNotification([^)]*){' "$host_js" | head -20 || true; then
  :
else
  echo "  no handleMcpNotification function-style anchor found"
fi

echo
echo "Host message case candidates:"
if grep -n -o 'case"open-in-browser".\{0,24\}' "$host_js" | head -20 || true; then
  :
else
  echo "  no case\"open-in-browser\" anchor found"
fi

echo
echo "Webview pending request candidates:"
if [[ ! -d "$assets_dir" ]]; then
  echo "  no webview assets directory found: $assets_dir"
  exit 0
fi

found=0
while IFS= read -r file; do
  if grep -q 'pendingRequest' "$file" && grep -q 'implementPlan' "$file"; then
    found=1
    echo
    echo "Bundle: $file"
    echo "  pendingRequest snippets:"
    grep -n -o '.\{0,90\}pendingRequest.\{0,160\}' "$file" | head -8 || true
    echo "  implementPlan snippets:"
    grep -n -o '.\{0,90\}implementPlan.\{0,160\}' "$file" | head -8 || true
    echo "  dispatchMessage snippets:"
    grep -n -o '.\{0,90\}dispatchMessage.\{0,160\}' "$file" | head -8 || true
    echo "  compact function anchors:"
    grep -n -o 'function [A-Za-z_$][A-Za-z0-9_$]*(e){.\{0,220\}pendingRequest:[A-Za-z_$][A-Za-z0-9_$]*.\{0,120\}switch' "$file" | head -8 || true
  fi
done < <(find "$assets_dir" -type f -name '*.js' | sort)

if [[ "$found" -eq 0 ]]; then
  echo "  no webview bundle containing both pendingRequest and implementPlan was found"
fi
