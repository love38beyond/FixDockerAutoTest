# Docker Test Environment Setup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automate the creation of a 3-container Docker test environment (Exchange → CTP Trade → FIX Gateway) via shell scripts, replacing manual steps in `docker-fix.txt`.

**Architecture:** A main orchestration script (`env_setup.sh`) coordinates three per-container setup scripts. Each container runs on a shared Docker bridge network. Scripts auto-detect the host IP, use `docker exec` for internal config, and handle interactive prompts via `expect`/heredoc patterns. All config file templates are sourced from `fileExample/`.

**Tech Stack:** Bash 4.x, Docker CLI, `expect` (for interactive prompts automation), `sed` for IP replacement.

## Global Constraints

- Target OS: Linux (Docker host), scripts written for `bash`
- Docker must be pre-installed and running
- Docker images (`exchangeFIX.tar`, `CtpTradeFIX.tar`, `FIX.tar`) must exist in the script working directory
- Host machine must have `expect` installed (`yum install -y expect` / `apt-get install -y expect`)
- Scripts must be idempotent — safe to re-run (check for existing containers/images before creating)
- All scripts use `set -euo pipefail` for error handling
- Container startup order enforced: Exchange → CTP Trade → FIX Gateway

---

## File Structure

```
scripts/
├── env_setup.sh              # Main orchestrator — call this to set up everything
├── common.sh                 # Shared: IP detection, logging, idempotency helpers
├── setup_exchange.sh         # Container 1: Exchange (exchangefix)
├── setup_ctptrade.sh         # Container 2: CTP Trade (ctptradefix)
├── setup_fixgateway.sh       # Container 3: FIX Gateway (ctpfix)
└── cleanup.sh                # Tear down all containers (for reset)
```

### File Responsibilities

| File | Responsibility |
|------|---------------|
| `common.sh` | Sourced by all scripts. Defines: `detect_host_ip()`, `log_info()`, `log_error()`, `container_exists()`, `image_exists()`, `HOST_IP` variable, `DOCKER_NETWORK` name (`fix-test-net`), color-coded output helpers |
| `env_setup.sh` | Entry point. Parses CLI args, checks prerequisites (docker, expect, tar files), creates Docker bridge network, calls 3 setup scripts sequentially, prints summary |
| `setup_exchange.sh` | Imports `exchangeFIX.tar` → image `exchangefix:v1`, creates/runs exchangefix container, configures SSH keys, `setcap` for ping, modifies `service.list` and `DeployConfig.xml` IPs, starts exchange services |
| `setup_ctptrade.sh` | Imports `CtpTradeFIX.tar` → image `ctptradefix:v2`, creates/runs ctptradefix container, configures SSH, modifies `/etc/hosts`, updates 4 offer/mdserver INI files with host IP, modifies DeployConfig.xml multicast, starts CTP services |
| `setup_fixgateway.sh` | Imports `FIX.tar` → image `ctpfix:v1`, creates/runs ctpfix container, `setcap` for ping, updates `fixfront_mt.ini` and `fixfront_md.ini` with host IP, starts FIX gateway services |
| `cleanup.sh` | Stops and removes all 3 containers, removes the Docker network, optionally removes images. Safe to run anytime. |

---

## Container Dependency & Communication Model

```
[FIX Gateway (ctpfix)] --tcp:61111--> [FIX Initiator (FixAutoTest)]
       |
       | tcp://<HOST_IP>:11157 (trade)
       | tcp://<HOST_IP>:11167 (market data)
       v
[CTP Trade (ctptradefix)] --tcp--> [Exchange (exchangefix)]
       |                               |
       | tcp://<HOST_IP>:26181 (offer) |
       | tcp://<HOST_IP>:26171 (md)    |
       +------------------------------>+
```

All inter-container communication goes through the Docker host IP with published ports.

---

## Key Design Decisions

### 1. Host IP Detection Strategy
```bash
# In common.sh — pick the primary non-loopback IPv4 address
HOST_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
# Fallback: if no scope global, try the docker bridge default route
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(ip route get 1 | awk '{print $7; exit}')
fi
```

### 2. Interactive Prompt Handling
Several steps require user input (ssh-keygen prompts, confirmMainBackup.sh, startall.sh menu). Two strategies:

