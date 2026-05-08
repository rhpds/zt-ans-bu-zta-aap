#!/bin/bash
set -euo pipefail

echo "Starting Central node setup (bootstrap phase)..."

cleanup() {
    echo "Cleaning up temporary ansible configuration..."
    rm -rf ~/.ansible.cfg
}
trap cleanup EXIT

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

for var in AH_TOKEN TMM_ORG TMM_ID GUID DOMAIN; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var environment variable is not set"
        echo "Usage: AH_TOKEN='...' TMM_ORG='...' TMM_ID='...' GUID='...' DOMAIN='...' $0"
        exit 1
    fi
done

###############################################################################
# 2. Environment variables
###############################################################################

export ANSIBLE_HOST_KEY_CHECKING=False
export NETBOX_TOKEN=0123456789abcdef0123456789abcdef01234567
export ANSIBLE_CONFIG=/tmp/zta-workshop-aap/ansible.cfg
mkdir -p /root/.ansible/cp

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

run_if_needed "Install pynetbox" \
    python3 -c "import pynetbox" \
    -- \
     pip3 install pynetbox --user

run_if_needed "Install paramiko" \
    python3 -c "import paramiko" \
    -- \
     pip3 install paramiko --user

###############################################################################
# 5. Install IPA client into containers via podman mount
###############################################################################

subscription-manager repos --enable rhel-9-for-x86_64-appstream-rpms 2>/dev/null || true

for c in app db; do
    if podman container exists "$c" 2>/dev/null; then
        if podman exec "$c" rpm -q ipa-client &>/dev/null; then
            echo "SKIP: ipa-client already installed in container '$c'"
        else
            echo "Installing ipa-client into '${c}' via podman mount"
            podman stop "$c" 2>/dev/null || true
            mnt=$(podman mount "$c")
            dnf install --installroot="$mnt" --releasever=9 -y ipa-client
            chroot "$mnt" rm -rf /var/log/dnf /var/cache/dnf
            podman umount "$c"
            podman start "$c"
            echo "ipa-client installed in '${c}'"
        fi

        podman exec "$c" bash -c \
            'rm -f /etc/yum.repos.d/redhat.repo
             sed -i "s/^enabled=1/enabled=0/" /etc/dnf/plugins/subscription-manager.conf 2>/dev/null || true
             sed -i "s/^skip_if_unavailable=.*/skip_if_unavailable=True/" /etc/dnf/dnf.conf 2>/dev/null || true'
    else
        echo "SKIP: Container '$c' does not exist"
    fi
done

###############################################################################
# 6. Clone workshop repo (idempotent)
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
mkdir -p /tmp/.ansible-cp /tmp/.ansible-fact-cache
chmod 700 /tmp/.ansible-cp /tmp/.ansible-fact-cache

###############################################################################
# 7. IPA rewrite config (idempotent)
###############################################################################

IPA_REWRITE="/etc/httpd/conf.d/ipa-rewrite.conf"
if grep -q "RequestHeader set Host central.zta.lab" "$IPA_REWRITE" 2>/dev/null; then
    echo "SKIP: ipa-rewrite.conf already configured"
else
    tee "$IPA_REWRITE" << 'IPA'
# VERSION 7 - DO NOT REMOVE THIS LINE
RequestHeader set Host central.zta.lab
RequestHeader set Referer https://central.zta.lab/ipa/ui/
RewriteEngine on
RewriteRule ^/ipa/ui/js/freeipa/plugins.js$    /ipa/wsgi/plugins.py [PT]
RewriteCond %{HTTP_HOST}    ^ipa-ca.example.local$ [NC]
RewriteCond %{REQUEST_URI}  !^/ipa/crl
RewriteCond %{REQUEST_URI}  !^/(ca|kra|pki|acme)
IPA

    if systemctl is-active --quiet httpd; then
        systemctl reload httpd
        echo "Apache httpd reloaded"
    else
        echo "NOTE: httpd not running, config will apply when started"
    fi
fi

###############################################################################
# 8. Reconfigure Keycloak container
###############################################################################

echo "Reconfiguring Keycloak container..."
podman stop keycloak 2>/dev/null || true
systemctl stop container-keycloak 2>/dev/null || true
systemctl kill container-keycloak 2>/dev/null || true
podman rm --force keycloak 2>/dev/null || true

