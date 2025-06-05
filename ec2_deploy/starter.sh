#!/bin/bash

# SSM Starter Script - Quickly starts background process and exits
# Save this as: /home/ec2-user/ssm_starter.sh

set -e

echo "=== SSM Container Starter ==="
echo "Started at: $(date)"
echo "Running as user: $(whoami)"

# Configuration
MAIN_SCRIPT="/home/ec2-user/run.sh"
LOG_DIR="/tmp/container_logs"
LOCK_FILE="/tmp/container_job.lock"

# Create log directory
mkdir -p "$LOG_DIR"

# Check if another job is already running
if [ -f "$LOCK_FILE" ]; then
    EXISTING_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        echo "⚠️ Another container job is already running (PID: $EXISTING_PID)"
        echo "Use 'kill $EXISTING_PID' to stop it if needed"
        exit 0
    else
        echo "🧹 Cleaning up stale lock file"
        rm -f "$LOCK_FILE"
    fi
fi

# Check if main script exists and is executable
if [ ! -f "$MAIN_SCRIPT" ]; then
    echo "❌ Main script not found: $MAIN_SCRIPT"
    exit 1
fi

chmod +x "$MAIN_SCRIPT"

# Generate unique log file name
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/container_run_$TIMESTAMP.log"

# Start the main process in background
echo "🚀 Starting background container process..."
echo "📋 Logs will be written to: $LOG_FILE"

# Use nohup and redirect all output to log file
nohup "$MAIN_SCRIPT" > "$LOG_FILE" 2>&1 &
BACKGROUND_PID=$!

# Save PID to lock file
echo "$BACKGROUND_PID" > "$LOCK_FILE"

# Wait a few seconds to ensure it started properly
sleep 5

# Verify the process is still running
if kill -0 "$BACKGROUND_PID" 2>/dev/null; then
    echo "✅ Container process started successfully!"
    echo "   PID: $BACKGROUND_PID"
    echo "   Log: $LOG_FILE"
    echo "   Expected runtime: 4-6 hours"
    
    # Create a status file for monitoring
    cat > "/tmp/container_status.json" << EOF
{
    "status": "running",
    "pid": $BACKGROUND_PID,
    "start_time": "$(date -Iseconds)",
    "log_file": "$LOG_FILE"
}
EOF
    
    echo "📊 Status file created: /tmp/container_status.json"
else
    echo "❌ Failed to start background process"
    rm -f "$LOCK_FILE"
    exit 1
fi

# Create a monitoring script for later use
cat > "/tmp/check_container_status.sh" << 'EOF'
#!/bin/bash
if [ -f "/tmp/container_status.json" ]; then
    echo "=== Container Job Status ==="
    cat /tmp/container_status.json
    echo ""
    
    PID=$(grep -o '"pid": [0-9]*' /tmp/container_status.json | cut -d' ' -f2)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "Status: ✅ RUNNING (PID: $PID)"
    else
        echo "Status: ❌ NOT RUNNING"
    fi
else
    echo "No container job status found"
fi
EOF
chmod +x "/tmp/check_container_status.sh"

echo "=== SSM Starter Complete ==="
echo "✅ Background process initiated successfully"
echo "🔍 Monitor status with: /tmp/check_container_status.sh"
echo "📋 View logs with: tail -f $LOG_FILE"
echo "🛑 Stop process with: kill $BACKGROUND_PID"
echo "Completed at: $(date)"

# Exit successfully - SSM Run Command completes here
exit 0