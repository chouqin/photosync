#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PhotoSync Full Deploy Script
# Run this from your LOCAL machine
# It packages code, uploads to VM, and runs setup
# ============================================================

VM_USER="${PHOTOSYNC_VM_USER:-azureuser}"
VM_IP="${PHOTOSYNC_VM_IP:-}"
VM_KEY="${PHOTOSYNC_VM_KEY:-}"
INSTALL_DIR="${PHOTOSYNC_DIR:-/opt/photosync}"
PACKAGE="photosync-deploy.tar.gz"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Validate inputs
if [ -z "$VM_IP" ]; then
    log_error "PHOTOSYNC_VM_IP not set. Example: export PHOTOSYNC_VM_IP=20.1.2.3"
    exit 1
fi

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
if [ -n "$VM_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $VM_KEY"
fi

# ============================================================
# 1. Package code
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

log_info "Packaging application..."
tar czf "/tmp/$PACKAGE" \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='data' \
    --exclude='.env' \
    --exclude='infra' \
    --exclude='scripts/deploy-to-vm.sh' \
    backend/ caddy/ docker-compose.yml README.md

log_info "Package created: /tmp/$PACKAGE ($(du -h /tmp/$PACKAGE | cut -f1))"

# ============================================================
# 2. Upload to VM
# ============================================================
log_info "Uploading to VM ($VM_USER@$VM_IP)..."
scp $SSH_OPTS "/tmp/$PACKAGE" "$VM_USER@$VM_IP:/tmp/$PACKAGE"

# ============================================================
# 3. Upload .env if exists
# ============================================================
if [ -f "$PROJECT_ROOT/.env" ]; then
    log_info "Uploading .env..."
    scp $SSH_OPTS "$PROJECT_ROOT/.env" "$VM_USER@$VM_IP:/tmp/photosync.env"
fi

# ============================================================
# 4. Run setup on VM
# ============================================================
log_info "Running setup on VM..."
ssh $SSH_OPTS "$VM_USER@$VM_IP" bash -s <<REMOTE_EOF
set -euo pipefail

INSTALL_DIR="$INSTALL_DIR"
PACKAGE="$PACKAGE"

# Extract code
sudo mkdir -p "\$INSTALL_DIR"
sudo tar xzf "/tmp/\$PACKAGE" -C "\$INSTALL_DIR"

# Move .env if uploaded
if [ -f "/tmp/photosync.env" ]; then
    sudo mv "/tmp/photosync.env" "\$INSTALL_DIR/.env"
    sudo chmod 600 "\$INSTALL_DIR/.env"
fi

# Run setup
sudo bash "\$INSTALL_DIR/scripts/setup-vm.sh"
REMOTE_EOF

# ============================================================
# 5. Cleanup
# ============================================================
rm -f "/tmp/$PACKAGE"

log_info "Deployment complete!"
echo ""
echo "Test: curl http://$VM_IP/health"
