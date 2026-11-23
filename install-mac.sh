#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${1:?Usage: install-mac.sh /absolute/path/to/bridge.json}"
node_bin="$(command -v node)"
"$node_bin" -e 'if (typeof WebSocket !== "function") process.exit(1)'
"$node_bin" "$source_dir/bridge.mjs" "$config" --check-config
codex_bin="$("$node_bin" -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).codex)' "$config")"
test -x "$codex_bin"
"$codex_bin" queue --help >/dev/null

install_dir="$HOME/Library/Application Support/SlackWorkBridge"
launch_dir="$HOME/Library/LaunchAgents"
label="local.slack-work-bridge"
plist="$launch_dir/$label.plist"
domain="gui/$(id -u)"

if test -e "$plist" || launchctl print "$domain/$label" >/dev/null 2>&1; then
  echo "Bridge job already exists. Stop it before changing its installation." >&2
  exit 1
fi
umask 077
mkdir -p "$install_dir" "$launch_dir"
install -m 600 "$source_dir/bridge.mjs" "$install_dir/bridge.mjs"
install -m 600 "$config" "$install_dir/bridge.json"
"$node_bin" --input-type=module - "$node_bin" "$install_dir" "$plist" "$label" <<'NODE'
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
const [node, dir, plist, label] = process.argv.slice(2);
const xml = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const arg = value => '<string>' + xml(value) + '</string>';
const text = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key>${arg(label)}
<key>ProgramArguments</key><array>${[node, join(dir, 'bridge.mjs'), join(dir, 'bridge.json')].map(arg).join('')}</array>
<key>WorkingDirectory</key>${arg(dir)}
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>15</integer>
<key>StandardOutPath</key>${arg(join(dir, 'service.log'))}
<key>StandardErrorPath</key>${arg(join(dir, 'service-errors.log'))}
</dict></plist>`;
writeFileSync(plist, text, { mode: 0o600, flag: 'wx' });
NODE
/usr/bin/plutil -lint "$plist"
if ! launchctl bootstrap "$domain" "$plist"; then
  rm "$plist"
  echo "Could not start the login job. Run the installer in your Mac login session." >&2
  exit 1
fi
echo "Started $label. Check $install_dir/status.json for connected."
