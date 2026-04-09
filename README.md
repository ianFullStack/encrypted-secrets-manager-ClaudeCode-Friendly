# 🔒 Encrypted Secrets Manager

A simple system to keep your secrets encrypted on disk and only decrypt them when needed.

## 🚀 Quick Start

### 1. Initial Setup (First Time Only)

```bash
# Copy the template and add your actual secrets
cp secrets.env.template secrets.env

# Edit secrets.env with your actual API keys, passwords, etc.
nano secrets.env  # or use your preferred editor

# Load the manager functions
source secrets-manager.sh

# Lock (encrypt) your secrets for the first time
lock-secrets
# You'll be prompted to create a password - remember it!
```

After this, `secrets.env` will be deleted and you'll have `secrets.env.enc` (encrypted).

### 2. Daily Workflow

**At the start of a work session:**
```bash
# Load the manager
source secrets-manager.sh

# Unlock your secrets
unlock-secrets
# Enter your password when prompted
```

Now `secrets.env` exists and I (Claude) can read it to access your API keys, passwords, etc.

**When you're done for the day:**
```bash
lock-secrets
```

This re-encrypts everything and deletes the plaintext file.

## 📋 Commands

| Command | Description |
|---------|-------------|
| `load-secrets-secure` | **(Recommended)** Popup password, decrypt to env vars in memory only — never writes plaintext to disk |
| `with-secrets <cmd>` | **(Recommended)** Popup password, decrypt, run command, auto-delete plaintext when command exits |
| `add-secret KEY VALUE` | Add or update a secret without exposing existing secrets — decrypts to memory, modifies, re-encrypts |
| `remove-secret KEY` | Remove a secret by name |
| `unlock-secrets` | Decrypt secrets.env.enc → secrets.env (manual flow, requires interactive terminal) |
| `lock-secrets` | Encrypt secrets.env → secrets.env.enc (deletes plaintext) |
| `toggle-secrets` | Smart toggle - locks if unlocked, unlocks if locked |
| `load-secrets` | Load from existing plaintext file into env vars |
| `show-secrets-help` | Show status and available commands |

## 🔐 Security Features

✅ **Plaintext never committed to git** - `.gitignore` excludes `secrets.env`
✅ **AES-256-CBC encryption** - Industry-standard encryption via OpenSSL
✅ **PBKDF2 key derivation** - Password stretching for brute-force resistance
✅ **Secure deletion** - Uses `shred` when available
✅ **Memory-only decryption** - `load-secrets-secure` keeps plaintext entirely off disk
✅ **PowerShell GUI password popup** - Password never appears in terminal output or AI context window
✅ **Auto-cleanup** - `with-secrets` deletes plaintext on command exit (even on Ctrl+C, via bash trap)
✅ **In-place secret editing** - `add-secret`/`remove-secret` modify the encrypted file without ever writing plaintext

## 🎯 Use With Claude Code

### Recommended (secure) workflow

**Load secrets into a Claude Code session without ever writing plaintext to disk:**
```bash
source ~/secrets-manager.sh && load-secrets-secure
```
A password popup appears. After entering it, all secrets are loaded into environment variables in memory. Claude can use `$VARIABLE_NAME` references but never sees the file or the values directly (unless explicitly asked to print them).

**Run a command (e.g., start a bot) with secrets, auto-cleaning on exit:**
```bash
source ~/secrets-manager.sh && with-secrets bun run start
```
This decrypts to disk briefly, runs your command, and shreds the plaintext when the command exits — even if you Ctrl+C.

**Add or update a secret without exposing existing ones:**
```bash
source ~/secrets-manager.sh && add-secret NEW_API_KEY abc123
```

### How the password popup works

Passwords are entered via a **PowerShell Windows Forms popup** with a masked password field. The password value goes from the GUI directly to OpenSSL via bash variable — it never appears in terminal output, command history, or any AI tool's context window. This is critical when working with Claude Code: even if Claude proxies the command, the password remains invisible.

### Why memory-only decryption matters

The original `unlock-secrets` flow writes a plaintext `secrets.env` file to disk. If you forget to `lock-secrets`, the file sits there exposed. `load-secrets-secure` eliminates this risk entirely — the decrypted content exists only in the bash process's memory and disappears when the shell exits.

For long-running processes that need a real env file (like `bun run --env-file secrets.env`), use `with-secrets` instead. It writes to disk only for the duration of the wrapped command and uses a bash trap to guarantee cleanup on exit, crash, or interrupt.

## 📝 Notes

- **Encrypted file** (`secrets.env.enc`) - Safe to commit to git, backup, sync
- **Decrypted file** (`secrets.env`) - Only exists during active sessions
- **Template** (`secrets.env.template`) - Reference for structure
- **Change password** - Just run `lock-secrets` again with a new password

## 🆘 Troubleshooting

**Forgot password?**
Unfortunately, there's no recovery. You'll need to recreate `secrets.env` manually.

**Wrong password error?**
Make sure you're typing the same password you used when locking.

**Want to change password?**
```bash
unlock-secrets  # with old password
lock-secrets    # with new password
```
