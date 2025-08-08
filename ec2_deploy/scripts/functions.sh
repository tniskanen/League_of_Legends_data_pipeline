#!/bin/bash

# Business logic functions for EC2 container orchestration
# This file contains window management and exit logic functions

# Function to adjust window based on BACKFILL and ACCELERATE settings
adjust_window_if_needed() {
    local start_epoch="$1"
    local end_epoch="$2"
    
    # Hardcoded CRON expressions
    local FAST_CRON="cron(0 10 * * ? *)"
    local SLOW_CRON="cron(0 10 */2 * ? *)"
    
    echo "🔄 Checking window adjustment logic..."
    
    # Get current BACKFILL setting from SSM
    local backfill
    if backfill_response=$(aws ssm get-parameter --name "BACKFILL" --query "Parameter.Value" --output text 2>/dev/null); then
        backfill=$(echo "$backfill_response" | tr '[:upper:]' '[:lower:]')
        echo "📊 BACKFILL setting: $backfill"
    else
        echo "⚠️ Failed to get BACKFILL from SSM, defaulting to false"
        backfill="false"
    fi
    
    # If BACKFILL=true, keep current window and run container
    if [ "$backfill" = "true" ]; then
        echo "🔄 BACKFILL=true: Using current window $start_epoch to $end_epoch"
        return
    fi
    
    # BACKFILL=false - Check FORCE_FAST first
    echo "🚀 BACKFILL=false: Checking FORCE_FAST setting..."
    
    # Get current FORCE_FAST setting from SSM
    local force_fast
    if force_fast_response=$(aws ssm get-parameter --name "FORCE_FAST" --query "Parameter.Value" --output text 2>/dev/null); then
        force_fast=$(echo "$force_fast_response" | tr '[:upper:]' '[:lower:]')
        echo "⚡ FORCE_FAST setting: $force_fast"
    else
        echo "⚠️ Failed to get FORCE_FAST from SSM, defaulting to false"
        force_fast="false"
    fi
    
    # If FORCE_FAST=true, update EventBridge to fast cron and continue
    if [ "$force_fast" = "true" ]; then
        echo "🚀 FORCE_FAST=true: Updating EventBridge to fast cron..."
        if aws events put-rule --name "lol-data-pipeline" --schedule-expression "$FAST_CRON" >/dev/null 2>&1; then
            echo "✅ Updated EventBridge to fast cron: $FAST_CRON"
        else
            echo "❌ Failed to update EventBridge to fast cron"
        fi
    fi
    
    # BACKFILL=false - Check ACCELERATE and adjust window
    echo "🚀 BACKFILL=false: Checking ACCELERATE setting..."
    
    # Get current ACCELERATE setting from SSM
    local accelerate
    if accelerate_response=$(aws ssm get-parameter --name "ACCELERATE" --query "Parameter.Value" --output text 2>/dev/null); then
        accelerate=$(echo "$accelerate_response" | tr '[:upper:]' '[:lower:]')
        echo "⚡ ACCELERATE setting: $accelerate"
    else
        echo "⚠️ Failed to get ACCELERATE from SSM, defaulting to false"
        accelerate="false"
    fi
    
    local current_start="$start_epoch"
    local current_end="$end_epoch"
    local current_time=$(date +%s)
    
    # Loop for epoch adjustment
    local max_iterations=10  # Prevent infinite loops
    local iteration=0
    
    while [ $iteration -lt $max_iterations ]; do
        iteration=$((iteration + 1))
        echo "🔄 Window adjustment iteration $iteration"
        
        # Calculate new epochs
        local new_start="$current_end"
        local new_end
        
        if [ "$accelerate" = "true" ]; then
            new_end=$((current_end + 4 * 24 * 3600))  # +4 days
            echo "⚡ Accelerated mode: $new_start to $new_end (+4 days)"
        else
            new_end=$((current_end + 2 * 24 * 3600))  # +2 days
            echo "🐌 Normal mode: $new_start to $new_end (+2 days)"
        fi
        
        # Check if new end_epoch is greater than current time
        if [ $new_end -gt $current_time ]; then
            if [ "$accelerate" = "true" ]; then
                # Switch to normal mode and recalculate
                echo "⚠️ New end_epoch ($new_end) > current_time ($current_time) with ACCELERATE=true"
                echo "🔄 Switching to normal mode and recalculating..."
                update_ssm_parameter "ACCELERATE" "false"
                accelerate="false"
                current_end="$new_end"  # Use the calculated end as new start
                continue
            else
                # Normal mode but still too far ahead - trigger slowdown
                echo "⚠️ New end_epoch ($new_end) > current_time ($current_time) with ACCELERATE=false"
                echo "🔄 Triggering slowdown mode..."
                
                # Set SLOWDOWN=true and FORCE_FAST=false
                update_ssm_parameter "SLOWDOWN" "true"
                update_ssm_parameter "FORCE_FAST" "false"
                
                echo "📊 Set SLOWDOWN=true, FORCE_FAST=false"
                echo "🛑 Shutting down EC2 instance to allow window to catch up..."
                
                # Shutdown EC2 instance
                shutdown_ec2_instance 30
                return
            fi
        else
            # New end_epoch is in the past - safe to update
            echo "✅ New end_epoch ($new_end) <= current_time ($current_time) - safe to update"
            update_window_json "$new_start" "$new_end" "s3://lol-match-jsons/production/state/next_window.json"
            return
        fi
    done
    
    # If we reach here, we hit max iterations
    echo "⚠️ Hit maximum iterations ($max_iterations), using last calculated window"
    update_window_json "$new_start" "$new_end" "s3://lol-match-jsons/production/state/next_window.json"
}

# Function to handle exit logic based on exit code
handle_exit_logic() {
    local exit_code="$1"
    
    echo "🔄 Processing exit code $exit_code..."
    
    # Set BACKFILL and ACCELERATE based on exit code
    local backfill_value
    local accelerate_value
    
    if [ "$exit_code" = "0" ] || [ "$exit_code" = "7" ] || [ "$exit_code" = "8" ]; then
        # Success or non-critical failures - move to production
        backfill_value="false"
        echo "📊 Exit code $exit_code: Setting BACKFILL=false (ACCELERATE unchanged)"
    elif [ "$exit_code" = "1" ]; then
        # Critical failure - stay in backfill and accelerate
        backfill_value="true"
        accelerate_value="true"
        echo "📊 Exit code $exit_code: Setting BACKFILL=true, ACCELERATE=true (catch-up mode)"
        
        # Apply current start and end epoch to backfill state
        if [ -n "$start_epoch" ] && [ -n "$end_epoch" ]; then
            echo "🔄 Applying current window ($start_epoch to $end_epoch) to backfill state..."
            update_window_json "$start_epoch" "$end_epoch" "s3://lol-match-jsons/production/state/next_window.json"
            echo "✅ Backfill window updated: $start_epoch to $end_epoch"
        else
            echo "⚠️ Warning: start_epoch or end_epoch not available for backfill state update"
        fi
    else
        echo "⚠️ Unknown exit code $exit_code, defaulting to production"
        backfill_value="false"
    fi
    
    # Update BACKFILL SSM parameter
    update_ssm_parameter "BACKFILL" "$backfill_value"
    
    # Only update ACCELERATE if we're setting it to true (backfill mode)
    if [ "$exit_code" = "1" ]; then
        update_ssm_parameter "ACCELERATE" "$accelerate_value"
    fi
    
    echo "✅ Exit logic completed - BACKFILL=$backfill_value, ACCELERATE=$accelerate_value"
} 