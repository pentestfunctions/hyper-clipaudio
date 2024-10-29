#!/bin/bash

# Function to detect OS
get_os() {
    if [ -f "/etc/arch-release" ]; then
        echo "arch"
    elif [ -f "/etc/debian_version" ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# Function to install dependencies
install_deps() {
    local os=$(get_os)
    echo "Installing required dependencies..."
    
    case $os in
        "arch")
            sudo pacman -S --noconfirm screen curl python
            ;;
        "debian")
            sudo apt update
            sudo apt install -y screen curl python3
            ;;
        *)
            echo "Unsupported operating system. Please install screen and curl manually."
            exit 1
            ;;
    esac
}

# Print status message
echo "Starting/Restarting Audio Clipboard"

# Check and install dependencies if needed
if ! command -v screen &> /dev/null || ! command -v curl &> /dev/null; then
    install_deps
fi

# Create directory if it doesn't exist
if ! mkdir -p /opt/hyper-clipaudio 2>/dev/null; then
    echo "Error: Failed to create directory. Please run with sudo."
    exit 1
fi

# Kill any existing screen sessions and processes
screen -ls | grep "audio-clipboard" | cut -d. -f1 | awk '{print $1}' | xargs -I % screen -X -S % quit > /dev/null 2>&1
pkill -f "python3 /opt/hyper-clipaudio/server.py" 2>/dev/null
pkill -f "python /opt/hyper-clipaudio/server.py" 2>/dev/null

# Check if the server file exists, if not download it
if [ ! -f "/opt/hyper-clipaudio/server.py" ]; then
    if ! curl -s https://raw.githubusercontent.com/pentestfunctions/hyper-clipaudio/refs/heads/main/linux_listener.py -o /opt/hyper-clipaudio/server.py; then
        echo "Error: Failed to download server script"
        exit 1
    fi
fi

# Start the process in a new screen session
# Use python3 for Debian and python for Arch
if [ "$(get_os)" = "debian" ]; then
    screen -dmS audio-clipboard python3 /opt/hyper-clipaudio/server.py
else
    screen -dmS audio-clipboard python /opt/hyper-clipaudio/server.py
fi

# Verify the process is running
if screen -ls | grep -q "audio-clipboard"; then
    echo "Audio Clipboard is running in background"
    echo "To view the running process: screen -r audio-clipboard"
    echo "To detach from view: Press Ctrl+A then D"
else
    echo "Failed to start Audio Clipboard"
    exit 1
fi

exit 0
