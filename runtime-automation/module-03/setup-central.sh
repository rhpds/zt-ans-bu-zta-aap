#!/bin/bash
set -euo pipefail

PLAYBOOK_DIR="/tmp/zta-workshop-aap"
AAP_HOST="https://control.zta.lab"
AAP_PASS="${AAP_ADMIN_PASSWORD:-ansible123!}"

# Pre-generate OAuth token to bypass awx.awx broken /api/v2/tokens/ endpoint
echo "Generating AAP OAuth token..."
OAUTH_TOKEN=$(curl -sk -X POST -u "admin:${AAP_PASS}" \
  -H "Content-Type: application/json" \
  -d '{"description":"runtime-module03","application":null,"scope":"write"}' \
  "${AAP_HOST}/api/controller/v2/tokens/" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")

if [ -z "$OAUTH_TOKEN" ]; then
  echo "ERROR: Failed to obtain OAuth token from AAP controller" >&2
  exit 1
fi

echo "Token obtained. Creating Section 3 templates..."
ansible-playbook -i "${PLAYBOOK_DIR}/inventory/hosts.ini" \
  "${PLAYBOOK_DIR}/setup/configure-aap-project.yml" \
  --tags section3,rbac \
  --extra-vars "controller_oauthtoken=${OAUTH_TOKEN}"

# Move neteng from team-infrastructure → team-readonly
# This scopes Section 3's AAP Policy as Code exercise:
# - neteng can no longer run infrastructure jobs (no policy bypass)
# - neteng is in Readonly so they can see (but not run) Section 3 templates
echo "Updating IdM group memberships for Section 3..."
ipa group-remove-member team-infrastructure --users=neteng || true
ipa group-add team-readonly \
  --desc="Read-only template visibility (all workshop users)" 2>/dev/null || true
ipa group-add-member team-readonly --users=neteng || true

echo "Module 03 runtime setup complete."
