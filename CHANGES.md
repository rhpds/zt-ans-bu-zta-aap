# Lab Stability Fixes — ZTA AAP Workshop

**Branch:** `lab-tuning`
**Automation repo:** [`rhpds/lb2864-zta-aap-automation`](https://github.com/rhpds/lb2864-zta-aap-automation) (`main`)
**Authors:** Wilson Harris, with Cursor AI pair-programming
**Testing period:** May 7–9, 2026 across namespaces `sandbox-g6l5l`, `sandbox-jd969`, `sandbox-zl87n`,
`sandbox-97jqx`, `sandbox-2sw94` on the RHDP development cluster

---

## Table of Contents

1. [How to read this document](#1-how-to-read-this-document)
2. [Pre-lab: setup-automation fixes](#2-pre-lab-setup-automation-fixes)
3. [Section 1 — ZTA Infrastructure Verification](#3-section-1)
4. [Section 2 — Deploy Application with Short-Lived Credentials](#4-section-2)
5. [Section 3 — AAP Policy as Code](#5-section-3)
6. [Section 4 — SPIFFE-Verified Network Management](#6-section-4)
7. [Section 5 — Automated Incident Response](#7-section-5)
8. [Section 6 — SSH Lockdown & Break-Glass](#8-section-6)
9. [Cross-cutting: automation repo fixes (nmartins0611 → rhpds)](#9-cross-cutting-automation-repo-fixes)
10. [Testing: solve-and-validate walkthrough](#10-testing-solve-and-validate)
11. [Recovery: restoring lab state after a restart](#11-recovery-after-restart)
12. [Commit reference](#12-commit-reference)

---

## 1. How to read this document

Each section below describes:

- **What the instructions say** — the intended student experience
- **What was observed** — what actually happened during live testing
- **Root cause** — why it happened
- **Fix** — what was changed in the automation repo or showroom scripts

Fixes in **`zt-ans-bu-zta-aap`** (`lab-tuning`) are in the showroom setup scripts.
Fixes in **`lb2864-zta-aap-automation`** (`main`) are in AAP playbook content.

---

## 2. Pre-lab: setup-automation fixes

These are environmental issues that prevented the lab from reaching a working
initial state. They apply to all sections.

### 2.1 Clone source, personal fork

**Files:** `setup-automation/setup-central.sh`, `setup-automation/setup-control.sh`,
`config/instances.yaml`
**Commits:** `8a53f78`, `6084235`

**Observed:** On every fresh deployment both VMs were cloning
`nmartins0611/zta-workshop-aap` (`zta-container` branch).

I changed this to an internal rhdps repo at http://gitea:3000/gitea/zta-workshop-aap for tuning purposes.
The changes made are explained later in this doc.

**Fix:**
- `setup-central.sh` and `setup-control.sh`: clone from
  `https://github.com/rhpds/lb2864-zta-aap-automation.git` (`main`)
- `config/instances.yaml`: seed Gitea from the same source with `owner: gitea`
  so the internal URL (`http://gitea:3000/gitea/zta-workshop-aap`) matches what
  `configure-aap-project.yml` and `validation_vars.yml` expect

### 2.2 `git pull` on retry instead of skipping

**File:** `setup-automation/setup-central.sh`
**Commit:** `08bae90`

**Observed:** When a setup step was interrupted and re-run, the script skipped
the clone because the target directory already existed, reusing potentially
stale or partial content.

**Fix:** Run `git pull` on retry so interrupted provisioning always picks up the
latest content.

### 2.3 `paramiko` not installed — Arista tasks fail at connection time

**File:** `setup-automation/setup-central.sh`
**Commit:** `9af488e`

**Observed:** All Arista/cEOS tasks failed with `No module named paramiko`.
`arista.eos` uses `paramiko` for SSH transport to containers.

**Fix:** Added `pip3 install paramiko --user` to the central node setup.

### 2.4 `ansible.controller` collection fallback when Automation Hub unreachable

**File:** `setup-automation/setup-central.sh`
**Commit:** `69618e7`

**Observed:** On environments where the Automation Hub token was expired or Hub
was unreachable, `ansible.controller` silently failed to install and all setup
playbooks failed with `ansible.controller is not a valid attribute`.

**Root cause:** `ansible.controller` is distributed from Automation Hub, not
Galaxy. Token expiry is a common event-lab condition.

**Fix:** Post-install guard — if `ansible.controller` is absent, create a
namespace symlink from `ansible/controller` → `awx/awx`. `awx.awx` is always
installed from Galaxy and defines the same modules and action groups. The symlink
satisfies both FQCN lookups and `module_defaults` group resolution.

### 2.5 AAP 2.6 OAuth token — sections 2–5 never appeared for students

**Files:** `setup-automation/setup-control-configure.sh`,
`runtime-automation/module-02` through `module-05/setup-central.sh`
**Commits:** `aea357c`, `f9bc840`, `96414ef`

**Observed:** Students advancing from module 1 to module 2, 3, 4, or 5 never saw
new job templates appear in AAP. The module transition scripts ran (visible in
showroom logs) but left AAP unchanged.

**Root cause:** `awx.awx:24.6.1` generates internal tokens by calling
`/api/v2/tokens/`. On AAP 2.6 Gateway deployments that endpoint returns 404. The
collection silently falls back to password auth on some calls and fails entirely
on others, leaving module transitions broken without a visible error.

**Fix:** Each script that calls `configure-aap-project.yml` now:
1. Pre-generates a token via `POST /api/controller/v2/tokens/`
2. Passes it as `controller_oauthtoken` extra-var
3. `configure-aap-project.yml` accepts this in `module_defaults` and bypasses the
   internal token generation path entirely

Also added a 60-attempt polling loop on `/api/controller/v2/ping/` in
`setup-control-configure.sh` before running any configure playbooks.

### 2.6 Only section 1 templates created at initial deploy

**File:** `setup-automation/setup-control-configure.sh`
**Commits:** `aea357c`, `914fc01`

**Observed (and corrected):** An intermediate change incorrectly pre-created all
sections (1–6) at initial deployment, which would have shown students all
templates upfront and broken the progressive reveal design.

**Correct behaviour:** Initial deployment creates section 1 templates only.
Module transitions (02–05) remove the previous section's templates and add the
next section's as students advance. EDA infrastructure is still created upfront
because the event stream URL must be wired into Splunk before module 05.

### 2.7 Vault KV guard accepted only HTTP 200

**File:** `setup-automation/setup-central.sh` (via embedded `8aed583` squash)

**Observed:** Vault readiness check looped indefinitely even when Vault was
healthy and the KV mount existed.

**Root cause:** An unauthenticated check on `sys/internal/ui/mounts/secret`
returns 403 (mount exists, caller unauthenticated) — the valid "ready" state.
The guard was checking for 200 only.

**Fix:** Accept both 200 and 403 as the ready signal; retry only on 404.

### 2.8 RHSM dnf plugin regenerating `redhat.repo` inside containers

**File:** `setup-automation/setup-central.sh` (via `c435599`, `b94824a` squash)

**Observed:** `deploy-db-app.yml` failed because package installs inside the app
and db containers tried to reach RHSM repos that don't exist in the lab network.

**Root cause:** The subscription-manager dnf plugin (enabled by default) was
regenerating `/etc/yum.repos.d/redhat.repo` at every `dnf` invocation, undoing
the repo cleanup that ran before container deployment.

**Fix:** Disable the plugin inside containers:
```bash
sed -i "s/^enabled=1/enabled=0/" /etc/dnf/plugins/subscription-manager.conf
sed -i "s/^skip_if_unavailable=.*/skip_if_unavailable=True/" /etc/dnf/dnf.conf
```

### 2.9 SPIRE agent using deprecated join_token attestation

**File:** `setup/deploy-spire.yml` (via `8aed583` squash)

**Observed:** SPIRE SVIDs expired after 5 hours (the join_token TTL). Labs run
for a full day at events — SVIDs would expire mid-session and SPIFFE-gated
playbooks would fail.

**Root cause:** `join_token` attestation is time-limited. The original
configuration did not set `x509pop` attestation which issues long-lived
renewable SVIDs.

**Fix:** Replaced `join_token` with `x509pop` node attestation; corrected agent
SPIFFE ID prefix; added `keyUsage` extensions to the issued certificates.

---

## 3. Section 1

**What the instructions say:** Students connect to AAP using `ztauser` credentials,
create an AAP project pointing to the Gitea repository, create a dynamic inventory
backed by NetBox, add an inventory source using the `netbox_inventory.yml` file
from the project, and run four verification job templates (Verify ZTA Services,
Test Vault Integration, Test Vault SSH Certificates, Test OPA Policy).

**What was observed:** Initial lab deployment (after §2 fixes) left the project,
inventory, and job templates correctly pre-created. Students could log in and run
the verification templates without issues.

**`ztauser` workflow creation permissions:**
During manual testing, `ztauser` could not create a workflow job template in the
AAP UI. This is expected — the instructions for Section 2 specify that `ztauser`
builds the pipeline; the RBAC fix (§4 of the cross-cutting fixes) grants the
Applications team `admin` on their own templates but workflow creation requires
org-level permissions that only `admin` has. The instructions guide students to
use the `admin` account for workflow creation.

**Automation fix:**
- **Solve script** (`solve-section1.yml`): The inventory source creation task
  must specify `execution_environment: Netbox`. The default EE lacks the
  `netbox.netbox` collection, causing the inventory sync to fail with
  `unknown plugin 'netbox.netbox.nb_inventory'`. Commit: `8fb4775`

---

## 4. Section 2

**What the instructions say:** Students create five job templates (Check DB Access
Policy, Create DB Credential, Configure DB Access List, Deploy Application, Rotate
DB Credentials), assemble them into a "Deploy Application Pipeline" workflow with
OPA → Vault → ACL → Deploy success chain, and launch it to deploy the Global
Telemetry Platform. The pipeline enforces OPA policy, generates short-lived Vault
DB credentials (default TTL: 5 minutes so students can watch it expire), applies
an Arista ACL for micro-segmentation, and deploys the app container. Students are
instructed to then increase the TTL to 30 minutes.

**What was observed:**

1. **`ztauser` couldn't see or edit workflow templates** — reported during manual
   walkthrough. Root cause: the Applications team had no RBAC grant on the
   "Deploy Application Pipeline" workflow object. The `ignore_errors` guard
   (commit `6d1ce40`) ensures setup doesn't fail at provision time, and
   solve-section2 re-applies RBAC after the workflow is created.

2. **OPA denied `admin` user** — when the solve script launched the workflow as
   the AAP `admin` user, `check-db-policy.yml` evaluated `awx_user_name` (=
   `admin`) against OPA and received `DENIED: user 'admin' is not a member of
   app-deployers group`. This was correct OPA behaviour but broke the automated
   solve.

3. **Application health returned `{"database": false, "status": "degraded"}`**
   — after a lab VM restart, the data-plane secondary IPs (`10.20.0.10` app,
   `10.30.0.10` db) were absent from the containers. The app could not reach the
   db across the cEOS fabric. See §11 (recovery) for the root cause.

4. **`check-db-policy.yml` broken playbook exercise** — the instructions include
   a coding exercise where students write OPA query and IdM lookup tasks. The
   broken version (`deploy-application-broken.yml`) was verified to have the
   correct hints in the lab instructions.

**Automation fixes:**
- **Solve script** (`solve-section2.yml`): Set `extra_vars: {requesting_user: ztauser}`
  and `ask_variables_on_launch: true` on both the workflow template definition
  and the launch task. This ensures OPA evaluates an authorized user (`ztauser`
  is in `app-deployers`) regardless of which AAP user runs the solve.
  Commits: `9118abb`, `0d505c3`
- **`configure-aap-project.yml`**: `ignore_errors: true` on workflow RBAC grants
  so provision doesn't fail when the workflow doesn't exist yet. Commit: `6d1ce40`
- **`create-db-credential.yml`** (BF-1): Support `vault_db_default_ttl` as an
  extra-var so the TTL is configurable at launch time (5m for the initial
  exercise, 30m after the student increases it).
- **`configure-aap-project.yml`** (BF-1b): The "Deploy Application Pipeline"
  workflow is intentionally NOT pre-created during provisioning — students build
  it themselves. A `workflow-precreate` tag exists for instructor use only. The
  solve script always creates the workflow with `vault_db_default_ttl: 30m`.
- **`configure-db-access.yml`**: The Arista ACL command used in check scripts
  was corrected from `show access-lists` to `show ip access-lists` (cEOS
  requirement). Commit: `d4acc5f`

---

## 5. Section 3

**What the instructions say:** Students experience AAP Policy as Code — a Gateway
policy that gates job execution against OPA. The `neteng` user attempts to run
"Apply Security Patch" and is denied by the policy. Students then configure the
policy via the AAP settings API and verify it allows the appropriate team.
Section 3B covers OPA data classification policy — students introduce a break
and fix it by updating OPA policy content.

**What was observed:**

1. **AAP Policy as Code OPA field** — the Gateway policy settings use
   `opa_query_path`, not `policy_enforcement`, in AAP 2.6. The check script was
   querying the wrong field. Corrected in validation checks.

2. **`neteng` permissions** — early in testing it was unclear whether `neteng`
   should have `admin` or reduced permissions when the module-03 transition runs.
   The module-03 transition script moves `neteng` from `team-infrastructure` to
   `team-readonly` in IdM — this is an intentional Section 3 design constraint
   (neteng can see templates but the Gateway policy denies their launches).

3. **`auditctl -l` check failed in containers** — the validation check for audit
   rules used `auditctl -l` which is not available in rootless Podman containers.
   Replaced with a file existence check.

**Automation fixes:**
- **`configure-idm-users.yml`** / **`configure-keycloak.yml`**: Added missing
  initial `neteng → team-infrastructure` group membership so the module-03
  transition (which removes neteng from infrastructure) has something to remove.
  Commit: `d4acc5f`
- **`solve-section3.yml`** / check script: Corrected OPA query path for AAP 2.6
  and auditctl fallback. Commit: `685759c`
- **`apply-security-patch.yml`** (BF-OPA): OPA policies updated with permissive
  defaults so a misconfigured OPA does not block all policy decisions on fresh
  deployments. Included in `8aed583` squash.

---

## 6. Section 4

**What the instructions say:** Students create a "Configure VLAN" job template
with a survey (VLAN ID, VLAN Name) and run it to create VLAN 200 (DMZ) across
all three cEOS switches. The playbook uses SPIFFE workload identity (SVID) to
authenticate to the switches and enforces two OPA policy rings — one for network
user authorization, one for SPIFFE trust verification. Students also manage IdM
identities and verify SPIFFE trust.

**What was observed:**

1. **OPA denied `admin` user** — same pattern as Section 2. `configure-vlan.yml`
   uses `network_user: "{{ awx_user_name | default('neteng') }}"`. When the AAP
   `admin` account launches the job, OPA receives `admin` and denies with
   `DENIED: user 'admin' is not a member of network-admins group`.

2. **SSH timeout to cEOS switches** — after a lab restart, SSH connections to
   cEOS ports 2001–2003 timed out. NETAVARK had accumulated duplicate DNAT rules
   pointing to wrong container IPs. See §11 (recovery) for details.

3. **SPIRE SVID expiry** — on labs that ran for more than 5 hours before students
   reached Section 4, the SPIFFE SVIDs had expired under the old `join_token`
   attestation. Fixed by §2.9 above.

**Automation fixes:**
- **Solve script** (`solve-section4.yml`): Set `extra_vars: {network_user: netadmin}`
  on both the template definition and the launch task. `netadmin` is in the
  `network-admins` IdM group so OPA permits the request. Commit: `00dd40c`
- **`configure-vlan.yml`**: No change to the playbook itself — the fix is in how
  the solve script passes the authorized user at launch time.

---

## 7. Section 5

**What the instructions say:** Students configure an EDA rulebook activation that
listens to a Splunk webhook. When a Splunk saved search detects an SSH brute-force
event, it fires the webhook, EDA triggers "Emergency: Revoke App Credentials",
Vault revokes the DB credentials, and the application goes offline. Students then
run "Restore App Credentials" to issue new credentials and bring the app back up.
A 10-minute alert suppression prevents the revoke loop from firing continuously.

**What was observed:**

1. **Splunk saved search missing on fresh deploy** — `deploy-splunk.yml` wrote
   `savedsearches.conf` to the host volume but never triggered a reload. Splunk
   never saw the new search. Additionally, `configure-splunk-eda.yml` was POSTing
   to the instance update URL assuming the saved search already existed (404 on
   fresh deployments). Commits: `42e7a5f`, `24ffc91`

2. **EDA webhook configuration** — the Splunk EDA addon requires a `url` field,
   not `webhook_url`, in the stanza configuration. The check script was testing
   the wrong field. Commit: `685759c`

3. **EDA event stream URL** — the EDA API path uses `event-streams` (hyphen), not
   `event_streams` (underscore). The check script was building the wrong URL.
   Commit: `685759c`

4. **Infinite revoke loop** — before the 10-minute alert suppression was in place,
   every Splunk search execution (every 1 minute) triggered a new revoke. The
   credentials were re-revoked repeatedly. BF-9e (commit `8aed583` squash) added
   `suppression_period = 600` to the saved search.

5. **Post-restore credential verification** — after "Restore App Credentials" ran,
   validation checks re-verified Vault leases. The restored credentials are new
   leases with new IDs — this is expected behaviour (a credential rotation, not a
   replay). The check script was updated to accept any active lease, not the
   original lease ID.

6. **Splunk password variable** — `deploy-splunk.yml` referenced
   `splunk_admin_password` (undefined) instead of `splunk_password`. This caused
   the module-01 Cisco data model acceleration task to fail silently.
   Commit: `8416b57`

**Automation fixes:**
- **`deploy-splunk.yml`**: Write `savedsearches.conf` then call
  `saved/searches/_reload`. Fix variable name `splunk_password`.
- **`configure-splunk-eda.yml`**: GET-check before POST for saved search; use
  `servicesNS/admin/search` app context; correct field names.
- **`configure-aap-project.yml`** (BF-3): EDA event stream and activation
  creation decoupled behind `eda_activation` tag so instructors can skip
  activation on environment resets without recreating the stream.
- **`revoke-app-credentials.yml`** (BF-4): Fix `add_host` cross-play variable
  sharing so `db_host` is available to the revocation play.
- **`restore-app-credentials.yml`** (BF-4b): Use `state: restarted` for the
  `ztaapp` service so it picks up the new credentials even if it was already
  running.

---

## 8. Section 6

**What the instructions say:** Students apply four SSH lockdown layers to the
app and db servers:
1. **Firewall** — restrict SSH source IPs using `firewall-cmd` rich rules
2. **IdM HBAC** — restrict which users can SSH using host-based access control
3. **Vault policy** — restrict SSH certificate signing to AppRole (not userpass)
4. **Wazuh bypass detection** — alert on SSH bypass attempts (optional)

Then verify the break-glass path: `aap-service` and `ztauser` can SSH, `neteng`
cannot.

**What was observed:**

1. **Firewall layer in containers** — `firewall-cmd` is not available in the
   rootless Podman app/db containers. The lockdown playbook was failing hard.

2. **HBAC check logic** — the validation check was matching partial strings
   instead of exact `Access granted: True/False` from `ipa hbactest` output.

3. **Wazuh VM absent** — in sandbox environments the Wazuh VM is optional
   infrastructure. Layer 4 correctly uses `ignore_errors: true` by design.

**Automation fixes:**
- **`lockdown-firewall.yml`**: Scoped to `app_servers:db_servers` (not
  `idm_clients`); added a container-compatible fallback using `sshd_config`
  `Match Address` block when `firewalld` is not available.
- **Check scripts**: Fixed HBAC exact match logic; added `sshd_config`
  ZTA lockdown verification as fallback alongside `firewall-cmd`. Commit: `685759c`

---

## 9. Cross-cutting automation repo fixes

These fixes in `lb2864-zta-aap-automation` apply across multiple sections and
represent the full delta from the original `nmartins0611/zta-workshop-aap` repo.

| Fix | Commit | Affected area |
|---|---|---|
| `vault_db_default_ttl` extra-var support | BF-1 (squash) | Section 2 — Vault credential TTL |
| Pre-create workflow with 30m Vault TTL (instructor-only tag) | BF-1b (squash) | Section 2 — Workflow bootstrap |
| `limits.conf` + disable Cisco data model acceleration in Splunk | BF-2 (squash) | Section 5 — Splunk startup |
| EDA event stream + activation (`eda_activation` tag) | BF-3 (squash) | Section 5 — EDA bootstrap |
| `add_host` cross-play var sharing in `restore-app-credentials.yml` | BF-4 (squash) | Section 5 — Credential restore |
| `state: restarted` for ztaapp service | BF-4b (squash) | Section 5 — App restart |
| Fix recursive `aap_controller_ip` in `configure-splunk-eda.yml` | BF-5 (squash) | Section 5 — Splunk/EDA integration |
| Fix Go template string escaping in `deploy-central.yml` | BF-6 / `a38ab6f` | Central deployment |
| Add `containers.podman` to collection install loop | BF-7 (squash) | Container deployment |
| Splunk filesystem conf endpoint; add "Failed password" query | BF-9 (squash) | Section 5 — Splunk search |
| 10-min alert suppression for brute-force saved search | BF-9e (squash) | Section 5 — EDA loop prevention |
| Disable `update_on_launch` on NetBox inventory source | OPT-INV (squash) | Section 1 — Inventory |
| Use `gitea:3000` internal service hostname | `8aed583` squash | All sections — SCM |
| SPIRE x509pop attestation; correct SPIFFE ID prefix | `8aed583` squash | Section 4 — SPIFFE/SVIDs |
| `controller_oauthtoken` in `module_defaults` | `96414ef` | All sections — AAP 2.6 compat |
| 20 targeted validation checks across all sections | `72c0d2c` | Solve/validate suite |
| Section 2 validation bug fixes; workflow RBAC | `d4acc5f` | Section 2 — Validation |
| Splunk password variable fix | `8416b57` | Section 5 — Splunk deploy |
| Section 3/5/6 check fixes; firewall container fallback | `685759c` | Sections 3, 5, 6 |
| EDA project pointed to `rhpds/lb2864-zta-aap-automation` | `1265263` | Section 5 — EDA |
| Force-patch project `scm_branch` to `main` | `3bfcc70`, `d988e25` | All sections — SCM |
| `ignore_errors` on workflow RBAC grants | `6d1ce40` | Section 2 — RBAC |
| Basic auth in force-patch URI task | `c656e9c` | All sections — SCM |
| Splunk saved search: GET-check, correct app context | `42e7a5f`, `24ffc91` | Section 5 — Splunk |
| NetBox EE for inventory source | `8fb4775` | Section 1 — Inventory |
| `requesting_user=ztauser` for Section 2 OPA | `9118abb`, `0d505c3` | Section 2 — OPA |
| `network_user=netadmin` for Section 4 OPA | `00dd40c` | Section 4 — OPA |
| Post-restart recovery playbook | `8913cb8` | All sections — Operations |

---

## 10. Testing: solve-and-validate walkthrough

After a fresh deployment completes, run the full end-to-end validation from the
**central VM** to confirm every section works.

### Prerequisites

- SSH to central via showroom bastion (`ssh rhel@192.168.1.11`) or
  `oc exec -it <showroom-pod> -- ssh rhel@central.zta.lab`
- The automation repo must be present at `/tmp/zta-workshop-aap`

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

| Section | What solve creates | Key validation |
|---|---|---|
| 1 | AAP Project, Inventory (NetBox source), 4 templates | Inventory sync with `Netbox` EE; all services reachable |
| 2 | 5 templates + "Deploy Application Pipeline" workflow | OPA permits `ztauser`; app health returns `{"status":"ok"}` |
| 3 | "Apply Security Patch" template with survey | Patch applies to app; OPA policy gating correct |
| 4 | "Configure VLAN" template; VLAN 200 (DMZ) created | OPA permits `netadmin`; VLAN on all three switches |
| 5 | 3 templates (Revoke, Simulate, Restore); EDA webhook | EDA event stream present; Splunk saved search exists |
| 6 | 4 SSH lockdown layers applied | HBAC: `aap-service`/`ztauser` permitted, `neteng` denied |

> **Note on Wazuh (Section 6, Layer 4):** Wazuh VM is optional infrastructure.
> Absence does not affect student exercises. `solve-section6.yml` marks Layer 4
> `ignore_errors: true` by design.

### Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `unknown plugin 'netbox.netbox.nb_inventory'` | Inventory source using default EE | Verify `execution_environment: Netbox` in solve-section1.yml |
| `DENIED: user 'admin' is not a member of app-deployers` | Section 2 workflow launched without `requesting_user` | Verify `extra_vars: {requesting_user: ztauser}` in solve-section2.yml |
| `DENIED: user 'admin' is not a member of network-admins` | VLAN job launched without `network_user` | Verify `extra_vars: {network_user: netadmin}` in solve-section4.yml |
| SSH timeout on cEOS tasks | Bad DNAT rules after restart | Run recovery playbook — `--tags ceos` |
| `{"database": false, "status": "degraded"}` | Data-plane IPs missing from containers | Run recovery playbook — `--tags dataplane` |
| Vault HTTP 503 / sealed | Lab restarted | Run recovery playbook — `--tags vault` |
| Module 2–5 templates never appear | AAP 2.6 OAuth token issue | Verify `f9bc840` is in the setup scripts |

---

## 11. Recovery after restart

Stopping and restarting the lab VMs drops four runtime states not automatically
restored. The following playbook handles all of them idempotently.

### Playbook location

```
/tmp/zta-workshop-aap/setup/recover-after-restart.yml   ← automation repo
setup-automation/recover-after-restart.sh               ← this repo (wrapper)
```

### What it restores

#### Step 1 — Vault unseal (`--tags vault`)

Vault always starts **sealed** after a VM restart. The playbook queries
`/v1/sys/health` and if sealed (HTTP 503), extracts the unseal key from
`/tmp/setup-scripts/setup-vault-latest.log` and runs `vault operator unseal`.
Skips if already unsealed (HTTP 200/429).

**Impact if not restored:** Section 1 "Test Vault Integration" fails. All
sections that rely on Vault dynamic credentials fail.

#### Step 2 — NetBox containers (`--tags netbox`)

The NetBox Docker Compose stack does not auto-start after VM restart. The
playbook checks `http://localhost:8000/api/status/` (with the NetBox API token)
and if unhealthy, runs `docker compose up -d` for `/tmp/netbox-docker`, then
waits up to 2 minutes.

**Impact if not restored:** Section 1 inventory sync fails. NetBox CMDB data
unavailable.

#### Step 3 — cEOS DNAT rules (`--tags ceos`)

**Root cause:** NETAVARK creates one `iptables` DNAT rule per container network
for each published SSH/eAPI port. After a restart, rules from all four container
networks (management, net1, net2, net3) accumulate simultaneously. SSH and eAPI
only listen on the management interface (`10.89.0.x`). Traffic hitting a
non-management DNAT rule is forwarded to the wrong IP and the connection times
out.

`ceos-dnat-fix.service` (installed by `deploy-central.yml`) is supposed to clean
this on boot, but fails when containers restart after the service runs.

The playbook replicates the service logic: for each cEOS container, get the
management network IP via `podman inspect`, then delete any DNAT rule that does
not forward to that management IP.

**Impact if not restored:** Section 2 "Configure DB Access List" and Section 4
"Configure VLAN" time out with SSH connection errors to cEOS ports 2001–2003.

#### Step 4 — App/DB data-plane IPs (`--tags dataplane`)

**Root cause:** `configure-container-networking.yml` adds secondary IPs
(`10.20.0.10/24` on app, `10.30.0.10/24` on db) and cross-subnet routes via
the cEOS fabric. These are stored as NetworkManager keyfiles but NM does not
always re-apply them when Podman networks recycle after a restart.

The playbook re-imports `configure-container-networking.yml` (idempotent).

**Impact if not restored:** Section 2 "Deploy Application" returns
`{"database": false, "status": "degraded"}`. The app and db containers cannot
communicate across the simulated network fabric.

### Running recovery

```bash
# Full recovery — all four steps (~20s on healthy lab)
sudo bash /home/rhel/zt-ans-bu-zta-aap/setup-automation/recover-after-restart.sh

# Targeted
sudo bash /home/rhel/zt-ans-bu-zta-aap/setup-automation/recover-after-restart.sh --tags vault
sudo bash /home/rhel/zt-ans-bu-zta-aap/setup-automation/recover-after-restart.sh --tags ceos,dataplane
```

### Expected output on a healthy lab

```
PLAY RECAP
vault   : ok=3  changed=0  unreachable=0  failed=0  skipped=3
netbox  : ok=3  changed=0  unreachable=0  failed=0  skipped=3
central : ok=4  changed=0  unreachable=0  failed=0  skipped=2
```

---

## 12. Commit reference

### `zt-ans-bu-zta-aap` (`lab-tuning`)

| Commit | Summary |
|---|---|
| `40b36ce` | docs(CHANGES): correct section-1-only description in configure phase entry |
| `914fc01` | fix(setup): revert to section1-only on initial configure — preserve lab progression |
| `0ef2cb5` | docs: add CHANGES.md — lab stability fixes and recovery guide |
| `6d427c1` | feat(setup): add recover-after-restart.sh wrapper script |
| `6084235` | fix(gitea): seed from rhpds/lb2864-zta-aap-automation, owner gitea user |
| `f9bc840` | fix(runtime): pre-generate AAP OAuth token in all module transition scripts |
| `aea357c` | fix(setup): AAP readiness wait and AAP 2.6 token in configure phase |
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
| `8913cb8` | feat(setup): add recover-after-restart.yml |
| `00dd40c` | fix(solve): set network_user=netadmin for Section 4 OPA |
| `0d505c3` | fix(solve): set requesting_user on workflow template, enable ask_variables |
| `9118abb` | fix(solve): pass requesting_user=ztauser for Section 2 workflow launch |
| `8fb4775` | fix(solve): use Netbox EE for inventory source sync |
| `24ffc91` | fix(splunk): create saved search if missing, use search app context |
| `42e7a5f` | fix(splunk): create saved search if missing, reload conf after write |
| `c656e9c` | fix(project): use basic auth in force-patch scm_branch uri task |
| `6d1ce40` | fix(rbac): ignore_errors on Deploy Application Pipeline workflow grants |
| `d988e25` | fix(project): force-patch scm_branch to main after project create |
| `3bfcc70` | fix(project): set controller project scm_branch to main |
| `1265263` | fix(eda): point EDA project to rhpds/lb2864-zta-aap-automation main |
| `685759c` | fix(validation): correct check and lockdown playbooks for Sections 3, 5, 6 |
| `d4acc5f` | Fix Section 2 validation bugs and add workflow RBAC to setup |
| `8416b57` | fix(splunk): use consistent splunk_password var in deploy-splunk.yml |
| `96414ef` | fix(aap): accept controller_oauthtoken in module_defaults |
| `72c0d2c` | feat(validation): add 20 targeted checks across all 5 sections |
| `8aed583` | fix: apply all lab-init fixes to main for fresh deployment readiness |
| `c262ca6` | chore: initial ZTA workshop automation content (BF-1 through BF-11) |