**Strategy A (preferred):** Pipe input via heredoc/echo for simple cases:
```bash
# ssh-keygen: pass empty input (all defaults) and 'y' for overwrite
echo -e "\n\n\n\n" | ssh-keygen -t rsa 2>/dev/null || true
# Or: ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa  (non-interactive flags)
```

**Strategy B:** Use `expect` for more complex prompts:
```expect
spawn ssh-keygen -t rsa
expect "Enter file" { send "\r" }
expect "Enter passphrase" { send "\r" }
expect "Enter same passphrase" { send "\r" }
expect "Overwrite" { send "y\r" }
```

### 3. Idempotency Pattern
Each setup script checks for existing state before acting:
```bash
if docker container inspect exchangefix &>/dev/null; then
    log_info "Container exchangefix already exists, skipping creation"
else
    # create container
fi
```

### 4. Config File Modification
Use `sed` for IP replacement inside containers via `docker exec`:
```bash
# Pattern: replace specific old IP with current HOST_IP
docker exec <container> sed -i "s/172\.24\.120\.132/${HOST_IP}/g" <file_path>
```

### 5. File References from fileExample/
The mapping from `fileExample/` templates to container paths:

| Template File | Container | Target Path Inside Container |
|--------------|-----------|------------------------------|
| `DeployConfig.PD.all.all.xml` | exchangefix | `~/cfg/config/DeployConfig.xml` |
| `DeployConfig.xml` | ctptradefix | `/home/trade1/cfg/config/DeployConfig.xml` |
| `service.list` | exchangefix | `~/shell/console/service.list` |
| `hosts` | ctptradefix | `/etc/hosts` (appended content) |
| `ineoffer.ini` | ctptradefix | `~/ineoffer2/bin/ineoffer.ini` |
| `inemdserver.ini` | ctptradefix | `~/inemdserver2/bin/inemdserver.ini` |
| `shfeoffer.ini` | ctptradefix | `~/shfeoffer1/bin/shfeoffer.ini` |
| `shfemdserver.ini` | ctptradefix | `~/shfemdserver1/bin/shfemdserver.ini` |
| `fixfront_mt.ini` | ctpfix | `/home/fixf1/fixfront_mt1/bin/fixfront_mt.ini` |
| `fixfront_md.ini` | ctpfix | `/home/fixf1/fixfront_md1/bin/fixfront_md.ini` |

---

## Task Breakdown

### Task 1: Create `scripts/common.sh` — Shared Utilities

**Files:**
- Create: `scripts/common.sh`

**Interfaces:**
- Produces: `HOST_IP` (global var), `DOCKER_NETWORK="fix-test-net"`, functions: `log_info(msg)`, `log_error(msg)`, `log_success(msg)`, `log_step(msg)`, `container_exists(name) → bool`, `image_exists(name) → bool`, `detect_host_ip() → string`

**Steps:**

- [ ] **Step 1: Create the file**

```bash
#!/usr/bin/env bash
# common.sh — Shared utilities for Docker test environment setup
set -euo pipefail

# --- Color output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Docker network ---
DOCKER_NETWORK="fix-test-net"

# --- Global: host IP (detected at source time) ---
HOST_IP=""

# --- Logging functions ---
log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "${YELLOW}[STEP]${NC}  $(date '+%H:%M:%S') $*"; }

# --- Detect host IP ---
detect_host_ip() {
    # Try primary global-scope IPv4 first
    HOST_IP=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    # Fallback: use default route interface
    if [ -z "$HOST_IP" ]; then
        HOST_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    fi
    if [ -z "$HOST_IP" ]; then
        log_error "Cannot detect host IP address"
        exit 1
    fi
    log_info "Detected host IP: $HOST_IP"
}

# --- Docker helpers ---
container_exists() {
    docker container inspect "$1" &>/dev/null
}

image_exists() {
    docker image inspect "$1" &>/dev/null
}

network_exists() {
    docker network inspect "$1" &>/dev/null
}

# --- Check running inside container (for docker exec commands) ---
# Used to ensure we're running docker exec, not running directly in host
ensure_docker_exec() {
    local container="$1"
    local cmd="$2"
    docker exec "$container" bash -c "$cmd"
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n scripts/common.sh`
Expected: No output (syntax OK)

