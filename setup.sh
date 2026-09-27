#!/usr/bin/env bash
# Claude Code + Playwright browser control, full-access mode, for a Chromebook's
# Linux development environment (Crostini, Debian). Safe to re-run.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/rayrobertslopez-web/chromebook-claude-setup/main/setup.sh)"
set -euo pipefail

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mSETUP FAILED: %s\033[0m\n' "$*"; exit 1; }
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

[ "$(id -u)" -ne 0 ] || fail "run this as the normal Chromebook Linux user, not root"
export DEBIAN_FRONTEND=noninteractive
getent hosts deb.debian.org >/dev/null && getent hosts claude.ai >/dev/null || fail "Linux can't reach the internet yet. Check that Chrome on this Chromebook can open google.com, then restart the Chromebook (clock > power > Restart), turn off any VPN, and re-run this command."

say "1/5  System packages (curl, Chromium browser)"
sudo apt-get update -y </dev/null
sudo apt-get install -y curl ca-certificates gnupg chromium </dev/null
CHROME="$(command -v chromium || true)"
[ -n "$CHROME" ] || fail "chromium did not install"

say "2/5  Node.js 22"
NODE_MAJOR=0
command -v node >/dev/null && NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs </dev/null
fi
node --version

say "3/5  Claude Code"
curl -fsSL https://claude.ai/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
grep -qs 'HOME/.local/bin' "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
claude --version </dev/null

say "4/5  Full-access mode (no permission prompts)"
mkdir -p "$HOME/.claude"
node - "$HOME/.claude/settings.json" <<'JS'
const fs = require('fs'); const f = process.argv[2];
let s = {}; try { s = JSON.parse(fs.readFileSync(f, 'utf8')); } catch {}
s.permissions = Object.assign({}, s.permissions, { defaultMode: 'bypassPermissions' });
s.skipDangerousModePermissionPrompt = true;
fs.writeFileSync(f, JSON.stringify(s, null, 2) + '\n');
JS

say "5/5  Playwright (Claude drives a real browser) - testing it now"
PW="@playwright/mcp@$(npm view @playwright/mcp version </dev/null)"   # pin: what runs = what was tested
HEADLESS="--headless"   # test the real visible window whenever this Terminal has a display
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && HEADLESS=""
TEST="$(mktemp --suffix=.cjs)"
cat > "$TEST" <<'JS'
// Starts the Playwright MCP server exactly as Claude will, asks it to open a page, checks the answer.
const { spawn } = require('child_process');
const [pkg, exe, ...extra] = process.argv.slice(2);
const p = spawn('npx', ['-y', pkg, '--isolated', '--executable-path', exe, ...extra.filter(Boolean)],
  { stdio: ['pipe', 'pipe', 'ignore'] });
let buf = '', id = 0; const waiting = new Map();
p.stdout.on('data', d => {
  buf += d; let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    try { const m = JSON.parse(line); if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); } } catch {}
  }
});
const rpc = (method, params) => new Promise(r => { const n = ++id; waiting.set(n, r); p.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: n, method, params }) + '\n'); });
const done = (ok, msg) => { console.log(msg); try { p.kill(); } catch {} process.exit(ok ? 0 : 1); };
setTimeout(() => done(false, 'BROWSER_FAIL timeout'), 240000);
p.on('exit', c => done(false, 'BROWSER_FAIL server exited ' + c));
(async () => {
  await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'setup-test', version: '1' } });
  p.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const r = await rpc('tools/call', { name: 'browser_navigate', arguments: { url: 'https://example.com' } });
  const t = JSON.stringify(r);
  const ok = !r.error && !(r.result && r.result.isError) && /Example Domain/.test(t);
  if (ok) await rpc('tools/call', { name: 'browser_close', arguments: {} });
  done(ok, ok ? 'BROWSER_OK' : 'BROWSER_FAIL ' + t.slice(0, 800));
})();
JS
echo "Testing $PW (${HEADLESS:-visible window})..."
EXTRA=""
if node "$TEST" "$PW" "$CHROME" "$HEADLESS" </dev/null; then
  echo "Browser works with the sandbox on."
elif node "$TEST" "$PW" "$CHROME" "$HEADLESS" --no-sandbox </dev/null; then
  EXTRA="--no-sandbox"; echo "Browser works (sandbox off - normal inside the Linux container)."
else
  rm -f "$TEST"; fail "Playwright could not open the browser (output above)"
fi
rm -f "$TEST"

claude mcp remove playwright -s user </dev/null >/dev/null 2>&1 || true
# Pin the display so the browser window still shows if Claude starts before ChromeOS's display bridge is up.
# shellcheck disable=SC2086
claude mcp add -e DISPLAY="${DISPLAY:-:0}" -e WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" -s user \
  playwright -- npx -y "$PW" --executable-path "$CHROME" $EXTRA </dev/null

trap - ERR
printf '\n\033[1;32mALL SET.\033[0m Close this Terminal window, open Terminal again, and type:  claude\n'
printf 'First time only: pick a color theme, then sign in to Claude in the browser tab it opens.\n'
printf 'If the sign-in page shows a code instead, copy it and paste it into Terminal with Ctrl+Shift+V.\n\n'
