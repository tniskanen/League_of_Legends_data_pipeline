#!/bin/bash

# Package script for EC2 deployment
# This script creates a deployment package with all necessary files

set -e

echo "📦 Creating EC2 deployment package..."

# Create scripts directory if it doesn't exist
mkdir -p scripts

# Copy the original run.sh to scripts directory (for backup)
if [ -f "run.sh" ]; then
    echo "📋 Backing up original run.sh..."
    cp run.sh run.sh.backup
fi

# Make all scripts executable
chmod +x scripts/*.sh
chmod +x *.sh

echo "✅ Package created successfully!"
echo ""
echo "📋 Deployment files:"
echo "   - scripts/run.sh (main orchestration)"
echo "   - scripts/utils.sh (utility functions)"
echo "   - scripts/functions.sh (business logic)"
echo "   - starter.sh (SSM starter)"
echo "   - build.sh (Docker build)"
echo "   - deploy.sh (EC2 deployment)"
echo ""
echo "🚀 To deploy:"
echo "   scp -r scripts/ ec2-user@your-instance:/home/ec2-user/"
echo "   scp starter.sh build.sh deploy.sh ec2-user@your-instance:/home/ec2-user/"
echo "   scp ec2.env ec2-user@your-instance:/home/ec2-user/" 