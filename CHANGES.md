# Lab Stability Fixes — ZTA AAP Workshop

**Branch:** `lab-tuning`
**Automation repo:** [`rhpds/lb2864-zta-aap-automation`](https://github.com/rhpds/lb2864-zta-aap-automation) (`main`)
**Authors:** Wilson Harris, with Cursor AI pair-programming

This document summarises every fix applied to the showroom scripts and the AAP
automation content since the `main` branch of this repo was forked into
`lab-tuning`. It is intended as a handoff reference for developers who need to
understand what was changed, why, and how to validate the lab after a fresh
deployment or an accidental VM restart.

---

## Table of Contents

1. [Setup-script fixes (this repo — `lab-tuning`)](#1-setup-script-fixes)
2. [AAP automation fixes (`lb2864-zta-aap-automation` — `main`)](#2-aap-automation-fixes)
3. [Testing: solve-and-validate walkthrough](#3-testing-solve-and-validate)
4. [Recovery: restoring lab state after a restart](#4-recovery-after-restart)

---

## 1. Setup-script fixes

Changes are in `setup-automation/` and `config/instances.yaml`.

### 1.1 Clone source corrected — both VMs

**Files:** `setup-automation/setup-central.sh`, `setup-automation/setup-control.sh`
**Commit:** `8a53f78`

Both scripts were cloning `nmartins0611/zta-workshop-aap` (an old personal fork,
`zta-container` branch). Changed to `rhpds/lb2864-zta-aap-automation` (`main`) —
the team-maintained fork that contains all current fixes.

Also added `mkdir -p /tmp/.ansible-cp /tmp/.ansible-fact-cache` immediately after
the clone. The `ansible.cfg` in the repo sets `control_path_dir=/tmp/.ansible-cp`;
if provisioning runs as root first, those directories are root-owned and subsequent
SSH multiplexing fails for the `rhel` user.

### 1.2 `git pull` on retry instead of skipping

**File:** `setup-automation/setup-central.sh`
**Commit:** `08bae90`

The original retry logic skipped the clone if the target directory already existed.
Changed to run `git pull` on retry so interrupted provisioning runs pick up the
latest content rather than silently reusing a stale or partial clone.

### 1.3 `paramiko` installed for Arista cEOS SSH

**File:** `setup-automation/setup-central.sh`
**Commit:** `9af488e`

`arista.eos` uses `paramiko` for SSH transport to the cEOS containers. Without it,
every Arista task fails at connection time with a cryptic `No module named paramiko`
error. Added `pip3 install paramiko --user` to the central node setup.

### 1.4 `ansible.controller` symlink fallback

**File:** `setup-automation/setup-central.sh`
**Commit:** `69618e7`

When the Automation Hub token is expired or the Hub is unreachable, the
`ansible.controller` collection fails to install from the `requirements.yml`
Galaxy URL. The lab setup playbooks use `ansible.controller.*` FQCNs throughout.

Added a post-install guard: if `ansible.controller` is absent after the install
attempt, create a namespace symlink:

```
~/.ansible/collections/ansible_collections/ansible/controller
  → ~/.ansible/collections/ansible_collections/awx/awx
```

`awx.awx` (installed from Galaxy) defines the same action groups and module
implementations. The symlink satisfies both FQCN lookups and `module_defaults`
group resolution without changing any playbook code.

### 1.5 Configure phase: AAP readiness wait and AAP 2.6 token

**File:** `setup-automation/setup-control-configure.sh`
**Commits:** `aea357c`, `914fc01`

Two problems in the original configure script (section tagging restored to `section1` only — see below):

| Problem | Fix |
|---|---|
| AAP controller was polled but the script didn't wait long enough | Added a 60-attempt polling loop on `/api/controller/v2/ping/` before running any configure playbooks |
| AAP 2.6 Gateway: `awx.awx:24.6.1` internally calls `/api/v2/tokens/` which returns 404 on the Gateway proxy | Pre-generate a token via `/api/controller/v2/tokens/` and pass it as `controller_oauthtoken` extra-var to bypass the broken auto-token path |

**Note on section tags:** An intermediate commit (`aea357c`) incorrectly changed the initial configure to
pre-create sections 1–6 upfront. This was reverted (`914fc01`) — initial deployment creates Section 1
templates only. Module transition scripts (`runtime-automation/module-0*/setup-central.sh`) handle the
progressive reveal (module-02 removes S1/adds S2, module-03 adds S3, etc.). EDA infrastructure is still
set up at initial configure because the event stream URL must be wired into Splunk before module-05.

### 1.6 AAP OAuth token pre-generated in all module transition scripts

**Files:** `runtime-automation/module-02/setup-central.sh` through `module-05/setup-central.sh`
**Commit:** `f9bc840`

Same AAP 2.6 token issue as §1.5 applies during section transitions. Each
module's transition script now curls `/api/controller/v2/tokens/` before
invoking `configure-aap-project.yml`, and passes the token as
`controller_oauthtoken`. Without this fix, students advancing to Section 2
through Section 5 would see no new templates appear in AAP.

Also documents the Section 3 IdM group mutation (moving `neteng` from
`team-infrastructure` to `team-readonly`) with inline comments.

### 1.7 Gitea seeded from `rhpds/lb2864-zta-aap-automation`

**File:** `config/instances.yaml`
**Commit:** `6084235`

Gitea's migration source was still pointing to `nmartins0611/zta-workshop-aap`.
Changed `clone_addr` to `https://github.com/rhpds/lb2864-zta-aap-automation.git`
and `owner` to `gitea` (the Gitea admin user). This ensures the internal Gitea
repo URL `http://gitea:3000/gitea/zta-workshop-aap` matches what
`configure-aap-project.yml` and `validation_vars.yml` expect, and that AAP
pulls from the team-maintained fork.

### 1.8 Recovery wrapper script added

**File:** `setup-automation/recover-after-restart.sh`
**Commit:** `6d427c1`

Thin wrapper that invokes the recovery playbook (see §4). Added here so lab
operators have a single well-known entry point on the central VM:

```bash
sudo bash /home/rhel/zt-ans-bu-zta-aap/setup-automation/recover-after-restart.sh
```

Supports `--tags` pass-through for targeted recovery.

---

## 2. AAP automation fixes

Changes are in `rhpds/lb2864-zta-aap-automation` (`main`).
File paths are relative to that repository root.

### 2.1 NetBox Execution Environment for inventory source sync

**File:** `setup/validation/solve-section1.yml`
**Commit:** `8fb4775`

The `ansible.controller.inventory_source` task was creating the NetBox inventory
source without specifying an Execution Environment. The default EE lacks the
`netbox.netbox` collection, causing sync to fail with:

```
ERROR! No module named 'netbox'
unknown plugin 'netbox.netbox.nb_inventory'
```

Added `execution_environment: Netbox` to the inventory source definition so the
sync job uses the EE that has `netbox.netbox` pre-installed.

### 2.2 `requesting_user` set for Section 2 workflow — OPA fix

**Files:** `setup/validation/solve-section2.yml`
**Commits:** `9118abb`, `0d505c3`

The "Deploy Application Pipeline" workflow runs `check-db-policy.yml`, which
queries OPA for database access decisions using `requesting_user` (defaulting
to `awx_user_name`). When the workflow is launched by the AAP `admin` user,
OPA correctly denies it — `admin` is not a member of `app-deployers`.

Two-part fix:

1. Pass `extra_vars: {requesting_user: ztauser}` on the `job_launch` task so
   the solve-script launch uses an authorized user.
2. Set `extra_vars: {requesting_user: ztauser}` and `ask_variables_on_launch: true`
   on the workflow template itself — ensures the default is in place for any
   subsequent launch (including student launches from the AAP UI).

### 2.3 `network_user` set for Section 4 VLAN job — OPA fix

**File:** `setup/validation/solve-section4.yml`
**Commit:** `00dd40c`

Same pattern as §2.2 but for the "Configure VLAN" job template. The playbook
`section4/configure-vlan.yml` uses `network_user: "{{ awx_user_name | default('neteng') }}"`.
When launched by `admin`, OPA denies with:

```
DENIED: user 'admin' is not a member of network-admins group
```

Fix: set `extra_vars: {network_user: netadmin}` on both the template definition
and the explicit `job_launch` task. `netadmin` is in the `network-admins` IdM
group so OPA permits the request.

### 2.4 Post-restart recovery playbook

**File:** `setup/recover-after-restart.yml`
**Commit:** `8913cb8`

New idempotent playbook that restores all runtime state lost after a lab
stop/start. See [§4](#4-recovery-after-restart) for full details.

---

## 3. Testing: solve-and-validate walkthrough

After a fresh deployment completes, run the full end-to-end validation from
the **central VM** to confirm every lab section works.

### Prerequisites

- `oc exec` into the `showroom` pod in the lab namespace and `ssh` to the
  central VM, **or** SSH directly to `192.168.1.11` via the bastion.
- The automation repo must be present at `/tmp/zta-workshop-aap` (placed by
  `setup-central.sh`).

### Run the solve

```bash
cd /tmp/zta-workshop-aap

# Full solve + validate (all sections)
ansible-playbook -i inventory/hosts.ini setup/validation/solve-all.yml \
  -e aap_password=ansible123!

# Individual section (example: Section 4 only)
ansible-playbook -i inventory/hosts.ini setup/validation/solve-section4.yml \
  -e aap_password=ansible123!
```

### Expected outcomes by section

| Section | What it creates | Key validation |
|---|---|---|
| 1 | AAP Project, Inventory (NetBox), credential set | Inventory sync succeeds with `Netbox` EE |
| 2 | "Deploy Application Pipeline" workflow | OPA permits `ztauser` (app-deployers); app health returns `{"status":"ok"}` |
| 3 | "Configure DB Access List" job template | SSH to ceos2 eAPI succeeds; ACL verified via Arista `show ip access-lists` |
| 4 | "Configure VLAN" job template | OPA permits `netadmin` (network-admins); VLAN 200 (DMZ) created on all three switches |
| 5 | Incident response templates (Revoke/Simulate/Restore) | EDA webhook is reachable; credential rotation completes |
| 6 | SSH lockdown layers 1–3 (Firewall, HBAC, Vault Policy) | Break-glass path verified; Layer 4 (Wazuh) is optional — `ignore_errors: true` |

> **Note on Wazuh (Section 6, Layer 4):** The Wazuh VM (`192.168.1.13`) is
> optional infrastructure. Its absence does not affect student exercises.
> `solve-section6.yml` marks the Wazuh tasks `ignore_errors: true` by design.

### Common failure modes and fixes

| Symptom | Likely cause | Fix |
|---|---|---|
| `unknown plugin 'netbox.netbox.nb_inventory'` | Inventory source using default EE | Verify `execution_environment: Netbox` in `solve-section1.yml` |
| `DENIED: user 'admin' is not a member of app-deployers group` | Workflow launched without `requesting_user` override | Verify §2.2 fix is in place; re-run solve-section2 |
| `DENIED: user 'admin' is not a member of network-admins group` | VLAN job launched without `network_user` override | Verify §2.3 fix is in place; re-run solve-section4 |
| `command timeout triggered` on cEOS tasks | Wrong DNAT rules after restart | Run recovery playbook — ceos step (see §4) |
| `{"database": false, "status": "degraded"}` from app health check | Data-plane IPs missing from app/db containers | Run recovery playbook — dataplane step (see §4) |
| Vault `HTTP 503` / `Vault is sealed` | Lab restarted without unseal | Run recovery playbook — vault step (see §4) |

---

## 4. Recovery after restart

Stopping and restarting the lab VMs (whether intentional or via the RHDP
"stop/start" button) drops several runtime states that the initial setup does
not automatically restore. The following playbook handles all of them
idempotently in about 20 seconds when the lab is already healthy (all steps
skip), or performs targeted repairs when something is broken.

### Playbook location

```
/tmp/zta-workshop-aap/setup/recover-after-restart.yml   ← automation repo
setup-automation/recover-after-restart.sh               ← this repo (wrapper)
```

### What it restores

#### Step 1 — Vault unseal (`--tags vault`)

Vault always starts **sealed** after a VM restart (by design). The playbook
queries `/v1/sys/health` (HTTP 503 = sealed) and, if sealed, extracts the
unseal key from `/tmp/setup-scripts/setup-vault-latest.log` and calls
`vault operator unseal`. Skips if Vault is already unsealed (HTTP 200/429).

#### Step 2 — NetBox containers (`--tags netbox`)

The NetBox Docker Compose stack does not auto-start after a VM restart. The
playbook checks `http://localhost:8000/api/status/` (with the NetBox API token)
and if it returns anything other than HTTP 200, runs:

```bash
docker compose -f /tmp/netbox-docker/docker-compose.yml \
  -f /tmp/netbox-docker/docker-compose.override.yml up -d
```

Then waits up to 2 minutes for the API to become healthy.

#### Step 3 — cEOS DNAT rules (`--tags ceos`)

**Root cause:** NETAVARK creates one `iptables` DNAT rule per container network
for each published port (SSH: 2001–2003, eAPI: 6031–6033). After a restart,
duplicate rules accumulate — rules from all four networks (management, net1,
net2, net3) are present simultaneously. SSH and eAPI only listen on the
management interface (`10.89.0.x`). Traffic forwarded to a non-management
rule hits the wrong container IP and the connection times out.

The systemd service `ceos-dnat-fix.service` (installed by `deploy-central.yml`)
is supposed to clean this up at boot, but it can fail when containers restart
after the service runs. The playbook replicates the service logic:

1. For each cEOS container (`ceos1`, `ceos2`, `ceos3`), get the management
   network IP via `podman inspect`.
2. Scan `iptables -t nat -S` for DNAT rules matching each published port.
3. Delete (`iptables -t nat -D`) any rule that does **not** forward to the
   management IP.

Verifies SSH reachability on ports 2001–2003 after cleanup.

#### Step 4 — App/DB data-plane IPs (`--tags dataplane`)

**Root cause:** The `configure-container-networking.yml` playbook adds secondary
IP addresses to the app container (`10.20.0.10/24` on net3) and the DB container
(`10.30.0.10/24` on net2), along with cross-subnet routes through the cEOS
fabric. These are stored as NetworkManager keyfiles but NM does not always
re-apply them cleanly after a restart when Podman networks are also recycling.

This step re-imports `setup/configure-container-networking.yml`, which is
idempotent — it uses `ip addr add` with `failed_when: rc not in [0, 2]` so it
succeeds whether or not the address is already present.

### Running the recovery

**Full recovery (all four steps):**

```bash
# From the central VM
sudo bash /home/rhel/zt-ans-bu-zta-aap/setup-automation/recover-after-restart.sh
```

**Targeted recovery:**

```bash
# Vault only
sudo bash /home/rhel/zt-ans-bu-zta-aap/setup-automation/recover-after-restart.sh --tags vault

# cEOS networking + data-plane only
sudo bash /home/rhel/zt-ans-bu-zta-aap/setup-automation/recover-after-restart.sh --tags ceos,dataplane
```

**Directly via ansible-playbook (from central or control VM):**

```bash
cd /tmp/zta-workshop-aap
ansible-playbook -i inventory/hosts.ini setup/recover-after-restart.yml
```

### Expected output on a healthy lab

All tasks should show `ok` or `skipped`; `changed=0` across all hosts confirms
nothing needed fixing:

```
PLAY RECAP
vault   : ok=3  changed=0  unreachable=0  failed=0  skipped=3
netbox  : ok=3  changed=0  unreachable=0  failed=0  skipped=3
central : ok=4  changed=0  unreachable=0  failed=0  skipped=2
```

---

## Commit reference

### `zt-ans-bu-zta-aap` (`lab-tuning`)

| Commit | Summary |
|---|---|
| `6d427c1` | feat(setup): add recover-after-restart.sh wrapper script |
| `6084235` | fix(gitea): seed from rhpds/lb2864-zta-aap-automation, owner gitea user |
| `f9bc840` | fix(runtime): pre-generate AAP OAuth token in all module transition scripts |
| `aea357c` | fix(setup): complete configure phase — all sections, EDA, AAP 2.6 token fix |
| `69618e7` | fix(setup): fall back to awx.awx symlink when ansible.controller unavailable |
| `9af488e` | fix: install paramiko for arista.eos cEOS SSH connectivity |
| `08bae90` | fix: git pull on retry instead of skipping existing clone directory |
| `8a53f78` | fix(setup): point clone to rhpds/lb2864, create ansible tmp dirs |
| `3911a93` | Update keycloak CA cert |
| `b5f24fd` | fix: Vault KV guard should accept 403, not 200 |
| `c435599` | fix: disable RHSM dnf plugin in containers and correct skip_if_unavailable |

### `lb2864-zta-aap-automation` (`main`)

| Commit | Summary |
|---|---|
| `8913cb8` | feat(setup): add recover-after-restart.yml — post-restart lab recovery |
| `00dd40c` | fix(solve): set network_user=netadmin for Configure VLAN OPA check |
| `0d505c3` | fix(solve): set requesting_user on workflow template, enable ask_variables |
| `9118abb` | fix(solve): pass requesting_user=ztauser for Section 2 workflow launch |
| `8fb4775` | fix(solve): use Netbox EE for inventory source sync |
