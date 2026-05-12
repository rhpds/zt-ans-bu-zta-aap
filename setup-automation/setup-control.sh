#!/bin/bash
set -euo pipefail

echo "Starting Control node setup (bootstrap phase)..."
export ANSIBLE_LOCALHOST_WARNING=False
export ANSIBLE_INVENTORY_UNPARSED_WARNING=False

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

run_if_needed() {
    local desc="$1"
    shift
    local check=()
    while [[ $# -gt 0 && "${1}" != "--" ]]; do
        check+=("$1"); shift
    done
    shift
    if "${check[@]}" &>/dev/null; then
        echo "SKIP (already done): $desc"
    else
        retry "$desc" "$@"
    fi
}

###############################################################################
# 1. Validate required environment variables
###############################################################################

for var in TMM_ORG TMM_ID AH_TOKEN; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var environment variable is not set"
        exit 1
    fi
done

###############################################################################
# 2. Enable subscription-manager repo management (idempotent)
###############################################################################

CURRENT_MANAGE_REPOS=$(subscription-manager config --list | grep -oP 'manage_repos\s*=\s*\[\K[^\]]+' || echo "unknown")
if [ "$CURRENT_MANAGE_REPOS" = "1" ]; then
    echo "SKIP: manage_repos already enabled"
else
    subscription-manager config --rhsm.manage_repos=1
    subscription-manager refresh
fi

###############################################################################
# 3. Setup Ansible configuration with AH Token
###############################################################################

tee ~/.ansible.cfg > /dev/null <<EOF
[defaults]
[galaxy]
server_list = automation_hub, validated, galaxy
[galaxy_server.automation_hub]
url = https://console.redhat.com/api/automation-hub/content/published/
auth_url = https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token
token=$AH_TOKEN
[galaxy_server.validated]
url = https://console.redhat.com/api/automation-hub/content/validated/
auth_url = https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token
token=$AH_TOKEN
[galaxy_server.galaxy]
url=https://galaxy.ansible.com/
[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
pipelining = True
EOF

###############################################################################
# 4. Install packages
###############################################################################

run_if_needed "Install base packages" \
    rpm -q dnf-utils \
    -- \
    dnf install -y dnf-utils git nano

run_if_needed "Install IPA client packages" \
    rpm -q ipa-client \
    -- \
    dnf install -y ipa-client sssd oddjob-mkhomedir

run_if_needed "Install Python3 libraries" \
    rpm -q python3-libsemanage \
    -- \
    dnf install -y python3-libsemanage

###############################################################################
# 5. Clone workshop repo (idempotent)
###############################################################################

if [ -d /tmp/zta-workshop-aap/.git ]; then
    echo "INFO: /tmp/zta-workshop-aap exists, pulling latest main"
    git -C /tmp/zta-workshop-aap pull --ff-only origin main
else
    rm -rf /tmp/zta-workshop-aap
    retry "Clone ZTA workshop repo" \
        git clone -b main https://github.com/rhpds/lb2864-zta-aap-automation.git /tmp/zta-workshop-aap
fi

# Ensure Ansible SSH ControlPath and fact-cache dirs are owned by the run user.
# ansible.cfg sets control_path_dir=/tmp/.ansible-cp; if provisioning runs as
# root first and creates the directory, subsequent rhel-user runs will fail.
mkdir -p /tmp/.ansible-cp /tmp/.ansible-fact-cache
chmod 700 /tmp/.ansible-cp /tmp/.ansible-fact-cache

###############################################################################
# 6. Install Ansible collections
###############################################################################

tee /tmp/requirements.yml > /dev/null <<EOF
---
collections:
  - name: cisco.ios
  - name: arista.eos
  - name: ansible.netcommon
  - name: community.postgresql
  - name: community.general
  - name: redhat.rhel_idm
  - name: netbox.netbox
  - name: containers.podman
  - name: ansible.controller
  - name: ansible.posix

EOF

run_if_needed "Install Ansible collections" \
    bash -c 'ansible-galaxy collection list | grep -q "arista.eos"' \
    -- \
    ansible-galaxy install -r /tmp/requirements.yml

# If ansible.controller was not installed from Automation Hub (e.g. token
# expired or unavailable), create a namespace symlink so that awx.awx
# (installed from Galaxy) serves the ansible.controller FQCN.  Both the
# module names (ansible.controller.*) and module_defaults group resolution
# (group/ansible.controller.controller:) work via this symlink because
# Ansible uses path-based collection lookup; awx.awx defines the same
# action_groups.controller entries as ansible.controller.
if ! ansible-galaxy collection list 2>/dev/null | grep -q "ansible.controller"; then
    echo "INFO: ansible.controller not found; symlinking awx.awx as ansible.controller"
    mkdir -p ~/.ansible/collections/ansible_collections/ansible
    ln -sfn ~/.ansible/collections/ansible_collections/awx/awx \
            ~/.ansible/collections/ansible_collections/ansible/controller
fi

# paramiko is required by arista.eos for direct SSH to cEOS switches
run_if_needed "Install paramiko" \
    bash -c 'python3 -c "import paramiko" 2>/dev/null' \
    -- \
    bash -c 'dnf install -y python3-pip 2>/dev/null; python3 -m pip install paramiko'

cp /tmp/zta-workshop-aap/ansible.cfg /etc/ansible/

echo ""
echo "control bootstrap phase complete"