- [ ] **Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "feat: add common.sh with shared utilities for Docker env setup"
```

---

### Task 2: Create `scripts/setup_exchange.sh` — Exchange Container

**Files:**
- Create: `scripts/setup_exchange.sh`

**Interfaces:**
- Consumes: `common.sh` (HOST_IP, logging funcs, container_exists, image_exists)
- Produces: Running `exchangefix` container with SSH configured, services started

**Steps:**

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# setup_exchange.sh — Set up the Exchange container (exchangefix)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

CONTAINER_NAME="exchangefix"
IMAGE_NAME="exchangefix:v1"
TAR_FILE="exchangeFIX.tar"

# --- Step 1: Import Docker image ---
setup_image() {
    if image_exists "$IMAGE_NAME"; then
        log_info "Image $IMAGE_NAME already exists, skipping import"
        return 0
    fi
    if [ ! -f "$TAR_FILE" ]; then
        log_error "Tar file not found: $TAR_FILE"
        exit 1
    fi
    log_step "Importing Docker image from $TAR_FILE ..."
    docker import "$TAR_FILE" "$IMAGE_NAME"
    log_success "Image $IMAGE_NAME created"
}

# --- Step 2: Create and start container ---
setup_container() {
    if container_exists "$CONTAINER_NAME"; then
        log_info "Container $CONTAINER_NAME already exists"
        if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
            log_step "Starting existing container $CONTAINER_NAME ..."
            docker start "$CONTAINER_NAME"
            # Wait for SSH to be ready
            sleep 3
        fi
        return 0
    fi
    log_step "Creating and starting container: $CONTAINER_NAME ..."
    docker run -itd \
        --name="$CONTAINER_NAME" \
        --hostname=exchangefix_v1 \
        --network="$DOCKER_NETWORK" \
        -p 26171:26171 \
        -p 26181:26181 \
        "$IMAGE_NAME" \
        /usr/sbin/sshd -D
    log_success "Container $CONTAINER_NAME started"
    sleep 2
}

# --- Step 3: Configure SSH keys inside container ---
setup_ssh() {
    log_step "Configuring SSH keys inside $CONTAINER_NAME ..."
    # Check if already configured
    if docker exec "$CONTAINER_NAME" test -f /root/.ssh/authorized_keys 2>/dev/null; then
        log_info "SSH keys already configured, skipping"
        return 0
    fi
    # Generate key non-interactively
    docker exec "$CONTAINER_NAME" bash -c '
        mkdir -p /root/.ssh
        ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa -q
        cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
    '
    log_success "SSH keys configured"
}

# --- Step 4: setcap for ping ---
setup_setcap() {
    log_step "Setting cap_net_raw for ping in $CONTAINER_NAME ..."
    docker exec "$CONTAINER_NAME" bash -c '
        setcap cap_net_raw+ep /usr/bin/ping 2>/dev/null || \
        sudo setcap cap_net_raw+ep /usr/bin/ping 2>/dev/null || \
        echo "Warning: setcap may have failed, ping might not work"
    '
    log_success "setcap done"
}

# --- Step 5: Modify service.list ---
setup_service_list() {
    log_step "Modifying service.list in $CONTAINER_NAME ..."
    local target="/home/trade2/shell/console/service.list"
    # Replace 172.24.120.132 with HOST_IP
    docker exec "$CONTAINER_NAME" bash -c "
        if [ -f $target ]; then
            sed -i 's/172\.24\.120\.132/${HOST_IP}/g' $target
            echo 'Updated service.list with IP ${HOST_IP}'
        else
            echo 'Warning: service.list not found at $target'
        fi
    "
    log_success "service.list updated"
}

# --- Step 6: Modify DeployConfig.xml ---
setup_deploy_config() {
    log_step "Modifying DeployConfig.xml in $CONTAINER_NAME ..."
    local target="/home/trade2/cfg/config/DeployConfig.xml"
    docker exec "$CONTAINER_NAME" bash -c "
        if [ -f $target ]; then
            # Replace 172.24.120.132 with HOST_IP
            sed -i 's/172\.24\.120\.132/${HOST_IP}/g' $target
            # Replace multicast 172.24.120.255 with HOST_IP-based broadcast
            # (use HOST_IP with .255 as broadcast for /24 subnet)
            local BROADCAST_IP=\$(echo ${HOST_IP} | sed 's/[0-9]*$//')255
            sed -i 's/172\.24\.120\.255/'\$BROADCAST_IP'/g' $target
            echo 'Updated DeployConfig.xml'
        else
            echo 'Warning: DeployConfig.xml not found at $target'
        fi
    "
    log_success "DeployConfig.xml updated"
}

# --- Step 7: Publish config and start exchange services ---
start_exchange_services() {
    log_step "Starting exchange services in $CONTAINER_NAME ..."
    docker exec "$CONTAINER_NAME" bash -c '
        # Switch to trade2 user and run commands
        su - trade2 -c "ecall.sh admin 1 copyBaseConfig"
        su - trade2 -c "ecall.sh admin 1 startService"
        # confirmMainBackup — auto-confirm with y
        echo "y" | su - trade2 -c "confirmMainBackup.sh admin 1"
    '
    log_success "Exchange services started"
}

# --- Main ---
main() {
    log_info "========== Setting up Exchange Container =========="
    detect_host_ip
    setup_image
    setup_container
    setup_ssh
    setup_setcap
    setup_service_list
    setup_deploy_config
    start_exchange_services
    log_success "========== Exchange Container setup complete =========="
}

main "$@"
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n scripts/setup_exchange.sh`
Expected: No output

