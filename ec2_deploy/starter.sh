#!/bin/bash

# SSM Starter Script - Simple version that passes PID directly
set -e

echo "=== SSM Container Starter ==="
echo "Started at: $(date)"
echo "Running as user: $(whoami)"

# Configuration
MAIN_SCRIPT="/home/ec2-user/scripts/run.sh"
LOG_DIR="/tmp/container_logs"
LOCK_FILE="/tmp/container_job.lock"

# Create log directory
mkdir -p "$LOG_DIR"

# Check if another job is already running
if [ -f "$LOCK_FILE" ]; then
    EXISTING_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        echo "⚠️ Another container job is already running (PID: $EXISTING_PID)"
        exit 0
    else
        echo "🧹 Removing stale lock file"
        rm -f "$LOCK_FILE"
    fi
fi

# Check if main script exists
if [ ! -f "$MAIN_SCRIPT" ]; then
    echo "❌ Main script not found: $MAIN_SCRIPT"
    exit 1
fi

chmod +x "$MAIN_SCRIPT"

# Generate log file
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/container_run_$TIMESTAMP.log"

echo "🚀 Starting background container process..."
echo "📋 Logs will be written to: $LOG_FILE"

# Test if we can write to the log file
if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "❌ Cannot write to log file: $LOG_FILE"
    echo "🔍 Debug: Directory permissions: $(ls -ld "$LOG_DIR")"
    echo "🔍 Debug: Current user: $(whoami)"
    exit 1
fi

# Start run.sh in background and get its PID
nohup "$MAIN_SCRIPT" > "$LOG_FILE" 2>&1 &
RUN_PID=$!

# Write the run.sh PID to the lock file (this is what run.sh expects)
echo "$RUN_PID" > "$LOCK_FILE"

# Wait a moment to ensure it started
sleep 3

# Verify it's running
if kill -0 "$RUN_PID" 2>/dev/null; then
    echo "✅ Container process started successfully!"
    echo "   PID: $RUN_PID"
    echo "   Log: $LOG_FILE"
    echo "   Monitor with: tail -f $LOG_FILE"
    echo "   Stop with: kill $RUN_PID"
else
    echo "❌ Failed to start background process"
    rm -f "$LOCK_FILE"
    exit 1
fi

echo "Completed at: $(date)"