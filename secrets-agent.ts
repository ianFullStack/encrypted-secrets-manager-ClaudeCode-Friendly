#!/usr/bin/env bun
/**
 * Secrets Agent — like ssh-agent for your encrypted secrets.
 *
 * Holds decrypted secrets in memory after one master-password entry, so
 * subsequent commands across multiple shell invocations don't have to
 * re-prompt. Enforces category-based scoping: accessing keys in a new
 * category triggers a fresh password popup (defense against scope creep).
 *
 * Architecture:
 *   - TCP localhost on a random port (cross-platform, no IPC differences)
 *   - Token-based auth (random 256-bit token written to info file with 600 perms)
 *   - Decrypted secrets live in process memory only — never on disk, never logged
 *   - Idle timeout (default 30 min) → process exits, secrets lost, password
 *     required again
 *
 * Commands:
 *   bun secrets-agent.ts start     — pop up master password, start daemon
 *   bun secrets-agent.ts status    — show running state, idle time, unlocked cats
 *   bun secrets-agent.ts stop      — shut down running agent
 *   bun secrets-agent.ts get KEY   — print export line for KEY (for shell eval)
 *   bun secrets-agent.ts dump      — print export lines for all unlocked keys
 *
 * Security properties:
 *   ✓ No plaintext on disk (memory-only)
 *   ✓ No network — TCP localhost bound to 127.0.0.1
 *   ✓ Token-based auth — even local processes can't query without token file
 *   ✓ No telemetry, no logging of values
 *   ✓ Idle timeout limits exposure window
 *
 * Caveats (same as any user-space credential store):
 *   ⚠ Process memory readable via debugger / same-user malware
 *   ⚠ Memory pages can be paged to swap — use BitLocker/FileVault to mitigate
 */

import { spawn, spawnSync } from 'child_process';
import { existsSync, readFileSync, writeFileSync, unlinkSync, chmodSync, mkdirSync } from 'fs';
import { homedir, platform } from 'os';
import { join } from 'path';
import { randomBytes, createHash } from 'crypto';

// ─── Paths ──────────────────────────────────────────────────────────────

const AGENT_DIR = join(homedir(), '.secrets-agent');
const INFO_FILE = join(AGENT_DIR, 'info.json');         // port + token, perms 600
const PID_FILE  = join(AGENT_DIR, 'pid');               // running daemon's PID
const CATEGORIES_FILE = join(homedir(), 'secrets-categories.json');