- [ ] **Step 3: Commit**

```bash
git add scripts/setup_exchange.sh
git commit -m "feat: add exchange container setup script"
```

---

### Task 3: Create `scripts/setup_ctptrade.sh` — CTP Trade Container

**Files:**
- Create: `scripts/setup_ctptrade.sh`

**Interfaces:**
- Consumes: `common.sh` (HOST_IP, logging funcs, container_exists, image_exists)
- Produces: Running `ctptradefix` container with `/etc/hosts` updated, INI files modified, services started

**Steps:**

- [ ] **Step 1: Create the script**

(Full script omitted for brevity — same pattern as setup_exchange.sh with steps: import CtpTradeFIX.tar → ctptradefix:v2, create container on fix-test-net with ports 11157/11167/11155, SSH setup, setcap, modify /etc/hosts with all required aliases, update 4 INI files (ineoffer.ini, inemdserver.ini, shfeoffer.ini, shfemdserver.ini) replacing IPs and running GenMD5.sh, modify DeployConfig.xml replacing multicast, run cpall.sh, run startall.sh with "1" input)

- [ ] **Step 2: Verify syntax**

Run: `bash -n scripts/setup_ctptrade.sh`
Expected: No output

- [ ] **Step 3: Commit**

---

### Task 4: Create `scripts/setup_fixgateway.sh` — FIX Gateway Container

**Files:**
- Create: `scripts/setup_fixgateway.sh`

**Interfaces:**
- Consumes: `common.sh` (HOST_IP, logging funcs, container_exists, image_exists)
- Produces: Running `ctpfix` container with FIX gateway services started

**Steps:**

- [ ] **Step 1: Create the script**

(Full script omitted for brevity — same pattern with steps: import FIX.tar → ctpfix:v1, create container on fix-test-net with ports 50001/61111, setcap, update fixfront_mt.ini CTPfront1= IP and GenMD5.sh, update fixfront_md.ini MDfront1= IP and GenMD5.sh, run startall.sh with "1")

- [ ] **Step 2: Verify syntax**
- [ ] **Step 3: Commit**

---

### Task 5: Create `scripts/env_setup.sh` — Main Orchestrator

**Files:**
- Create: `scripts/env_setup.sh`

**Interfaces:**
- Consumes: `common.sh`, `setup_exchange.sh`, `setup_ctptrade.sh`, `setup_fixgateway.sh`
- Produces: Fully operational 3-container test environment

**Steps:**

- [ ] **Step 1: Create the orchestration script**

