#!/bin/bash
# Secrets Manager - Encrypt/Decrypt your .env file for secure storage
# Usage: source secrets-manager.sh, then use 'unlock-secrets' or 'lock-secrets'

SECRETS_FILE="secrets.env"
ENCRYPTED_FILE="secrets.env.enc"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

unlock-secrets() {
    if [ -f "$SECRETS_FILE" ]; then
        echo -e "${YELLOW}⚠️  Warning: $SECRETS_FILE already exists and is unlocked!${NC}"
        read -p "Do you want to re-decrypt? This will overwrite the current file. (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            return 1
        fi
    fi

    if [ ! -f "$ENCRYPTED_FILE" ]; then
        echo -e "${RED}❌ Error: $ENCRYPTED_FILE not found!${NC}"
        echo "Run 'lock-secrets' first to create an encrypted file, or create $ENCRYPTED_FILE manually."
        return 1
    fi

    echo "🔓 Unlocking secrets..."
    echo "Enter decryption password:"

    if openssl enc -aes-256-cbc -d -pbkdf2 -in "$ENCRYPTED_FILE" -out "$SECRETS_FILE" 2>/dev/null; then
        echo -e "${GREEN}✅ Secrets unlocked! File: $SECRETS_FILE${NC}"
        echo -e "${YELLOW}⚠️  Remember to run 'lock-secrets' when you're done!${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to decrypt. Wrong password or corrupted file.${NC}"
        rm -f "$SECRETS_FILE" 2>/dev/null  # Clean up partial file
        return 1
    fi
}

lock-secrets() {
    if [ ! -f "$SECRETS_FILE" ]; then
        echo -e "${RED}❌ Error: $SECRETS_FILE not found!${NC}"
        echo "Nothing to lock. The secrets are already locked or don't exist."
        return 1
    fi

    echo "🔒 Locking secrets..."

    if [ -f "$ENCRYPTED_FILE" ]; then
        echo -e "${YELLOW}⚠️  $ENCRYPTED_FILE already exists.${NC}"
        read -p "Overwrite with new encryption? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted. Your secrets remain unlocked."
            return 1
        fi
    fi

    echo "Enter encryption password:"

    if openssl enc -aes-256-cbc -salt -pbkdf2 -in "$SECRETS_FILE" -out "$ENCRYPTED_FILE" 2>/dev/null; then
        # Securely delete the plaintext file
        shred -u "$SECRETS_FILE" 2>/dev/null || rm -f "$SECRETS_FILE"
        echo -e "${GREEN}✅ Secrets locked and encrypted! File: $ENCRYPTED_FILE${NC}"
        echo -e "${GREEN}🗑️  Plaintext $SECRETS_FILE has been deleted.${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to encrypt.${NC}"
        return 1
    fi
}

toggle-secrets() {
    if [ -f "$SECRETS_FILE" ]; then
        lock-secrets
    else
        unlock-secrets
    fi
}

# Load secrets into environment variables (more secure - values never appear in chat)
load-secrets() {
    if [ ! -f "$SECRETS_FILE" ]; then
        echo -e "${RED}❌ Error: $SECRETS_FILE not found!${NC}"
        echo "Run 'unlock-secrets' first to decrypt your secrets."
        return 1
    fi

    echo "📥 Loading secrets into environment variables..."

    # Export all non-comment, non-empty lines as environment variables
    set -a  # automatically export all variables
    source "$SECRETS_FILE"
    set +a

    # Count how many variables were loaded
    local count=$(grep -c "^[^#].*=.*" "$SECRETS_FILE" 2>/dev/null || echo "0")

    echo -e "${GREEN}✅ Loaded $count secrets into environment${NC}"
    echo -e "${GREEN}💡 Now Claude can use \$VARIABLE_NAME without seeing the actual values${NC}"
    return 0
}

