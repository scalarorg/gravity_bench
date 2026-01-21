#!/bin/bash
# Use debian-12-bookworm-v20251209
# Setup script for gravity_bench environment

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
NVME_DEVICE="/dev/nvme0n1"
NVME_PARTITION="/dev/nvme0n1p1"
MOUNT_POINT="/mnt/bench"
BENCH_DIR="/mnt/bench/gravity_bench"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

GRAVITY_RETH_BRANCH="fastevm"
GRAVITY_BENCH_BRANCH="fastevm"
# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Setup NVMe disk
setup_nvme() {
    log_info "Setting up NVMe disk..."
    
    # Check if already mounted
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_warn "$MOUNT_POINT is already mounted. Skipping NVMe setup."
        return 0
    fi
    
    # Check if partition already exists
    if [ -e "$NVME_PARTITION" ]; then
        log_warn "Partition $NVME_PARTITION already exists."
        read -p "Do you want to recreate it? This will destroy all data! (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Using existing partition."
        else
            log_info "Recreating partition..."
            sudo umount "$NVME_PARTITION" 2>/dev/null || true
            sudo parted "$NVME_DEVICE" mklabel gpt
            sudo parted -a optimal "$NVME_DEVICE" mkpart primary ext4 0% 100%
            sudo mkfs -t ext4 -F "$NVME_PARTITION"
        fi
    else
        # Create new partition
        log_info "Creating partition table and partition..."
        sudo parted "$NVME_DEVICE" mklabel gpt
        sudo parted -a optimal "$NVME_DEVICE" mkpart primary ext4 0% 100%
        sudo mkfs -t ext4 "$NVME_PARTITION"
    fi
    
    # Mount the partition
    log_info "Mounting partition..."
    sudo mkdir -p "$MOUNT_POINT"
    sudo mount "$NVME_PARTITION" "$MOUNT_POINT"
    sudo chown -R "$USER:$USER" "$MOUNT_POINT"
    
    log_info "NVMe disk setup completed."
}

# Install system dependencies
install_system_dependencies() {
    log_info "Installing system dependencies..."
    if ! sudo apt update; then
        log_error "Failed to update package list. Check sudo permissions."
        return 1
    fi
    if ! sudo apt install -y \
        build-essential \
        pkg-config \
        libclang-dev \
        libssl-dev \
        htop \
        git \
        rsync \
        python3 \
        python3-pip \
        python3-dev \
        python3-venv; then
        log_error "Failed to install system dependencies. Check sudo permissions."
        return 1
    fi
    log_info "System dependencies installed."
}

# Install Node.js
install_nodejs() {
    log_info "Installing Node.js v20 (LTS)..."
    if command -v node &> /dev/null; then
        NODE_VERSION=$(node --version)
        log_warn "Node.js is already installed: $NODE_VERSION"
        read -p "Do you want to reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping Node.js installation."
            return 0
        fi
    fi
    
    if ! curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -; then
        log_error "Failed to setup Node.js repository. Check sudo permissions."
        return 1
    fi
    if ! sudo apt install -y nodejs; then
        log_error "Failed to install Node.js. Check sudo permissions."
        return 1
    fi
    log_info "Node.js installed: $(node --version)"
}

# Install Rust
install_rust() {
    log_info "Installing Rust..."
    if command -v rustc &> /dev/null; then
        RUST_VERSION=$(rustc --version)
        log_warn "Rust is already installed: $RUST_VERSION"
        read -p "Do you want to reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping Rust installation."
            return 0
        fi
    fi
    
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    log_info "Rust installed: $(rustc --version)"
}

# Clone repositories
clone_repositories() {
    log_info "Cloning repositories..."
    
    # Create directory if it doesn't exist
    if [ ! -d "$MOUNT_POINT" ]; then
        log_info "Creating directory $MOUNT_POINT..."
        sudo mkdir -p "$MOUNT_POINT"
        sudo chown -R "$USER:$USER" "$MOUNT_POINT"
    fi
    
    cd "$MOUNT_POINT"
    
    if [ ! -d "gravity_bench" ]; then
        log_info "Cloning gravity_bench repository..."
        git clone https://github.com/scalarorg/gravity_bench.git -b ${GRAVITY_RETH_BRANCH}
    else
        log_warn "gravity_bench directory already exists. Skipping clone."
    fi
    
    if [ ! -d "gravity-reth" ]; then
        log_info "Cloning gravity-reth repository..."
        git clone https://github.com/Galxe/gravity-reth.git
    else
        log_warn "gravity-reth directory already exists. Skipping clone."
    fi
    
    log_info "Repositories cloned."
}

# Build the project
build_project() {
    log_info "Building gravity_bench project..."
    
    if [ ! -d "$BENCH_DIR" ]; then
        log_error "gravity_bench directory not found at $BENCH_DIR"
        return 1
    fi
    
    cd "$BENCH_DIR"
    
    # Ensure cargo is in PATH
    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env"
    fi
    
    cargo build --release
    log_info "Build completed."
}

# Main execution
main() {
    log_info "Starting gravity_bench setup..."
    
    # Setup NVMe if available
    # setup_nvme
    # Install dependencies
    install_system_dependencies
    install_nodejs
    install_rust
    
    # Clone and build
    clone_repositories
    build_project
    
    log_info "Setup completed successfully!"
    log_info "Benchmark directory: $BENCH_DIR"
}

# Run main function
main "$@"

