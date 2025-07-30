# FIXED: Enhanced function to run container with better error handling (NO TIMEOUT)
run_container() {
    echo "🚀 Running container with IAM role and auto-shutdown..."
    
    # Check if a container with the same name is already running
    if $DOCKER_CMD ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        echo "⚠️ Container ${CONTAINER_NAME} is already running. Stopping it first..."
        $DOCKER_CMD stop "${CONTAINER_NAME}" || true
        $DOCKER_CMD rm "${CONTAINER_NAME}" || true
    fi
    
    # Login to ECR
    if [[ "$ECR_URI" == *".dkr.ecr."* ]]; then
        echo "🔑 Logging into AWS ECR..."
        aws ecr get-login-password --region "${REGION}" | $DOCKER_CMD login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" || {
            handle_error 3 "Failed to login to ECR"
        }
        
        echo "📥 Pulling Docker image: ${ECR_URI}"
        $DOCKER_CMD pull "${ECR_URI}" || {
            handle_error 4 "Failed to pull Docker image: ${ECR_URI}"
        }
    fi
    
    # Clean up any existing container with the same name
    if [ "$($DOCKER_CMD ps -a -q -f name=^/${CONTAINER_NAME}$)" ]; then
        echo "🧹 Removing existing container: ${CONTAINER_NAME}"
        $DOCKER_CMD rm -f ${CONTAINER_NAME}
    fi
    
    # Update status
    cat > "/tmp/container_status.json" << EOF
{
    "status": "starting_container",
    "pid": $$,
    "start_time": "$(date -Iseconds)",
    "container_name": "$CONTAINER_NAME"
}
EOF

    # Show the Docker command being executed
    echo "🔍 Running Docker command:"
    echo "$DOCKER_CMD run --name ${CONTAINER_NAME} -d ${PORT_MAPPING} ${VOLUME_MAPPING} ${ENV_VARS} ${EXTRA_ARGS} ${ECR_URI}"

    # Run container with IAM role
    echo "🏃 Starting Docker container: ${CONTAINER_NAME}"
    CONTAINER_ID=$($DOCKER_CMD run --name "${CONTAINER_NAME}" \
        -d \
        ${PORT_MAPPING} \
        ${VOLUME_MAPPING} \
        ${ENV_VARS} \
        ${EXTRA_ARGS} \
        "${ECR_URI}")
    
    if [ $? -eq 0 ]; then
        echo "✅ Container started with ID: ${CONTAINER_ID}"
        
        # Wait a moment for container to initialize
        sleep 3
        
        # Check if container is still running
        if ! $DOCKER_CMD ps -q -f "name=${CONTAINER_NAME}" | grep -q .; then
            echo "❌ Container stopped immediately after starting!"
            echo "🔍 Container logs:"
            $DOCKER_CMD logs "${CONTAINER_NAME}"
            echo "🔍 Container exit code:"
            $DOCKER_CMD inspect "${CONTAINER_NAME}" --format='{{.State.ExitCode}}'
            handle_error 5 "Container exited immediately"
        fi
        
        # Update status
        cat > "/tmp/container_status.json" << EOF
{
    "status": "container_running",
    "pid": $$,
    "container_id": "$CONTAINER_ID",
    "container_name": "$CONTAINER_NAME",
    "start_time": "$(date -Iseconds)"
}
EOF
    else
        handle_error 5 "Failed to start container"
    fi
    
    # Follow logs if requested
    if [ "${FOLLOW_LOGS:-true}" = "true" ]; then
        echo "📋 Following container logs... (Container will continue running)"
        $DOCKER_CMD logs -f ${CONTAINER_NAME} &
        LOGS_PID=$!
        
        # Handle Ctrl+C gracefully
        trap "kill $LOGS_PID 2>/dev/null || true; echo '📋 Stopped following logs, container still running'" INT
        wait $LOGS_PID 2>/dev/null || true
        trap - INT
    fi
    
    # Wait for container completion (NO TIMEOUT - will wait indefinitely)
    if [ "${WAIT_FOR_EXIT:-true}" = "true" ]; then
        echo "⏳ Waiting for container to complete (no timeout)..."
        
        # Simple wait with periodic status updates every 5 minutes
        while $DOCKER_CMD ps -q -f "name=${CONTAINER_NAME}" | grep -q .; do
            sleep 300  # 5 minutes
            echo "⏱️ Container still running at $(date)..."
        done
        
        # Get final status
        EXIT_CODE=$($DOCKER_CMD inspect ${CONTAINER_NAME} --format='{{.State.ExitCode}}')
        echo "✅ Container completed with exit code: ${EXIT_CODE}"
        
        # Show final logs if not already following
        if [ "${FOLLOW_LOGS:-true}" != "true" ]; then
            echo "📋 Final container logs:"
            $DOCKER_CMD logs --tail 50 ${CONTAINER_NAME}
        fi
        
        # Update final status
        cat > "/tmp/container_status.json" << EOF
{
    "status": "completed",
    "pid": $$,
    "container_id": "$CONTAINER_ID",
    "exit_code": $EXIT_CODE,
    "end_time": "$(date -Iseconds)"
}
EOF
        
        # Cleanup
        if [ "${AUTO_CLEANUP:-true}" = "true" ]; then
            echo "🧹 Cleaning up container..."
            $DOCKER_CMD rm -f "${CONTAINER_NAME}"
            
            if [ "${CLEANUP_VOLUMES:-false}" = "true" ]; then
                echo "🧹 Cleaning up Docker volumes..."
                $DOCKER_CMD volume prune -f
                $DOCKER_CMD image prune -f
            fi
        fi
        
        # Clean up lock file
        rm -f "$LOCK_FILE"
        
        echo "🎉 Job completed successfully!"
        
        # AUTO-SHUTDOWN: Shutdown EC2 instance if enabled
        if [ "${AUTO_SHUTDOWN:-true}" = "true" ]; then
            echo ""
            echo "🛑 AUTO-SHUTDOWN ENABLED"
            echo "Container job completed, initiating EC2 instance shutdown..."
            shutdown_ec2_instance 30  # 30 second delay to allow logs to be written
        else
            echo "⚠️ Auto-shutdown disabled. Instance will remain running."
        fi
        
        return $EXIT_CODE
    fi
}