// Encrypted file location — looks in CWD first (project-specific), then home
function findEncryptedFile(): string {
  const candidates = [
    join(process.cwd(), 'secrets.env.enc'),
    join(homedir(), 'secrets.env.enc'),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  console.error('Error: secrets.env.enc not found in CWD or home directory');
  process.exit(1);
}

// ─── Categories ─────────────────────────────────────────────────────────

interface CategoriesConfig {
  categories: Record<string, string[]>;  // name → glob patterns
  default_category: string;
  bulk_categories?: string[];             // categories that can be loaded together (e.g., for bots)
}

const DEFAULT_CATEGORIES: CategoriesConfig = {
  categories: {
    'Wallets':     ['WALLET_*', '*PRIVATE_KEY*', '*_SECRET_KEY'],
    'Trading':     ['HELIUS_*', 'BIRDEYE_*', 'GROK_*', 'ALCHEMY_*', 'JUPITER_*', 'JITO_*', 'DEXSCREENER_*'],
    'Telegram':    ['TELEGRAM_*'],
    'StockAPIs':   ['FINNHUB_*', 'YAHOO_*', 'EDGAR_*', 'POLYGON_*', 'ALPACA_*'],
    'Email':       ['GMAIL_*', 'SMTP_*', 'EMAIL_*', 'MAILGUN_*'],
    'Payments':    ['STRIPE_*', 'PAYPAL_*'],
    'Wix':         ['WIX_*', 'Wix_*'],
    'BotConfig':   ['MAX_*', 'MIN_*', 'DRY_*', 'TICK_*'],
  },
  default_category: 'Other',
  bulk_categories: ['Wallets', 'Trading', 'Telegram', 'StockAPIs', 'BotConfig'],
};

function loadCategories(): CategoriesConfig {
  if (existsSync(CATEGORIES_FILE)) {
    try {
      return JSON.parse(readFileSync(CATEGORIES_FILE, 'utf-8'));
    } catch (e) {
      console.error(`Warning: failed to parse ${CATEGORIES_FILE}, using defaults`);
    }
  }
  return DEFAULT_CATEGORIES;
}

function categorize(key: string, config: CategoriesConfig): string {
  for (const [cat, patterns] of Object.entries(config.categories)) {
    for (const pat of patterns) {
      const regex = new RegExp('^' + pat.replace(/\*/g, '.*') + '$', 'i');
      if (regex.test(key)) return cat;
    }
  }
  return config.default_category;
}

// ─── Password popup (cross-platform) ────────────────────────────────────

function getPasswordViaPopup(prompt: string = 'Enter secrets password:'): string {
  const os = platform();
  let pw = '';
  try {
    if (os === 'win32') {
      const ps = `
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.Form
$f.Text = 'Secrets Agent'
$f.Size = New-Object System.Drawing.Size(380,150)
$f.StartPosition = 'CenterScreen'
$f.TopMost = $true
$f.FormBorderStyle = 'FixedDialog'
$l = New-Object System.Windows.Forms.Label
$l.Text = '${prompt.replace(/'/g, "''")}'
$l.Location = New-Object System.Drawing.Point(15,15)
$l.Size = New-Object System.Drawing.Size(340,18)
$f.Controls.Add($l)
$b = New-Object System.Windows.Forms.TextBox
$b.UseSystemPasswordChar = $true
$b.Location = New-Object System.Drawing.Point(15,38)
$b.Size = New-Object System.Drawing.Size(340,22)
$f.Controls.Add($b)
$ok = New-Object System.Windows.Forms.Button
$ok.Text = 'OK'
$ok.Location = New-Object System.Drawing.Point(280,72)
$ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
$f.AcceptButton = $ok
$f.Controls.Add($ok)
$f.Add_Shown({ $b.Focus() })
if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output $b.Text }
$f.Dispose()
`;
      const r = spawnSync('powershell', ['-NoProfile', '-Command', ps], { encoding: 'utf-8' });
      pw = (r.stdout || '').replace(/\r?\n$/, '');
    } else if (os === 'darwin') {
      const r = spawnSync('osascript', ['-e',
        `tell application "System Events"
          activate
          set p to text returned of (display dialog "${prompt}" default answer "" with title "Secrets Agent" with hidden answer)
        end tell`
      ], { encoding: 'utf-8' });
      pw = (r.stdout || '').replace(/\r?\n$/, '');
    } else {
      // Linux: try zenity, then kdialog
      let r = spawnSync('zenity', ['--password', '--title=Secrets Agent'], { encoding: 'utf-8' });
      if (r.status === 0) {
        pw = (r.stdout || '').replace(/\r?\n$/, '');
      } else {
        r = spawnSync('kdialog', ['--title', 'Secrets Agent', '--password', prompt], { encoding: 'utf-8' });
        pw = (r.stdout || '').replace(/\r?\n$/, '');
      }
    }
  } catch (e) {
    console.error('Password popup failed:', e);
  }
  return pw;
}

// ─── Decryption ─────────────────────────────────────────────────────────

function decryptSecrets(encryptedFile: string, password: string): Map<string, string> | null {
  const r = spawnSync('openssl', [
    'enc', '-aes-256-cbc', '-d', '-pbkdf2',
    '-in', encryptedFile,
    '-pass', `pass:${password}`,
  ], { encoding: 'utf-8' });

  if (r.status !== 0) return null;

  const map = new Map<string, string>();
  for (const line of (r.stdout || '').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq < 1) continue;
    const k = trimmed.slice(0, eq).trim();
    let v = trimmed.slice(eq + 1);
    // Strip surrounding quotes
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    map.set(k, v);
  }
  return map;
}

// ─── Daemon state ───────────────────────────────────────────────────────

interface AgentState {
  secrets: Map<string, string>;
  masterPassword: string;
  unlockedCategories: Set<string>;
  config: CategoriesConfig;
  encryptedFile: string;
  lastAccess: number;
  authToken: string;
}

const IDLE_TTL_MS = parseInt(process.env.SECRETS_AGENT_TTL_MS || '1800000');  // 30 min default

// ─── Server ─────────────────────────────────────────────────────────────

