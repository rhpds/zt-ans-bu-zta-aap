#!/bin/bash
set -euo pipefail

echo "Starting Vault node setup..."

###############################################################################
# Helpers
###############################################################################

retry() {
    local max_attempts=3
    local delay=5
    local desc="$1"
    shift
    for ((i = 1; i <= max_attempts; i++)); do
        echo "Attempt $i/$max_attempts: $desc"
        if "$@"; then
            return 0
        fi
        if [ $i -lt $max_attempts ]; then
            echo "  Failed. Retrying in ${delay}s..."
            sleep $delay
        fi
    done
    echo "FATAL: Failed after $max_attempts attempts: $desc"
    exit 1
}

###############################################################################
# 1. Validate required environment variables
###############################################################################

for var in VAULT_LIC; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var environment variable is not set"
        exit 1
    fi
done

###############################################################################
# 2. Apply Vault license (idempotent)
###############################################################################

VAULT_LIC_FILE="/etc/vault.d/vault.hclic"

if [ -f "$VAULT_LIC_FILE" ]; then
    EXISTING_LIC=$(cat "$VAULT_LIC_FILE")
    if [ "$EXISTING_LIC" = "$VAULT_LIC" ]; then
        echo "SKIP: Vault license already configured with same content"
        LICENSE_UPDATED=false
    else
        echo "Updating Vault license file..."
        echo "$VAULT_LIC" | sudo tee "$VAULT_LIC_FILE" > /dev/null
        sudo chmod 640 "$VAULT_LIC_FILE"
        sudo chown vault:vault "$VAULT_LIC_FILE"
        echo "License file updated at ${VAULT_LIC_FILE}"
        LICENSE_UPDATED=true
    fi
else
    echo "Creating Vault license file..."
    echo "$VAULT_LIC" | sudo tee "$VAULT_LIC_FILE" > /dev/null
    sudo chmod 640 "$VAULT_LIC_FILE"
    sudo chown vault:vault "$VAULT_LIC_FILE"
    echo "License file written to ${VAULT_LIC_FILE}"
    LICENSE_UPDATED=true
fi

###############################################################################
# 3. Enable and start Vault service (idempotent)
###############################################################################

if ! systemctl is-enabled --quiet vault 2>/dev/null; then
    sudo systemctl enable vault
    echo "Vault service enabled"
else
    echo "SKIP: Vault service already enabled"
fi

if [ "$LICENSE_UPDATED" = true ]; then
    echo "Restarting Vault service due to license update..."
    sudo systemctl restart vault
    sleep 3
else
    if ! systemctl is-active --quiet vault; then
        echo "Starting Vault service..."
        sudo systemctl start vault
        sleep 3
    else
        echo "SKIP: Vault service already running"
    fi
fi

if sudo systemctl is-active --quiet vault; then
    echo "Vault service is running"
else
    echo "ERROR: Vault service may not be running properly"
    sudo systemctl status vault
    exit 1
fi

###############################################################################
# 4. Unseal Vault (idempotent)
###############################################################################

echo "Checking Vault seal status..."

SEAL_STATUS=$(vault status -address=http://127.0.0.1:8200 -format=json 2>/dev/null | grep -o '"sealed":[^,]*' | cut -d: -f2 || echo "true")

if [ "$SEAL_STATUS" = "false" ]; then
    echo "SKIP: Vault is already unsealed"
else
    echo "Unsealing Vault..."
    if vault operator unseal \
        -address=http://127.0.0.1:8200 \
        -tls-skip-verify \
        1c6a637e70172e3c249f77b653fb64a820749864cad7f5aa7ab6d5aca5197ec5; then
        echo "Vault unsealed successfully"
    else
        echo "WARNING: Vault unseal returned non-zero (may already be unsealed or need additional keys)"
    fi
fi

if vault status -address=http://127.0.0.1:8200 &>/dev/null; then
    echo ""
    echo "============================================================"
    echo "  Vault Setup Complete"
    echo "============================================================"
    echo "  Vault URL: http://192.168.1.12:8200"
    echo "  Status: $(vault status -address=http://127.0.0.1:8200 -format=json 2>/dev/null | grep -o '"sealed":[^,]*' | cut -d: -f2 | sed 's/false/Unsealed/;s/true/Sealed/')"
    echo "============================================================"
else
    echo "WARNING: Could not verify Vault status"
fi

echo ""
echo "vault setup complete"