# Get password via GUI popup, cross-platform (never visible in terminal/context)
# Detection order: Windows (PowerShell) > macOS (osascript) > Linux (zenity/kdialog) > terminal fallback (read -s)
_get-secrets-password() {
    local pw
    local os
    os="$(uname -s 2>/dev/null || echo unknown)"

    case "$os" in
        # Windows variants under Git Bash, MSYS, Cygwin
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
            pw=$(powershell -NoProfile -Command '
                Add-Type -AssemblyName System.Windows.Forms
                $form = New-Object System.Windows.Forms.Form
                $form.Text = "Secrets Password"
                $form.Size = New-Object System.Drawing.Size(350,150)
                $form.StartPosition = "CenterScreen"
                $form.TopMost = $true
                $label = New-Object System.Windows.Forms.Label
                $label.Text = "Enter secrets password:"
                $label.Location = New-Object System.Drawing.Point(10,15)
                $label.Size = New-Object System.Drawing.Size(310,20)
                $form.Controls.Add($label)
                $box = New-Object System.Windows.Forms.TextBox
                $box.UseSystemPasswordChar = $true
                $box.Location = New-Object System.Drawing.Point(10,40)
                $box.Size = New-Object System.Drawing.Size(310,20)
                $form.Controls.Add($box)
                $btn = New-Object System.Windows.Forms.Button
                $btn.Text = "OK"
                $btn.Location = New-Object System.Drawing.Point(130,70)
                $btn.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $form.AcceptButton = $btn
                $form.Controls.Add($btn)
                $result = $form.ShowDialog()
                if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
                    Write-Output $box.Text
                }
                $form.Dispose()
            ' 2>/dev/null)
            ;;

        # macOS — use AppleScript via osascript
        Darwin)
            pw=$(osascript -e 'tell application "System Events"
                activate
                set thePassword to text returned of (display dialog "Enter secrets password:" default answer "" with title "Secrets Password" with hidden answer)
            end tell' 2>/dev/null)
            ;;

        # Linux — try zenity, then kdialog, then fall back to terminal read
        Linux)
            if command -v zenity >/dev/null 2>&1; then
                pw=$(zenity --password --title="Secrets Password" 2>/dev/null)
            elif command -v kdialog >/dev/null 2>&1; then
                pw=$(kdialog --title "Secrets Password" --password "Enter secrets password:" 2>/dev/null)
            else
                # Headless or no GUI dialog available — read from terminal silently
                # Note: requires an interactive TTY
                if [ -t 0 ]; then
                    echo -n "Enter secrets password: " >&2
                    read -rs pw
                    echo "" >&2
                else
                    echo "Error: No GUI dialog available (install zenity or kdialog) and no interactive terminal." >&2
                    return 1
                fi
            fi
            ;;

        *)
            # Unknown OS — try terminal read as last resort
            if [ -t 0 ]; then
                echo -n "Enter secrets password: " >&2
                read -rs pw
                echo "" >&2
            else
                echo "Error: Unsupported OS '$os' and no interactive terminal." >&2
                return 1
            fi
            ;;
    esac

    echo "$pw"
}

