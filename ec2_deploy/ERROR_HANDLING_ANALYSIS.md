# Error Handling and Logging Analysis for run.sh

## Overview
This document explains how error handling works in the `run.sh` script and how it integrates with the logging system to ensure data integrity and proper error reporting.

## Error Handling Flow

### 1. **check_docker() Function**
**Purpose**: Verifies Docker is available and running
**Failure Scenarios**:
- Docker not installed → `handle_error 1` → Exit code 1, EC2 shutdown in 60s
- Docker not running → `handle_error 2` → Exit code 2, EC2 shutdown in 60s  
- Docker daemon inaccessible → `handle_error 2` → Exit code 2, EC2 shutdown in 60s

**What Happens**: Script logs error, updates status file, shuts down EC2 instance, and exits
**Impact**: Container cannot run, so script terminates immediately

### 2. **verify_iam_credentials() Function**
**Purpose**: Verifies AWS IAM role permissions
**Failure Scenarios**:
- Cannot access AWS services → `handle_error 3` → Exit code 3, EC2 shutdown in 60s

**What Happens**: Script logs error, updates status file, shuts down EC2 instance, and exits
**Impact**: Cannot access SSM, S3, ECR, so script terminates immediately

### 3. **load_environment_vars() Function**
**Purpose**: Loads configuration and SSM parameters
**Failure Scenarios**:
- SSM parameter failures → `handle_error 3` → Exit code 3, EC2 shutdown in 60s
- Missing required variables → `handle_error 2` → Exit code 2, EC2 shutdown in 60s
- S3 download failures → `handle_error 4` → Exit code 4, EC2 shutdown in 60s
- Invalid epoch values → `handle_error 5` → Exit code 5, EC2 shutdown in 60s

**What Happens**: Script logs error, updates status file, shuts down EC2 instance, and exits
**Impact**: Cannot proceed without configuration, so script terminates immediately

### 4. **adjust_window_if_needed() Function** ⚠️ **CRITICAL**
**Purpose**: Updates production window and EventBridge scheduler
**Failure Scenarios**:
- SLOWDOWN trigger → Returns 1 → Script exits with code 0 (NOT IDEAL)
- Missing ARNs → Returns 1 → Script exits with code 0 (NOT IDEAL)

**What Happens**: 
- **BEFORE FIX**: Script exits without setting BACKFILL=true (WINDOW LOST!)
- **AFTER FIX**: Script sets BACKFILL=true before exiting, preserving window

**Impact**: This was the critical gap - production state could be updated but container never runs

### 5. **run_container() Function**
**Purpose**: Runs the Docker container
**Failure Scenarios**:
- ECR login failures → `handle_error 3` → Exit code 3, EC2 shutdown in 60s
- Image pull failures → `handle_error 4` → Exit code 4, EC2 shutdown in 60s
- Container start failures → `handle_error 5` → Exit code 5, EC2 shutdown in 60s
- Container fails immediately → Sets BACKFILL=true, then exits

**What Happens**: Script logs error, sets BACKFILL=true if needed, updates status file, shuts down EC2 instance, and exits

## Logging Integration

### **Status File Updates**
All error scenarios update `/tmp/container_status.json` with:
```json
{
    "status": "failed",
    "error": "Error message",
    "end_time": "ISO timestamp",
    "exit_code": 1-5
}
```

### **CloudWatch Logging**
- **Enabled by default**: `SEND_LOGS_TO_CLOUDWATCH=true`
- **Log group**: `/aws/ec2/containers/default` (configurable)
- **Log stream**: `container-{timestamp}-{instance-id}`
- **Content**: Combined shell script + container logs

### **Log File Locations**
- **Shell script logs**: `/tmp/container_logs/container_run_YYYYMMDD_HHMMSS.log`
- **Container logs**: `/tmp/container_logs/container_logs_YYYYMMDD_HHMMSS.log`
- **Combined logs**: `/tmp/container_logs/combined_logs_YYYYMMDD_HHMMSS.log`

## Critical Data Integrity Protection

### **BACKFILL Parameter Management**
The `BACKFILL` parameter is critical for data integrity:

1. **When BACKFILL=true**: Container runs with current window, no production state update
2. **When BACKFILL=false**: Container runs and production state gets updated
3. **If container fails after production update**: BACKFILL must be set to true to preserve window

### **Window State Management**
- **Production state**: `s3://lol-match-jsons/production/state/next_window.json`
- **Backfill state**: `s3://lol-match-jsons/backfill/state/next_window.json`
- **Window preservation**: If production state is updated but container fails, BACKFILL=true ensures the window is retried

## Error Exit Codes

| Exit Code | Meaning | Action |
|-----------|---------|---------|
| 1 | Docker issues | EC2 shutdown, no data loss |
| 2 | Configuration issues | EC2 shutdown, no data loss |
| 3 | AWS/SSM issues | EC2 shutdown, no data loss |
| 4 | S3/ECR issues | EC2 shutdown, no data loss |
| 5 | Container issues | EC2 shutdown, BACKFILL=true set |

## Recommendations

### **Immediate Fixes Applied** ✅
1. **Window adjustment failures**: Now set BACKFILL=true before exit
2. **Container immediate failures**: Now set BACKFILL=true before exit
3. **ARN loading failures**: Now set BACKFILL=true before exit

### **Additional Considerations**
1. **Monitoring**: Set up CloudWatch alarms for failed container runs
2. **Retry logic**: Consider implementing automatic retry for transient failures
3. **Alerting**: Set up SNS notifications for critical failures
4. **Metrics**: Track failure rates and types for operational insights

## Testing Error Scenarios

To test error handling:
1. **Docker unavailable**: Stop Docker service
2. **IAM issues**: Remove IAM role from EC2 instance
3. **SSM issues**: Delete required SSM parameters
4. **S3 issues**: Remove S3 bucket permissions
5. **Container failures**: Use invalid container image

Each should result in proper error logging, BACKFILL=true if needed, and EC2 shutdown.
