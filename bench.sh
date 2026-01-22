#!/bin/bash

source ./setup.sh
RUST_LOG=debug cargo run --bin gravity_bench --release -- --config bench_config_fastevm.toml