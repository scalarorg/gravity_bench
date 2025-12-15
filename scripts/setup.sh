#!/bin/bash
# Use debian-12-bookworm-v20251209
# Setup nvme
sudo parted /dev/nvme0n1 mklabel gpt
sudo parted -a optimal /dev/nvme0n1 mkpart primary ext4 0% 100%
sudo mkfs -t ext4 /dev/nvme0n1p1
sudo mkdir -p /mnt/bench
sudo mount /dev/nvme0n1p1 /mnt/bench
sudo chown -R $USER:$USER /mnt/bench

# Setup the gravity_bench environment
sudo apt install build-essential pkg-config libclang-dev libssl-dev htop git -y
sudo apt install python3 python3-pip python3-dev python3-venv -y

# To install Node.js v20 (LTS):
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install nodejs

# Setup rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
. "$HOME/.cargo/env"

# Clone the gravity_bench and gravity-reth repositories
cd /mnt/bench
git clone https://github.com/scalarorg/gravity_bench.git -b fastevm
git clone https://github.com/Galxe/gravity-reth.git

# Install the dependencies
cd /mnt/bench/gravity_bench
cargo build --release

