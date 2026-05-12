#!/bin/bash
# recover-after-restart.sh — Restore lab runtime state after an accidental stop/start.
#
# Runs the idempotent recovery playbook from the cloned automation repo.
# Safe to run on a healthy lab — tasks that are already in the desired state skip.
#
# Usage:
#   sudo bash /home/rhel/zt-ans-bu-zta-aap/setup-automation/recover-after-restart.sh
#
# To target only specific recovery steps use --tags:
#   sudo ... recover-after-restart.sh --tags vault
#   sudo ... recover-after-restart.sh --tags netbox
#   sudo ... recover-after-restart.sh --tags ceos,dataplane

set -euo pipefail

PLAYBOOK_DIR="/tmp/zta-workshop-aap"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_CONFIG="${PLAYBOOK_DIR}/ansible.cfg"

cd "${PLAYBOOK_DIR}" || { echo "ERROR: ${PLAYBOOK_DIR} not found — has setup-central.sh been run?"; exit 1; }

echo "Running lab recovery playbook..."
ansible-playbook -i inventory/hosts.ini setup/recover-after-restart.yml "$@"
echo ""
echo "Recovery complete."