# Load secrets into env vars WITHOUT writing plaintext to disk
load-secrets-secure() {
    if [ ! -f "$ENCRYPTED_FILE" ]; then
        echo -e "${RED}Error: $ENCRYPTED_FILE not found!${NC}"
        return 1
    fi

    echo "Requesting password..."
    local password
    password=$(_get-secrets-password)

    if [ -z "$password" ]; then
        echo -e "${RED}No password provided.${NC}"
        return 1
    fi

    echo "Decrypting to memory..."
    local decrypted
    decrypted=$(openssl enc -aes-256-cbc -d -pbkdf2 -in "$ENCRYPTED_FILE" -pass "pass:$password" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to decrypt. Wrong password?${NC}"
        return 1
    fi

    # Parse and export env vars from decrypted content (never touches disk)
    local count=0
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        # Split on first = only
        local key="${line%%=*}"
        local value="${line#*=}"
        # Remove surrounding quotes if present
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        export "$key=$value"
        count=$((count + 1))
    done <<< "$decrypted"

    echo -e "${GREEN}Loaded $count secrets into environment (never written to disk)${NC}"
    return 0
}

# NOTE: `with-secrets` was removed in 2026-04-16. It decrypted to disk for the
# duration of a wrapped command. The recommended pattern now is:
#
#   load-secrets-secure       # decrypt to env vars in memory only (no disk)
#   exec <your command>       # inherits env vars from the parent shell
#
# This keeps plaintext entirely off disk. See start-secure.sh in your project
# for an example. If you need the old behavior for a one-off command, use:
#   unlock-secrets && <command> && lock-secrets

# Add or update a secret without exposing existing secrets in context
# Usage: add-secret KEY VALUE
# Decrypts to memory, adds/updates the line, re-encrypts. Plaintext never stays on disk.
add-secret() {
    if [ $# -ne 2 ]; then
        echo -e "${RED}Usage: add-secret KEY VALUE${NC}"
        echo "Example: add-secret MY_API_KEY abc123"
        return 1
    fi

    local key="$1"
    local value="$2"

    if [ ! -f "$ENCRYPTED_FILE" ]; then
        # No encrypted file yet — create one with just this secret
        echo "$key=$value" | openssl enc -aes-256-cbc -salt -pbkdf2 -out "$ENCRYPTED_FILE" -pass "pass:$(_get-secrets-password)" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Created $ENCRYPTED_FILE with $key${NC}"
        else
            echo -e "${RED}Failed to encrypt.${NC}"
            return 1
        fi
        return 0
    fi

    echo "Requesting password..."
    local password
    password=$(_get-secrets-password)

    if [ -z "$password" ]; then
        echo -e "${RED}No password provided.${NC}"
        return 1
    fi

    # Decrypt to memory
    local decrypted
    decrypted=$(openssl enc -aes-256-cbc -d -pbkdf2 -in "$ENCRYPTED_FILE" -pass "pass:$password" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to decrypt. Wrong password?${NC}"
        return 1
    fi

    # Remove existing line for this key (if any)
    local updated
    updated=$(echo "$decrypted" | grep -v "^${key}=")

    # Add a "Custom" section header on first add (gives blank line separation
    # from previous categories and keeps additions visually grouped)
    local custom_hdr="# Custom secrets (added via add-secret/add-secret-gui)"
    if ! echo "$updated" | grep -qF "$custom_hdr"; then
        updated="${updated}"$'\n\n'"${custom_hdr}"
    fi

    # Append the new key on its own line
    updated="${updated}"$'\n'"${key}=${value}"

    # Re-encrypt (pipe, never written as plaintext file)
    echo "$updated" | openssl enc -aes-256-cbc -salt -pbkdf2 -out "$ENCRYPTED_FILE" -pass "pass:$password" 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Secret '$key' added/updated and re-encrypted.${NC}"
    else
        echo -e "${RED}Failed to re-encrypt.${NC}"
        return 1
    fi
}

# GUI popup for entering a new secret: name + value + confirm value
# Returns "KEY=VALUE" on stdout if user confirms with matching values, empty on cancel/mismatch
_get-new-secret-input() {
    local result
    local os
    os="$(uname -s 2>/dev/null || echo unknown)"

    case "$os" in
        # Windows variants under Git Bash, MSYS, Cygwin
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
            result=$(powershell -NoProfile -Command '
                Add-Type -AssemblyName System.Windows.Forms
                Add-Type -AssemblyName System.Drawing

                while ($true) {
                    $form = New-Object System.Windows.Forms.Form
                    $form.Text = "Add New Secret"
                    $form.Size = New-Object System.Drawing.Size(380,260)
                    $form.StartPosition = "CenterScreen"
                    $form.TopMost = $true
                    $form.FormBorderStyle = "FixedDialog"
                    $form.MaximizeBox = $false
                    $form.MinimizeBox = $false

                    $lblName = New-Object System.Windows.Forms.Label
                    $lblName.Text = "Secret Name (e.g. MY_API_KEY):"
                    $lblName.Location = New-Object System.Drawing.Point(15,15)
                    $lblName.Size = New-Object System.Drawing.Size(340,18)
                    $form.Controls.Add($lblName)

                    $boxName = New-Object System.Windows.Forms.TextBox
                    $boxName.Location = New-Object System.Drawing.Point(15,35)
                    $boxName.Size = New-Object System.Drawing.Size(340,22)
                    $boxName.CharacterCasing = "Upper"
                    $form.Controls.Add($boxName)

                    $lblVal = New-Object System.Windows.Forms.Label
                    $lblVal.Text = "Secret Value:"
                    $lblVal.Location = New-Object System.Drawing.Point(15,68)
                    $lblVal.Size = New-Object System.Drawing.Size(340,18)
                    $form.Controls.Add($lblVal)

                    $boxVal = New-Object System.Windows.Forms.TextBox
                    $boxVal.UseSystemPasswordChar = $true
                    $boxVal.Location = New-Object System.Drawing.Point(15,88)
                    $boxVal.Size = New-Object System.Drawing.Size(340,22)
                    $form.Controls.Add($boxVal)

                    $lblConf = New-Object System.Windows.Forms.Label
                    $lblConf.Text = "Confirm Value:"
                    $lblConf.Location = New-Object System.Drawing.Point(15,121)
                    $lblConf.Size = New-Object System.Drawing.Size(340,18)
                    $form.Controls.Add($lblConf)

                    $boxConf = New-Object System.Windows.Forms.TextBox
                    $boxConf.UseSystemPasswordChar = $true
                    $boxConf.Location = New-Object System.Drawing.Point(15,141)
                    $boxConf.Size = New-Object System.Drawing.Size(340,22)
                    $form.Controls.Add($boxConf)

                    $btnOk = New-Object System.Windows.Forms.Button
                    $btnOk.Text = "Save"
                    $btnOk.Location = New-Object System.Drawing.Point(180,180)
                    $btnOk.Size = New-Object System.Drawing.Size(80,28)
                    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
                    $form.AcceptButton = $btnOk
                    $form.Controls.Add($btnOk)

                    $btnCancel = New-Object System.Windows.Forms.Button
                    $btnCancel.Text = "Cancel"
                    $btnCancel.Location = New-Object System.Drawing.Point(275,180)
                    $btnCancel.Size = New-Object System.Drawing.Size(80,28)
                    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
                    $form.CancelButton = $btnCancel
                    $form.Controls.Add($btnCancel)

                    $form.Add_Shown({ $boxName.Focus() })
                    $r = $form.ShowDialog()

                    if ($r -ne [System.Windows.Forms.DialogResult]::OK) {
                        $form.Dispose()
                        return
                    }

                    $name = $boxName.Text.Trim()
                    $v1 = $boxVal.Text
                    $v2 = $boxConf.Text
                    $form.Dispose()

                    if ([string]::IsNullOrEmpty($name)) {
                        [System.Windows.Forms.MessageBox]::Show("Secret name cannot be empty.", "Error", "OK", "Error") | Out-Null
                        continue
                    }
                    if ($name -notmatch "^[A-Za-z_][A-Za-z0-9_]*$") {
                        [System.Windows.Forms.MessageBox]::Show("Secret name must start with a letter or underscore and contain only letters, numbers, and underscores.", "Error", "OK", "Error") | Out-Null
                        continue
                    }
                    if ($v1 -ne $v2) {
                        [System.Windows.Forms.MessageBox]::Show("Values do not match. Please try again.", "Error", "OK", "Error") | Out-Null
                        continue
                    }
                    if ([string]::IsNullOrEmpty($v1)) {
                        [System.Windows.Forms.MessageBox]::Show("Secret value cannot be empty.", "Error", "OK", "Error") | Out-Null
                        continue
                    }

                    Write-Output "$name=$v1"
                    return
                }
            ' 2>/dev/null)
            ;;

        # macOS — use AppleScript via osascript
        Darwin)
            local name v1 v2
            name=$(osascript -e 'tell application "System Events"
                activate
                set theName to text returned of (display dialog "Secret Name (e.g. MY_API_KEY):" default answer "" with title "Add New Secret")
            end tell' 2>/dev/null)
            [ -z "$name" ] && return
            v1=$(osascript -e "tell application \"System Events\"
                activate
                set theVal to text returned of (display dialog \"Enter value for $name:\" default answer \"\" with title \"Add New Secret\" with hidden answer)
            end tell" 2>/dev/null)
            [ -z "$v1" ] && return
            v2=$(osascript -e "tell application \"System Events\"
                activate
                set theVal to text returned of (display dialog \"Confirm value for $name:\" default answer \"\" with title \"Add New Secret\" with hidden answer)
            end tell" 2>/dev/null)
            if [ "$v1" != "$v2" ]; then
                osascript -e 'display dialog "Values do not match." with title "Error" buttons {"OK"}' 2>/dev/null
                return
            fi
            result="$name=$v1"
            ;;

        # Linux — try zenity (kdialog has no easy multi-field form)
        Linux)
            if command -v zenity >/dev/null 2>&1; then
                local form_out name v1 v2
                form_out=$(zenity --forms --title="Add New Secret" \
                    --text="Enter secret details" \
                    --add-entry="Secret Name (e.g. MY_API_KEY)" \
                    --add-password="Value" \
                    --add-password="Confirm Value" \
                    --separator="|" 2>/dev/null)
                [ -z "$form_out" ] && return
                IFS='|' read -r name v1 v2 <<< "$form_out"
                if [ -z "$name" ]; then
                    zenity --error --text="Secret name cannot be empty." 2>/dev/null
                    return
                fi
                if [ "$v1" != "$v2" ]; then
                    zenity --error --text="Values do not match." 2>/dev/null
                    return
                fi
                result="$name=$v1"
            else
                echo "Error: zenity not installed. Install with: sudo apt install zenity" >&2
                return 1
            fi
            ;;

        *)
            echo "Error: Unsupported OS '$os' for GUI input." >&2
            return 1
            ;;
    esac

    echo "$result"
}

# Add a secret via GUI popup (no command-line typing needed).
# Pops up password prompt, then a form with Name / Value / Confirm Value fields.
# Plaintext never touches disk — decrypt to memory, modify, re-encrypt.
# Usage: add-secret-gui
add-secret-gui() {
    if [ ! -f "$ENCRYPTED_FILE" ]; then
        echo -e "${RED}Error: $ENCRYPTED_FILE not found in current directory.${NC}"
        echo "Make sure you're in the directory containing your encrypted secrets."
        return 1
    fi

    echo "Requesting master password..."
    local password
    password=$(_get-secrets-password)

    if [ -z "$password" ]; then
        echo -e "${RED}No password provided.${NC}"
        return 1
    fi

    # Verify password by attempting decrypt (so we don't pop up the form on bad password)
    local decrypted
    decrypted=$(openssl enc -aes-256-cbc -d -pbkdf2 -in "$ENCRYPTED_FILE" -pass "pass:$password" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to decrypt. Wrong password?${NC}"
        return 1
    fi

    echo "Opening secret entry form..."
    local entry
    entry=$(_get-new-secret-input)

    if [ -z "$entry" ]; then
        echo -e "${YELLOW}Cancelled — no secret added.${NC}"
        return 1
    fi

    # Parse KEY=VALUE
    local key="${entry%%=*}"
    local value="${entry#*=}"

    if [ -z "$key" ] || [ -z "$value" ]; then
        echo -e "${RED}Invalid entry from form.${NC}"
        return 1
    fi

    # Check if key already exists — warn user
    if echo "$decrypted" | grep -q "^${key}="; then
        echo -e "${YELLOW}Note: '$key' already exists and will be overwritten.${NC}"
    fi

    # Remove existing line for this key (if any)
    local updated
    updated=$(echo "$decrypted" | grep -v "^${key}=")

    # Add a "Custom" section header on first add (gives blank line separation
    # from previous categories and keeps additions visually grouped)
    local custom_hdr="# Custom secrets (added via add-secret/add-secret-gui)"
    if ! echo "$updated" | grep -qF "$custom_hdr"; then
        updated="${updated}"$'\n\n'"${custom_hdr}"
    fi

    # Append the new key on its own line
    updated="${updated}"$'\n'"${key}=${value}"

    # Re-encrypt (pipe, never written as plaintext file)
    echo "$updated" | openssl enc -aes-256-cbc -salt -pbkdf2 -out "$ENCRYPTED_FILE" -pass "pass:$password" 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Secret '$key' added/updated and re-encrypted.${NC}"
    else
        echo -e "${RED}Failed to re-encrypt.${NC}"
        return 1
    fi
}

# Remove a secret by key name
# Usage: remove-secret KEY
remove-secret() {
    if [ $# -ne 1 ]; then
        echo -e "${RED}Usage: remove-secret KEY${NC}"
        return 1
    fi

    local key="$1"

    if [ ! -f "$ENCRYPTED_FILE" ]; then
        echo -e "${RED}Error: $ENCRYPTED_FILE not found!${NC}"
        return 1
    fi

    echo "Requesting password..."
    local password
    password=$(_get-secrets-password)

    if [ -z "$password" ]; then
        echo -e "${RED}No password provided.${NC}"
        return 1
    fi

    local decrypted
    decrypted=$(openssl enc -aes-256-cbc -d -pbkdf2 -in "$ENCRYPTED_FILE" -pass "pass:$password" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to decrypt. Wrong password?${NC}"
        return 1
    fi

    # Check if key exists
    if ! echo "$decrypted" | grep -q "^${key}="; then
        echo -e "${YELLOW}Key '$key' not found in secrets.${NC}"
        return 1
    fi

    # Remove the line and re-encrypt
    local updated
    updated=$(echo "$decrypted" | grep -v "^${key}=")

    echo "$updated" | openssl enc -aes-256-cbc -salt -pbkdf2 -out "$ENCRYPTED_FILE" -pass "pass:$password" 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Secret '$key' removed and re-encrypted.${NC}"
    else
        echo -e "${RED}Failed to re-encrypt.${NC}"
        return 1
    fi
}

# ─── Secrets Agent (long-running daemon for one-popup-per-session UX) ──
# The agent holds decrypted secrets in memory after one master-password entry,
# so multiple shell invocations / Claude Code calls don't have to re-prompt.
# Enforces category-based scoping: new categories trigger a fresh popup.
# See ~/secrets-agent.ts for implementation, ~/secrets-categories.json for config.

AGENT_SCRIPT="$HOME/secrets-agent.ts"

# Wrapper: secrets-agent <start|stop|status|get|dump|dump-all>
secrets-agent() {
    if [ ! -f "$AGENT_SCRIPT" ]; then
        echo -e "${RED}Error: $AGENT_SCRIPT not found.${NC}"
        return 1
    fi
    if ! command -v bun >/dev/null 2>&1; then
        echo -e "${RED}Error: bun runtime not found. Install from https://bun.sh${NC}"
        return 1
    fi

    local subcmd="${1:-status}"

    if [ "$subcmd" = "start" ]; then
        # Start in background so it survives this shell exit.
        # Use nohup so it detaches; output goes to log file.
        local log_file="$HOME/.secrets-agent/agent.log"
        mkdir -p "$HOME/.secrets-agent" 2>/dev/null
        nohup bun "$AGENT_SCRIPT" start > "$log_file" 2>&1 &
        disown 2>/dev/null
        # Wait for password popup + startup
        sleep 2
        if bun "$AGENT_SCRIPT" status >/dev/null 2>&1; then
            echo -e "${GREEN}Secrets Agent started.${NC}"
            bun "$AGENT_SCRIPT" status
        else
            echo -e "${RED}Failed to start agent. Check $log_file${NC}"
            return 1
        fi
        return 0
    fi

    bun "$AGENT_SCRIPT" "$@"
}

# Load secrets via the agent (auto-starts agent if not running).
# Use this in place of load-secrets-secure when you want the one-popup-per-session UX.
# Optional: load-secrets-from-agent --bulk     (popup once, load EVERYTHING)
load-secrets-from-agent() {
    if [ ! -f "$AGENT_SCRIPT" ]; then
        echo -e "${YELLOW}Agent script missing — falling back to load-secrets-secure${NC}"
        load-secrets-secure
        return $?
    fi

    # Auto-start agent if not running
    if ! bun "$AGENT_SCRIPT" status >/dev/null 2>&1; then
        echo "Agent not running — starting it (password popup)..."
        secrets-agent start || return 1
    fi

    local mode="dump"
    if [ "${1:-}" = "--bulk" ] || [ "${1:-}" = "--all" ]; then
        mode="dump-all"
    fi

    # Pull export lines from agent and eval them in current shell.
    # SECRETS_AGENT_INTERNAL=1 confirms to the agent that we're inside the
    # bash wrapper (where output is captured by $(...) and eval'd, never
    # displayed to the user/AI).
    local export_lines
    export_lines=$(SECRETS_AGENT_INTERNAL=1 bun "$AGENT_SCRIPT" "$mode" 2>/dev/null)
    if [ -z "$export_lines" ]; then
        echo -e "${YELLOW}No keys returned from agent (no categories unlocked yet?)${NC}"
        echo "Try: load-secrets-from-agent --bulk  (loads everything with one popup)"
        return 1
    fi

    eval "$export_lines"
    local count
    count=$(echo "$export_lines" | grep -c '^export ')
    echo -e "${GREEN}Loaded $count secrets from agent.${NC}"
    return 0
}

# Show available commands
show-secrets-help() {
    echo "Secrets Manager Commands:"
    echo ""
    echo "Recommended (Agent — one popup per session, category-scoped):"
    echo "  secrets-agent start         - Start the agent (master password popup)"
    echo "  secrets-agent status        - Show running state, idle time, unlocked categories"
    echo "  secrets-agent stop          - Stop the agent (forces re-auth on next use)"
    echo "  load-secrets-from-agent     - Load currently-unlocked keys into env vars"
    echo "  load-secrets-from-agent --bulk - Load ALL keys (one popup unlocks everything)"
    echo ""
    echo "Direct (no agent — popup every time):"
    echo "  load-secrets-secure         - Popup password, decrypt to env vars only"
    echo ""
    echo "Manage encrypted secrets:"
    echo "  add-secret-gui              - GUI popup form: name + value + confirm value"
    echo "  add-secret KEY VAL          - CLI version (value visible in shell history)"
    echo "  remove-secret KEY           - Remove a secret by name"
    echo "  unlock-secrets              - Decrypt to plaintext file (manual flow)"
    echo "  lock-secrets                - Encrypt and delete plaintext"
    echo "  toggle-secrets              - Auto lock/unlock"
    echo ""
    echo "Current status:"
    if [ -f "$SECRETS_FILE" ]; then
        echo -e "  ${YELLOW}UNLOCKED${NC} - $SECRETS_FILE exists (plaintext on disk!)"
    else
        echo -e "  ${GREEN}LOCKED${NC} - Secrets are encrypted"
    fi
    if [ -f "$AGENT_SCRIPT" ] && command -v bun >/dev/null 2>&1; then
        if bun "$AGENT_SCRIPT" status >/dev/null 2>&1; then
            echo -e "  ${GREEN}AGENT RUNNING${NC}"
        else
            echo -e "  ${YELLOW}Agent not running${NC} (run: secrets-agent start)"
        fi
    fi
}

echo -e "${GREEN}Secrets Manager loaded!${NC}"
echo "Commands: secrets-agent, load-secrets-from-agent, load-secrets-secure, add-secret-gui, show-secrets-help"