function startDaemon(state: AgentState, port: number): void {
  // Write info file BEFORE starting server so client can find us
  if (!existsSync(AGENT_DIR)) mkdirSync(AGENT_DIR, { recursive: true });
  writeFileSync(INFO_FILE, JSON.stringify({ port, token: state.authToken }), { mode: 0o600 });
  try { chmodSync(INFO_FILE, 0o600); } catch {}
  writeFileSync(PID_FILE, String(process.pid), { mode: 0o600 });

  const server = Bun.serve({
    port,
    hostname: '127.0.0.1',
    async fetch(req) {
      let body: any = {};
      try { body = await req.json(); } catch {}

      // Token check on every request
      if (body.token !== state.authToken) {
        return new Response(JSON.stringify({ error: 'invalid token' }), { status: 401 });
      }

      state.lastAccess = Date.now();
      const url = new URL(req.url);

      switch (url.pathname) {
        case '/status':
          return Response.json({
            running: true,
            pid: process.pid,
            idleMs: Date.now() - state.lastAccess,
            ttlMs: IDLE_TTL_MS,
            unlockedCategories: Array.from(state.unlockedCategories),
            keyCount: state.secrets.size,
          });

        case '/get': {
          const key: string = body.key;
          if (!key || !state.secrets.has(key)) {
            return Response.json({ error: 'key not found' }, { status: 404 });
          }
          const cat = categorize(key, state.config);
          if (!state.unlockedCategories.has(cat)) {
            // Trigger fresh password popup for this category
            const pw = getPasswordViaPopup(`New category "${cat}" — enter password to authorize:`);
            if (pw !== state.masterPassword) {
              return Response.json({ error: `category "${cat}" not authorized` }, { status: 403 });
            }
            state.unlockedCategories.add(cat);
          }
          return Response.json({ key, value: state.secrets.get(key), category: cat });
        }

        case '/unlock-category': {
          const cat: string = body.category;
          if (state.unlockedCategories.has(cat)) {
            return Response.json({ ok: true, alreadyUnlocked: true });
          }
          const pw = getPasswordViaPopup(`Unlock category "${cat}" — enter password:`);
          if (pw !== state.masterPassword) {
            return Response.json({ error: 'wrong password' }, { status: 403 });
          }
          state.unlockedCategories.add(cat);
          return Response.json({ ok: true });
        }

        case '/dump': {
          // Returns export lines for all currently-unlocked keys
          const lines: string[] = [];
          for (const [k, v] of state.secrets) {
            const cat = categorize(k, state.config);
            if (state.unlockedCategories.has(cat)) {
              // Shell-escape the value
              const esc = v.replace(/'/g, `'"'"'`);
              lines.push(`export ${k}='${esc}'`);
            }
          }
          return new Response(lines.join('\n') + '\n', { headers: { 'Content-Type': 'text/plain' } });
        }

        case '/dump-all': {
          // Bulk mode: requires unlocking all bulk_categories first
          for (const cat of state.config.bulk_categories || Object.keys(state.config.categories)) {
            if (!state.unlockedCategories.has(cat)) {
              const pw = getPasswordViaPopup(`Bulk-load all secrets — enter password:`);
              if (pw !== state.masterPassword) {
                return Response.json({ error: 'wrong password' }, { status: 403 });
              }
              // Unlock all categories at once
              for (const c of Object.keys(state.config.categories)) state.unlockedCategories.add(c);
              state.unlockedCategories.add(state.config.default_category);
              break;
            }
          }
          const lines: string[] = [];
          for (const [k, v] of state.secrets) {
            const esc = v.replace(/'/g, `'"'"'`);
            lines.push(`export ${k}='${esc}'`);
          }
          return new Response(lines.join('\n') + '\n', { headers: { 'Content-Type': 'text/plain' } });
        }

        case '/stop':
          setTimeout(() => process.exit(0), 100);
          return Response.json({ ok: true, stopping: true });

        default:
          return new Response('not found', { status: 404 });
      }
    },
  });

  console.log(`Secrets Agent started — PID ${process.pid}, listening on 127.0.0.1:${port}`);
  console.log(`Idle timeout: ${IDLE_TTL_MS / 60000} min`);

  // Idle expiry
  setInterval(() => {
    if (Date.now() - state.lastAccess > IDLE_TTL_MS) {
      console.log('Idle timeout reached — exiting');
      cleanup();
      process.exit(0);
    }
  }, 60 * 1000);

  // Cleanup on signals
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig as any, () => { cleanup(); process.exit(0); });
  }
}

function cleanup() {
  try { unlinkSync(INFO_FILE); } catch {}
  try { unlinkSync(PID_FILE); } catch {}
}

// ─── Client helpers ─────────────────────────────────────────────────────

