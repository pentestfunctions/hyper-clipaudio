#!/bin/bash

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored status messages
print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_error() {
    echo -e "${RED}[!]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[*]${NC} $1"
}

# Function to cleanup previous installations
cleanup_previous_install() {
    print_status "Cleaning up previous installation..."
    
    # Stop any running service
    if systemctl is-active --quiet hyper-clipaudio; then
        print_status "Stopping existing service..."
        systemctl stop hyper-clipaudio
    fi
    
    # Disable the service
    if systemctl is-enabled --quiet hyper-clipaudio 2>/dev/null; then
        print_status "Disabling existing service..."
        systemctl disable hyper-clipaudio
    fi
    
    # Remove service file
    if [ -f "/etc/systemd/system/hyper-clipaudio.service" ]; then
        print_status "Removing existing service file..."
        rm -f /etc/systemd/system/hyper-clipaudio.service
    fi
    
    # Remove any remaining service files
    find /etc/systemd/system -name "hyper-clipaudio*.service" -exec rm -f {} \;
    
    # Clean up systemd
    print_status "Cleaning up systemd..."
    systemctl daemon-reload
    systemctl reset-failed
    
    # Remove old installation files
    if [ -d "/opt/hyper-clipaudio" ]; then
        print_status "Removing old installation files..."
        rm -rf /opt/hyper-clipaudio
    fi
    
    # Clean up log files but keep the directory
    if [ -d "/var/log/hyper-clipaudio" ]; then
        print_status "Cleaning up old log files..."
        rm -f /var/log/hyper-clipaudio/*
    fi
    
    # Kill any remaining processes
    print_status "Checking for remaining processes..."
    pkill -f "hyper-clipaudio"
    
    print_status "Cleanup complete!"
}

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root"
    exit 1
fi

# Get the actual user who ran the script with sudo
ACTUAL_USER=$(who am i | awk '{print $1}')
if [ -z "$ACTUAL_USER" ]; then
    ACTUAL_USER=$SUDO_USER
fi

if [ -z "$ACTUAL_USER" ]; then
    print_error "Could not determine the actual user"
    exit 1
fi

USER_ID=$(id -u $ACTUAL_USER)
USER_HOME=$(eval echo ~$ACTUAL_USER)

print_status "Installing for user: $ACTUAL_USER (UID: $USER_ID)"

# Run cleanup
cleanup_previous_install

# Rest of your installation script continues here...
[Previous installation script content goes here]
