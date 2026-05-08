#!/bin/bash
set -euo pipefail

PLAYBOOK_DIR="/tmp/zta-workshop-aap"
AAP_HOST="https://control.zta.lab"
AAP_PASS="${AAP_ADMIN_PASSWORD:-ansible123!}"

# Pre-generate OAuth token to bypass awx.awx broken /api/v2/tokens/ endpoint
# (AAP 2.6 gateway uses /api/controller/v2/tokens/ instead)
echo "Generating AAP OAuth token..."
OAUTH_TOKEN=$(curl -sk -X POST -u "admin:${AAP_PASS}" \
  -H "Content-Type: application/json" \
  -d '{"description":"runtime-module02","application":null,"scope":"write"}' \
  "${AAP_HOST}/api/controller/v2/tokens/" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")

if [ -z "$OAUTH_TOKEN" ]; then
  echo "ERROR: Failed to obtain OAuth token from AAP controller" >&2
  exit 1
fi

echo "Token obtained. Removing Section 1 templates..."
ansible-playbook -i "${PLAYBOOK_DIR}/inventory/hosts.ini" \
  "${PLAYBOOK_DIR}/setup/configure-aap-project.yml" \
  --tags remove_section \
  --extra-vars "aap_remove_section=1 controller_oauthtoken=${OAUTH_TOKEN}"

echo "Creating Section 2 templates..."
ansible-playbook -i "${PLAYBOOK_DIR}/inventory/hosts.ini" \
  "${PLAYBOOK_DIR}/setup/configure-aap-project.yml" \
  --tags section2,rbac \
  --extra-vars "controller_oauthtoken=${OAUTH_TOKEN}"

echo "Module 02 runtime setup complete."
