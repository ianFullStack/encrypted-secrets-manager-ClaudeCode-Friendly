#!/bin/bash
# Demo: Using environment variables to connect to a database
# This simulates what Claude would do when you tell me to use secrets

echo "=== Connecting to Database ==="
echo "Host: $DB_HOST"
echo "User: $DB_USER"
echo "Password: [HIDDEN - using \$DB_PASSWORD from environment]"
echo ""
echo "=== Making API Call ==="
echo "Using OpenAI API Key: ${OPENAI_API_KEY:0:10}... [rest hidden]"
echo ""
echo "✅ Commands executed successfully without exposing secrets in chat!"