async function callAgent(path: string, body: object = {}): Promise<any> {
  if (!existsSync(INFO_FILE)) {
    return { error: 'agent not running' };
  }
  const info = JSON.parse(readFileSync(INFO_FILE, 'utf-8'));
  try {
    const res = await fetch(`http://127.0.0.1:${info.port}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...body, token: info.token }),
    });
    // Read text once, then try to parse as JSON. Avoids the
    // "body already consumed" bug if .json() fails and we'd retry .text().
    const text = await res.text();
    try { return JSON.parse(text); } catch { return text; }
  } catch (e: any) {
    return { error: `agent unreachable: ${e.message}` };
  }
}

async function isAgentRunning(): Promise<boolean> {
  if (!existsSync(INFO_FILE)) return false;
  const r = await callAgent('/status');
  return r && r.running === true;
}

// ─── CLI ────────────────────────────────────────────────────────────────

async function main() {
  const cmd = process.argv[2];

  if (cmd === 'start') {
    if (await isAgentRunning()) {
      console.log('Agent already running.');
      return;
    }
    const encryptedFile = findEncryptedFile();
    const config = loadCategories();
    const password = getPasswordViaPopup();
    if (!password) { console.error('No password provided.'); process.exit(1); }
    const secrets = decryptSecrets(encryptedFile, password);
    if (!secrets) { console.error('Failed to decrypt — wrong password?'); process.exit(1); }
    if (secrets.size === 0) { console.error('Decryption succeeded but no secrets found.'); process.exit(1); }

    const port = 30000 + Math.floor(Math.random() * 30000);
    const state: AgentState = {
      secrets, masterPassword: password,
      unlockedCategories: new Set(),
      config, encryptedFile,
      lastAccess: Date.now(),
      authToken: randomBytes(32).toString('hex'),
    };
    startDaemon(state, port);
    return;
  }

  if (cmd === 'status') {
    const r = await callAgent('/status');
    if (r.error) { console.log('Agent not running.'); process.exit(1); }
    console.log(`Running — PID ${r.pid}`);
    console.log(`Idle: ${Math.round(r.idleMs / 1000)}s / TTL ${Math.round(r.ttlMs / 1000)}s`);
    console.log(`Keys loaded: ${r.keyCount}`);
    console.log(`Unlocked categories: ${r.unlockedCategories.length ? r.unlockedCategories.join(', ') : '(none yet)'}`);
    return;
  }

  if (cmd === 'stop') {
    const r = await callAgent('/stop');
    if (r.error) { console.log('Agent was not running.'); return; }
    console.log('Agent stopped.');
    return;
  }

  // Internal commands (used by the bash wrapper, not for direct human/AI use).
  // These output secret values to stdout — meant to be captured by `eval $(...)`.
  // Running them directly will print values to your terminal/AI context. The
  // INTERNAL_OK env var must be set (the bash wrapper sets it) or you must
  // pass --i-understand-this-leaks to confirm you know what you're doing.
  if (cmd === 'get' || cmd === 'dump' || cmd === 'dump-all') {
    const guarded = process.env.SECRETS_AGENT_INTERNAL === '1' ||
                    process.argv.includes('--i-understand-this-leaks');
    if (!guarded) {
      console.error(`Refusing to run "${cmd}" directly — output contains secret values.`);
      console.error(`Use the bash wrapper instead:`);
      console.error(`  source ~/secrets-manager.sh && load-secrets-from-agent`);
      console.error(`(Or pass --i-understand-this-leaks if you really know what you're doing.)`);
      process.exit(2);
    }

    if (cmd === 'get') {
      const key = process.argv[3];
      if (!key) { console.error('Usage: secrets-agent get KEY'); process.exit(1); }
      const r = await callAgent('/get', { key });
      if (r.error) { console.error('Error:', r.error); process.exit(1); }
      const esc = r.value.replace(/'/g, `'"'"'`);
      console.log(`export ${r.key}='${esc}'`);
      return;
    }

    const r = await callAgent(cmd === 'dump-all' ? '/dump-all' : '/dump');
    if (typeof r === 'object' && r.error) { console.error('Error:', r.error); process.exit(1); }
    process.stdout.write(typeof r === 'string' ? r : '');
    return;
  }

  console.log(`Usage: bun secrets-agent.ts <command>

Public commands:
  start             Start the agent (master password popup)
  status            Show running state, idle time, unlocked categories
  stop              Stop the running agent (forces re-auth on next use)

To load secrets into your shell, use the bash wrapper (NEVER call get/dump
directly — they output secret values to stdout and would leak into terminal
output or AI assistant context):

  source ~/secrets-manager.sh && load-secrets-from-agent           # category-scoped
  source ~/secrets-manager.sh && load-secrets-from-agent --bulk    # one popup → load all

Environment:
  SECRETS_AGENT_TTL_MS   Idle timeout in ms (default 1800000 = 30 min)`);
}

main().catch(e => { console.error(e); process.exit(1); });
