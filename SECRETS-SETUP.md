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
| `unlock-secrets` | Decrypt secrets.env.enc → secrets.env |
| `lock-secrets` | Encrypt secrets.env → secrets.env.enc (deletes plaintext) |
| `toggle-secrets` | Smart toggle - locks if unlocked, unlocks if locked |
| `show-secrets-help` | Show status and available commands |

## 🔐 Security Features

✅ **Plaintext never committed to git** - `.gitignore` excludes `secrets.env`
✅ **AES-256-CBC encryption** - Industry-standard encryption via OpenSSL
✅ **PBKDF2 key derivation** - Password stretching for brute-force resistance
✅ **Secure deletion** - Uses `shred` when available
✅ **Session-based** - Only decrypted when you're actively working

## 🎯 Use With Claude

When starting a session with me:
1. You: "Unlock my secrets" + provide your password
2. Me: I decrypt and confirm
3. You: Leave me to work - I'll read from `secrets.env` as needed
4. You: "Lock them back up" when done

This way you can leave me to work autonomously without repeated password prompts!

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
