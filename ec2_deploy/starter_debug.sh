#!/bin/bash
# SSM Starter Script - Debug Version
# Save this as: /home/ec2-user/ssm_starter_debug.sh

set -e

echo "=== SSM Container Starter - DEBUG MODE ==="
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
echo "🔍 Checking main script: $MAIN_SCRIPT"
if [ ! -f "$MAIN_SCRIPT" ]; then
    echo "❌ Main script not found: $MAIN_SCRIPT"
    echo "📁 Contents of /home/ec2-user/:"
    ls -la /home/ec2-user/ || echo "Cannot list directory"
    exit 1
fi

echo "✅ Main script found"
echo "📋 Script details:"
ls -la "$MAIN_SCRIPT"

# Check if script is readable
if [ ! -r "$MAIN_SCRIPT" ]; then
    echo "❌ Main script is not readable"
    exit 1
fi

# Make executable
chmod +x "$MAIN_SCRIPT"
echo "✅ Made script executable"

# Show first few lines of the script to verify it's valid
echo "📄 First 10 lines of main script:"
head -10 "$MAIN_SCRIPT" || echo "Cannot read script content"

# Generate unique log file name
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/container_run_$TIMESTAMP.log"

# Test run the script briefly to see immediate errors
echo "🧪 Testing script execution..."
echo "Running: timeout 10s $MAIN_SCRIPT"

# Try running with timeout to catch immediate failures
if timeout 10s "$MAIN_SCRIPT" > "$LOG_FILE" 2>&1; then
    echo "✅ Script runs without immediate errors"
else
    EXIT_CODE=$?
    echo "❌ Script failed during test run (exit code: $EXIT_CODE)"
    echo "📋 Error output:"
    tail -20 "$LOG_FILE"
    exit 1
fi

# Start the main process in background
echo "🚀 Starting background container process..."
echo "📋 Logs will be written to: $LOG_FILE"

# Use nohup and redirect all output to log file
nohup "$MAIN_SCRIPT" > "$LOG_FILE" 2>&1 &
BACKGROUND_PID=$!

# Save PID to lock file
echo "$BACKGROUND_PID" > "$LOCK_FILE"
echo "💾 Saved PID $BACKGROUND_PID to lock file"

# Wait a few seconds to ensure it started properly
echo "⏳ Waiting 5 seconds to verify startup..."
sleep 5

# Show recent log output for debugging
echo "📋 Recent log output:"
tail -10 "$LOG_FILE" 2>/dev/null || echo "Cannot read log file yet"

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
    echo "📋 Final log output:"
    cat "$LOG_FILE" 2>/dev/null || echo "Cannot read log file"
    echo "🔍 Process check details:"
    ps aux | grep -v grep | grep "$MAIN_SCRIPT" || echo "No matching processes found"
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

exit 0