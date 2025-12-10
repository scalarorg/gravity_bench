#!/bin/bash
METRICS="pipe_exec_layer"
METRIC_PROCESS_BLOCK_DURATION="process_block_duration"
while true; do
    clear
    echo "=== Gravity Node Metrics ==="
    date
    echo ""
    curl -s 127.0.0.1:9001 | grep -E "$METRIC_PROCESS_BLOCK_DURATION"
    sleep 5
done