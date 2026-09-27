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

say "1/5  System packages (curl, Chromium browser)"
sudo apt-get update -y </dev/null
sudo apt-get install -y curl ca-certificates gnupg chromium </dev/null
CHROME="$(command -v chromium || true)"
[ -n "$CHROME" ] || fail "chromium did not install"

say "2/5  Node.js 22"
NODE_MAJOR=0
command -v node >/dev/null && NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - </dev/null
  sudo apt-get install -y nodejs </dev/null
fi
node --version

say "3/5  Claude Code"
curl -fsSL https://claude.ai/install.sh | bash </dev/null
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
TEST="$(mktemp --suffix=.cjs)"
cat > "$TEST" <<'JS'
// Starts the Playwright MCP server exactly as Claude will, asks it to open a page, checks the answer.
const { spawn } = require('child_process');
const [exe, ...extra] = process.argv.slice(2);
const p = spawn('npx', ['-y', '@playwright/mcp@latest', '--headless', '--isolated', '--executable-path', exe, ...extra],
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
EXTRA=""
if node "$TEST" "$CHROME" </dev/null; then
  echo "Browser works with the sandbox on."
elif node "$TEST" "$CHROME" --no-sandbox </dev/null; then
  EXTRA="--no-sandbox"; echo "Browser works (sandbox off - normal inside the Linux container)."
else
  rm -f "$TEST"; fail "Playwright could not open the browser (output above)"
fi
rm -f "$TEST"

claude mcp remove playwright -s user </dev/null >/dev/null 2>&1 || true
# shellcheck disable=SC2086
claude mcp add -s user playwright -- npx -y @playwright/mcp@latest --executable-path "$CHROME" $EXTRA </dev/null

trap - ERR
printf '\n\033[1;32mALL SET.\033[0m Close this Terminal window, open Terminal again, and type:  claude\n'
printf 'First time only: pick a color theme, then sign in to Claude in the browser tab it opens.\n\n'
