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

# Show available commands
show-secrets-help() {
    echo "Secrets Manager Commands:"
    echo "  unlock-secrets  - Decrypt $ENCRYPTED_FILE to $SECRETS_FILE"
    echo "  lock-secrets    - Encrypt $SECRETS_FILE to $ENCRYPTED_FILE and delete plaintext"
    echo "  toggle-secrets  - Auto lock/unlock based on current state"
    echo "  load-secrets    - Load secrets into environment variables (more secure!)"
    echo ""
    echo "Current status:"
    if [ -f "$SECRETS_FILE" ]; then
        echo -e "  ${YELLOW}🔓 UNLOCKED${NC} - $SECRETS_FILE exists"
    else
        echo -e "  ${GREEN}🔒 LOCKED${NC} - Secrets are encrypted"
    fi
}

echo -e "${GREEN}Secrets Manager loaded!${NC}"
echo "Commands: unlock-secrets, lock-secrets, toggle-secrets, load-secrets, show-secrets-help"
