#!/bin/bash
set -euo pipefail

echo "Starting Control node setup (configure phase)..."
export ANSIBLE_LOCALHOST_WARNING=False
export ANSIBLE_INVENTORY_UNPARSED_WARNING=False

AAP_HOST="https://control.zta.lab"
AAP_USER="admin"
AAP_PASS="ansible123!"

PLAYBOOK_DIR="/tmp/zta-workshop-aap"
cd "${PLAYBOOK_DIR}" || { echo "ERROR: Cannot cd to ${PLAYBOOK_DIR}"; exit 1; }

###############################################################################
# 1. Wait for AAP to be ready
###############################################################################

echo "Waiting for AAP controller to be ready..."
for i in $(seq 1 60); do
    CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
        "${AAP_HOST}/api/controller/v2/ping/" -u "${AAP_USER}:${AAP_PASS}" 2>/dev/null)
    if [ "$CODE" = "200" ]; then
        echo "  AAP ready (attempt $i)"
        break
    fi
    echo "  waiting... (attempt $i, HTTP $CODE)"
    sleep 10
done

###############################################################################
# 2. Generate an OAuth token for configure playbooks
#
# awx.awx:24.6.1 tries to generate tokens at /api/v2/tokens/ which is 404
# on AAP 2.6 Gateway.  Pre-generating a token and passing it as
# controller_oauth_token bypasses the broken token generation path.
###############################################################################

echo "Generating AAP OAuth token..."
CONTROLLER_OAUTH_TOKEN=$(curl -sk -X POST \
    "${AAP_HOST}/api/controller/v2/tokens/" \
    -H "Content-Type: application/json" \
    -u "${AAP_USER}:${AAP_PASS}" \
    -d '{"description":"setup-automation","application":null,"scope":"write"}' | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null)

if [ -z "${CONTROLLER_OAUTH_TOKEN}" ]; then
    echo "ERROR: Failed to generate AAP OAuth token — aborting configure phase"
    exit 1
fi
echo "  Token generated OK"
export CONTROLLER_OAUTH_TOKEN

# Convenience alias so ansible-playbook extra-vars are concise
TOKEN_VAR="controller_oauth_token=${CONTROLLER_OAUTH_TOKEN}"

###############################################################################
# 3. Run AAP configuration playbooks
###############################################################################

# Credentials (Vault-sourced machine, Arista, NetBox, SSH CA)
ansible-playbook -i inventory/hosts.ini setup/configure-aap-credentials.yml \
    -e "${TOKEN_VAR}"

# ZTA Live Topology Dashboard
ansible-playbook -i inventory/hosts.ini setup/deploy-dashboard.yml \
    -e "${TOKEN_VAR}"

# Static inventory (ZTA Lab Inventory + hosts)
ansible-playbook -i inventory/hosts.ini setup/configure-aap-inventory.yml \
    -e "${TOKEN_VAR}"

# Project + Execution Environment
ansible-playbook -i inventory/hosts.ini setup/configure-aap-project.yml \
    --tags ee,project -e "${TOKEN_VAR}"

# Refresh inventory after project sync
ansible-playbook -i inventory/hosts.ini setup/configure-aap-inventory.yml \
    -e "${TOKEN_VAR}"

# NetBox CMDB inventory source
ansible-playbook -i inventory/hosts.ini setup/configure-aap-netbox.yml \
    -e "${TOKEN_VAR}"

# Job templates for all lab sections
ansible-playbook -i inventory/hosts.ini setup/configure-aap-project.yml \
    --tags section1,section2,section3,section4,section5,section6 \
    -e "${TOKEN_VAR}"

# EDA project, Decision Environment, event stream, Splunk webhook
# (does NOT create the "Splunk Events" activation — that is a student deliverable in S5.3)
ansible-playbook -i inventory/hosts.ini setup/configure-aap-project.yml \
    --tags eda -e "${TOKEN_VAR}"
ansible-playbook -i inventory/hosts.ini setup/configure-splunk-eda.yml \
    -e "${TOKEN_VAR}"

echo ""
echo "control configure phase complete"