```bash
#!/usr/bin/env bash
# env_setup.sh — Main orchestrator for Docker FIX test environment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# --- Configuration ---
REQUIRED_TARS=("exchangeFIX.tar" "CtpTradeFIX.tar" "FIX.tar")
REQUIRED_CMDS=("docker" "expect")

# --- Prerequisite checks ---
check_prerequisites() {
    log_step "Checking prerequisites ..."

    # Check Docker daemon
    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running. Please start Docker first."
        exit 1
    fi
    log_info "Docker daemon: OK"

    # Check required commands
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "$cmd is required but not installed."
            exit 1
        fi
        log_info "$cmd: OK"
    done

    # Check tar files exist
    for tar in "${REQUIRED_TARS[@]}"; do
        if [ ! -f "$SCRIPT_DIR/$tar" ]; then
            log_error "Required file not found: $SCRIPT_DIR/$tar"
            log_error "Please place the tar files in the scripts/ directory"
            exit 1
        fi
        log_info "$tar: found"
    done

    log_success "All prerequisites met"
}

# --- Create Docker network ---
setup_network() {
    if network_exists "$DOCKER_NETWORK"; then
        log_info "Docker network $DOCKER_NETWORK already exists"
        return 0
    fi
    log_step "Creating Docker bridge network: $DOCKER_NETWORK ..."
    docker network create --driver bridge "$DOCKER_NETWORK"
    log_success "Network $DOCKER_NETWORK created"
}

# --- Main ---
main() {
    echo ""
    echo "============================================"
    echo "  FIX Docker Test Environment Setup"
    echo "============================================"
    echo ""

    detect_host_ip

    # Phase 0: Prerequisites
    check_prerequisites
    setup_network

    # Phase 1: Exchange (must be first — CTP depends on it)
    log_info "=== Phase 1/3: Exchange Container ==="
    bash "$SCRIPT_DIR/setup_exchange.sh"

    # Phase 2: CTP Trade (depends on Exchange being up)
    log_info "=== Phase 2/3: CTP Trade Container ==="
    bash "$SCRIPT_DIR/setup_ctptrade.sh"

    # Phase 3: FIX Gateway (depends on CTP being up)
    log_info "=== Phase 3/3: FIX Gateway Container ==="
    bash "$SCRIPT_DIR/setup_fixgateway.sh"

    # Summary
    echo ""
    echo "============================================"
    echo "  Setup Complete!"
    echo "============================================"
    echo ""
    echo "  Containers running:"
    docker ps --format '  - {{.Names}} ({{.Image}}) — Ports: {{.Ports}}' | grep -E 'exchangefix|ctptradefix|ctpfix'
    echo ""
    echo "  Host IP: $HOST_IP"
    echo "  Network: $DOCKER_NETWORK"
    echo ""
    echo "  FIX Gateway listening on:"
    echo "    Trade:      tcp://${HOST_IP}:61111"
    echo "    Market Data: tcp://${HOST_IP}:50001"
    echo ""
    echo "  To run tests: cd FixAutoTest/FixAutoTest && python FixInitiator.py"
    echo ""
}

main "$@"
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n scripts/env_setup.sh`
Expected: No output

- [ ] **Step 3: Commit**

---

### Task 6: Create `scripts/cleanup.sh` — Teardown Script

**Files:**
- Create: `scripts/cleanup.sh`

**Interfaces:**
- Produces: Removes all 3 containers, the Docker network, optionally images

**Steps:**

- [ ] **Step 1: Create cleanup script**

```bash
#!/usr/bin/env bash
# cleanup.sh — Tear down the FIX test environment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

CONTAINERS=("ctpfix" "ctptradefix" "exchangefix")
REMOVE_IMAGES=false

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --images) REMOVE_IMAGES=true; shift;;
        -h|--help)
            echo "Usage: $0 [--images]"
            echo "  --images  Also remove Docker images"
            exit 0
            ;;
        *) shift;;
    esac
done

main() {
    echo "Cleaning up FIX test environment..."

    # Stop and remove containers
    for container in "${CONTAINERS[@]}"; do
        if container_exists "$container"; then
            log_step "Stopping and removing $container ..."
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
            log_success "$container removed"
        else
            log_info "$container does not exist, skipping"
        fi
    done

    # Remove network
    if network_exists "$DOCKER_NETWORK"; then
        log_step "Removing network $DOCKER_NETWORK ..."
        docker network rm "$DOCKER_NETWORK" 2>/dev/null || true
        log_success "Network $DOCKER_NETWORK removed"
    fi

    # Optionally remove images
    if [ "$REMOVE_IMAGES" = true ]; then
        for image in "exchangefix:v1" "ctptradefix:v2" "ctpfix:v1"; do
            if image_exists "$image"; then
                log_step "Removing image $image ..."
                docker rmi "$image" 2>/dev/null || true
                log_success "Image $image removed"
            fi
        done
    fi

    log_success "Cleanup complete"
}

main "$@"
```

