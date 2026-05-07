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
    const root = path.join(dir, entry, "extension");
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
    echo "error: no installed Codex extension found under ~/.vscode/extensions/openai.chatgpt-*/extension" >&2
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

publisher="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); console.log(p.publisher || "openai")' "$package_json")"
name="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); console.log(p.name || "chatgpt")' "$package_json")"
version="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); console.log(p.version || "unknown")' "$package_json")"

if [[ "$version" == "unknown" ]]; then
  echo "error: package.json has no version" >&2
  exit 1
fi

fixture_root="Tests/Fixtures/vsix/${publisher}.${name}-${version}-local/extension"
mkdir -p "$fixture_root/out" "$fixture_root/webview/assets"
cp "$package_json" "$fixture_root/package.json"
cp "$host_js" "$fixture_root/out/extension.js"

webview_count=0
if [[ -d "$assets_dir" ]]; then
  while IFS= read -r file; do
    if grep -q 'pendingRequest' "$file" && grep -q 'implementPlan' "$file"; then
      cp "$file" "$fixture_root/webview/assets/$(basename "$file")"
      webview_count=$((webview_count + 1))
    fi
  done < <(find "$assets_dir" -type f -name '*.js' | sort)
fi

echo "Prepared fixture: $fixture_root"
echo "Version: $version"
echo "Copied webview bundles: $webview_count"

if [[ "$webview_count" -eq 0 ]]; then
  echo "warning: no webview bundle containing both pendingRequest and implementPlan was copied" >&2
fi
