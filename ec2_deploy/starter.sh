#!/bin/bash

# SSM Starter Script - Quickly starts background process and exits
# FIXED: Proper locking mechanism to prevent race conditions
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

# FIXED: Atomic lock creation using flock for proper concurrency control
# This prevents race conditions between multiple SSM executions
exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    echo "⚠️ Another container job is already running"
    if [ -f "$LOCK_FILE" ]; then
        EXISTING_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
            echo "   Running PID: $EXISTING_PID"
        else
            echo "   Lock file exists but process may be dead"
        fi
    fi
    echo "Use '/tmp/check_container_status.sh' to check status"
    exit 0
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

# FIXED: Write PID to lock file immediately after starting process
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
        
        # Show recent log entries
        LOG_FILE=$(grep -o '"log_file": "[^"]*' /tmp/container_status.json | cut -d'"' -f4)
        if [ -f "$LOG_FILE" ]; then
            echo ""
            echo "=== Recent Log Entries ==="
            tail -n 10 "$LOG_FILE"
        fi
    else
        echo "Status: ❌ NOT RUNNING"
        
        # Check if lock file still exists
        if [ -f "/tmp/container_job.lock" ]; then
            echo "⚠️ Stale lock file exists, you may need to clean it up"
        fi
    fi
else
    echo "No container job status found"
fi

# Check for Docker containers that might still be running
if command -v docker &> /dev/null; then
    echo ""
    echo "=== Docker Container Status ==="
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}" | grep -E "(default_repo|container)" || echo "No related containers found"
fi
EOF
chmod +x "/tmp/check_container_status.sh"

# Create a cleanup script
cat > "/tmp/cleanup_container_job.sh" << 'EOF'
#!/bin/bash
echo "=== Container Job Cleanup ==="

# Kill the background process if it's still running
if [ -f "/tmp/container_job.lock" ]; then
    PID=$(cat "/tmp/container_job.lock" 2>/dev/null || echo "")
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "🛑 Stopping background process (PID: $PID)..."
        kill "$PID"
        sleep 3
        
        # Force kill if still running
        if kill -0 "$PID" 2>/dev/null; then
            echo "🔥 Force killing process..."
            kill -9 "$PID"
        fi
    fi
    
    rm -f "/tmp/container_job.lock"
    echo "✅ Lock file removed"
fi

# Stop and remove Docker containers
if command -v docker &> /dev/null; then
    echo "🐳 Cleaning up Docker containers..."
    docker ps -a --format "{{.Names}}" | grep -E "(default_repo|container)" | while read -r container; do
        echo "   Stopping and removing: $container"
        docker stop "$container" 2>/dev/null || true
        docker rm "$container" 2>/dev/null || true
    done
fi

# Clean up status files
rm -f "/tmp/container_status.json"
echo "✅ Cleanup complete"
EOF
chmod +x "/tmp/cleanup_container_job.sh"

echo "=== SSM Starter Complete ==="
echo "✅ Background process initiated successfully"
echo "🔍 Monitor status with: /tmp/check_container_status.sh"
echo "📋 View logs with: tail -f $LOG_FILE"
echo "🛑 Stop process with: kill $BACKGROUND_PID"
echo "🧹 Emergency cleanup with: /tmp/cleanup_container_job.sh"
echo "Completed at: $(date)"

# Release the lock on exit (flock will automatically release)
# The background process will maintain its own lock via the PID file
exec 200>&-

# Exit successfully - SSM Run Command completes here