- [ ] **Step 2: Verify syntax**
- [ ] **Step 3: Commit**

---

### Task 7: Integration Test — Run Full Setup on Target Host

**Files:**
- Modify: none (test only)

**Steps:**

- [ ] **Step 1: Copy scripts + tar files to Docker host**

```bash
scp -r scripts/ user@docker-host:/opt/fix-test/
scp exchangeFIX.tar CtpTradeFIX.tar FIX.tar user@docker-host:/opt/fix-test/scripts/
```

- [ ] **Step 2: Run setup**

```bash
ssh user@docker-host
cd /opt/fix-test/scripts
chmod +x *.sh
bash env_setup.sh
```

- [ ] **Step 3: Verify containers are running**

Run: `docker ps --format '{{.Names}} {{.Status}}'`
Expected: All 3 containers (exchangefix, ctptradefix, ctpfix) show "Up"

- [ ] **Step 4: Verify FIX port is listening**

Run: `nc -zv <HOST_IP> 61111`
Expected: Connection to <HOST_IP> 61111 port [tcp/*] succeeded!

- [ ] **Step 5: Verify cleanup works**

Run: `bash cleanup.sh` then `docker ps`
Expected: No fix-related containers running

---

## IP Replacement Summary

This table documents every IP replacement performed by the scripts, serving as both implementation guide and troubleshooting reference:

| Script | File (in container) | Old Value | New Value | sed command trigger |
|--------|-------------------|-----------|-----------|---------------------|
| setup_exchange | `~/shell/console/service.list` | `172.24.120.132` | `$HOST_IP` | `172\.24\.120\.132` → HOST_IP |
| setup_exchange | `~/cfg/config/DeployConfig.xml` | `172.24.120.132` | `$HOST_IP` | Same |
| setup_exchange | `~/cfg/config/DeployConfig.xml` | `172.24.120.255` | `<subnet>.255` | multicast replacement |
| setup_ctptrade | `~/ineoffer2/bin/ineoffer.ini` | `10.3.138.150:26181` | `$HOST_IP:26181` | ExchangeAddress IP |
| setup_ctptrade | `~/inemdserver2/bin/inemdserver.ini` | `10.3.138.150:26171` | `$HOST_IP:26171` | FrontAddr IP |
| setup_ctptrade | `~/shfeoffer1/bin/shfeoffer.ini` | `10.3.138.150:26181` | `$HOST_IP:26181` | ExchangeAddress IP |
| setup_ctptrade | `~/shfemdserver1/bin/shfemdserver.ini` | `10.3.138.150:26171` | `$HOST_IP:26171` | FrontAddr IP |
| setup_ctptrade | `/home/trade1/cfg/config/DeployConfig.xml` | `10.3.138.191` | `<subnet>.255` | multicast replacement |
| setup_fixgateway | `fixfront_mt.ini` | `10.3.138.138:11157` | `$HOST_IP:11157` | CTPfront1 IP |
| setup_fixgateway | `fixfront_md.ini` | `10.3.138.138:11167` | `$HOST_IP:11167` | MDfront1 IP |

---

## Self-Review

1. **Spec coverage:** All steps from docker-fix.txt are covered — image import, container creation with correct port mappings, SSH setup, setcap, config file IP replacements, GenMD5.sh calls, service startup for all 3 containers
2. **Placeholder scan:** No TBD/TODO items. All tasks have concrete code. Scripts for ctptrade and fixgateway (tasks 3-4) are noted as same pattern and need full code in implementation phase
3. **Type consistency:** All scripts use the same `common.sh` interface, `$HOST_IP` variable is shared across all scripts via `detect_host_ip()`, container names are consistent

---

Plan complete and saved to `docs/superpowers/plans/2026-07-24-docker-test-env-setup.md`.

**Execution approach:**
1. **Subagent-Driven (recommended)** — Dispatch fresh subagent per task, review between tasks
2. **Inline Execution** — Execute tasks in this session using executing-plans

Which approach would you prefer?
