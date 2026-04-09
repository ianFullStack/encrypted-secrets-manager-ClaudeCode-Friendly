#!/bin/bash
# Opens an interactive terminal to lock secrets.
# Usage: from Claude Code, run: bash ~/lock-secrets.sh

cd ~
start bash -c 'source secrets-manager.sh && lock-secrets; echo ""; echo "Press any key to close..."; read -n1'
