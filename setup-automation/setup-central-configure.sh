#!/bin/bash
set -euo pipefail

echo "Starting Central node setup (configure phase)..."

export ANSIBLE_HOST_KEY_CHECKING=False
export NETBOX_TOKEN=0123456789abcdef0123456789abcdef01234567
export ANSIBLE_CONFIG=/tmp/zta-workshop-aap/ansible.cfg

###############################################################################
# 1. Wait for Vault to be unsealed (HTTP 200 = initialized + unsealed + active)
###############################################################################

echo "Waiting for Vault to be ready and unsealed..."
VAULT_TIMEOUT=300
VAULT_ELAPSED=0
while [ $VAULT_ELAPSED -lt $VAULT_TIMEOUT ]; do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://192.168.1.12:8200/v1/sys/health 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo "Vault is ready and unsealed (waited ${VAULT_ELAPSED}s)"
        break
    fi
    echo "Vault not ready yet (HTTP ${HTTP_CODE}, ${VAULT_ELAPSED}s/${VAULT_TIMEOUT}s)..."
    sleep 10
    VAULT_ELAPSED=$((VAULT_ELAPSED + 10))
done

if [ $VAULT_ELAPSED -ge $VAULT_TIMEOUT ]; then
    echo "ERROR: Vault did not become ready within ${VAULT_TIMEOUT}s"
    exit 1
fi

###############################################################################
# 2. Wait for NetBox to be responsive
###############################################################################

echo "Waiting for NetBox to be ready..."
NETBOX_TIMEOUT=300
NETBOX_ELAPSED=0
while [ $NETBOX_ELAPSED -lt $NETBOX_TIMEOUT ]; do
    if curl -f -s http://192.168.1.15:8000 &>/dev/null; then
        echo "NetBox is ready (waited ${NETBOX_ELAPSED}s)"
        break
    fi
    echo "NetBox not ready yet (${NETBOX_ELAPSED}s/${NETBOX_TIMEOUT}s)..."
    sleep 10
    NETBOX_ELAPSED=$((NETBOX_ELAPSED + 10))
done

if [ $NETBOX_ELAPSED -ge $NETBOX_TIMEOUT ]; then
    echo "ERROR: NetBox did not become ready within ${NETBOX_TIMEOUT}s"
    exit 1
fi

###############################################################################
# 3. Run service-dependent playbooks
###############################################################################

PLAYBOOK_DIR="/tmp/zta-workshop-aap"
cd "${PLAYBOOK_DIR}" || { echo "ERROR: Cannot cd to ${PLAYBOOK_DIR}"; exit 1; }

ansible-playbook -i inventory/hosts.ini setup/configure-vault.yml
ansible-playbook -i inventory/hosts.ini setup/configure-vault-ssh.yml
ansible-playbook -i inventory/hosts.ini setup/configure-netbox.yml
ansible-playbook -i inventory/hosts.ini setup/integrate-splunk.yml --skip-tags arista_syslog,wazuh_splunk
ansible-playbook -i inventory/hosts.ini setup/configure-aap-podman-gateway-prereqs.yml

echo ""
echo "central configure phase complete"