podman create --name keycloak --restart=always \
    -p 8180:8080 -p 8543:8443 \
    -e KEYCLOAK_ADMIN=admin \
    -e KEYCLOAK_ADMIN_PASSWORD=ansible123! \
    -e KC_HOSTNAME=keycloak-https-${GUID}.${DOMAIN} \
    -e KC_HTTPS_CERTIFICATE_FILE=/opt/certs/server.crt \
    -e KC_HTTPS_CERTIFICATE_KEY_FILE=/opt/certs/server.key \
    -e KC_HTTP_ENABLED=true \
    -v /opt/keycloak/certs:/opt/certs:Z \
    registry.redhat.io/rhbk/keycloak-rhel9:24 start \
    --hostname=keycloak-https-${GUID}.${DOMAIN} \
    --https-port=8443 \
    --http-enabled=true \
    --proxy-headers forwarded

if [ -f /etc/systemd/system/container-keycloak.service ]; then
    sed -i "/^PIDFile/d" /etc/systemd/system/container-keycloak.service
    systemctl daemon-reload
fi
systemctl start container-keycloak

###############################################################################
# 9. Copy ansible.cfg and run independent playbooks
###############################################################################

cp /tmp/zta-workshop-aap/ansible.cfg /etc/ansible/

PLAYBOOK_DIR="/tmp/zta-workshop-aap"
cd "${PLAYBOOK_DIR}" || { echo "ERROR: Cannot cd to ${PLAYBOOK_DIR}"; exit 1; }
ansible-playbook -i inventory/hosts.ini setup/configure-dns.yml
ansible-playbook -i inventory/hosts.ini setup/enroll-idm-clients.yml
ansible-playbook -i inventory/hosts.ini setup/deploy-central.yml --skip-tags keycloak

###############################################################################
# 9b. Pre-install container packages using host Satellite subscription
#     db and app containers are ubi9/ubi-init at runtime with no RHSM access.
#     Use podman mount + dnf --installroot so the host subscription satisfies
#     all dependencies directly into the container filesystem without a
#     download-copy-localinstall cycle.
#
#     Packages covered:
#       db:  postgresql-server postgresql python3-psycopg2 rsyslog
#            (needed by deploy-db-app.yml and integrate-splunk.yml)
#       app: python3 python3-pip python3-psycopg2 rsyslog
#            (needed by deploy-db-app.yml and integrate-splunk.yml)
###############################################################################

subscription-manager repos --enable rhel-9-for-x86_64-appstream-rpms 2>/dev/null || true

for container_name in db app; do
    if podman container exists "$container_name" 2>/dev/null; then
        case "$container_name" in
            db)  pkgs="postgresql-server postgresql python3-psycopg2 rsyslog"
                 check_pkg="postgresql-server" ;;
            app) pkgs="python3 python3-pip python3-psycopg2 rsyslog"
                 check_pkg="python3-psycopg2" ;;
        esac

        if podman exec "$container_name" rpm -q "$check_pkg" &>/dev/null; then
            echo "SKIP (already done): packages already installed in '${container_name}'"
        else
            echo "Installing packages into '${container_name}' via podman mount: ${pkgs}"
            podman stop "$container_name" 2>/dev/null || true
            mnt=$(podman mount "$container_name")
            # shellcheck disable=SC2086
            dnf install --installroot="$mnt" --releasever=9 -y $pkgs
            chroot "$mnt" rm -rf /var/log/dnf /var/cache/dnf
            podman umount "$container_name"
            podman start "$container_name"
            echo "Packages installed in '${container_name}'"
        fi

        # Remove the RHSM repo file and set skip_if_unavailable unconditionally.
        # deploy-central.yml may have pre-installed packages via dnf, leaving
        # redhat.repo inside the container. Ansible's dnf module refreshes ALL
        # repo metadata on initialisation — even for state: present — and aborts
        # when Satellite is unreachable from the container.
        podman exec "$container_name" bash -c \
            'rm -f /etc/yum.repos.d/redhat.repo
             sed -i "s/^enabled=1/enabled=0/" /etc/dnf/plugins/subscription-manager.conf 2>/dev/null || true
             sed -i "s/^skip_if_unavailable=.*/skip_if_unavailable=True/" /etc/dnf/dnf.conf 2>/dev/null || true'
    else
        echo "SKIP: Container '${container_name}' does not exist, skipping pre-install"
    fi
done

ansible-playbook -i inventory/hosts.ini setup/deploy-db-app.yml

echo ""
echo "central bootstrap phase complete"
