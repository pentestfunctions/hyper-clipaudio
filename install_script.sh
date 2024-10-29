#!/bin/bash

# Print status message
echo "Starting/Restarting Audio Clipboard"

# Ensure screen is installed
if ! command -v screen &> /dev/null; then
    echo "Screen is not installed. Installing screen..."
    if command -v apt &> /dev/null; then
        sudo apt install -y screen
    elif command -v yum &> /dev/null; then
        sudo yum install -y screen
    else
        echo "Could not install screen. Please install it manually."
        exit 1
    fi
fi

# Create directory if it doesn't exist
mkdir -p /opt/hyper-clipaudio

# Kill any existing screen sessions and processes
screen -ls | grep "audio-clipboard" | cut -d. -f1 | awk '{print $1}' | xargs -I % screen -X -S % quit > /dev/null 2>&1
pkill -f "python3 /opt/hyper-clipaudio/server.py"

# Check if the server file exists, if not download it
if [ ! -f "/opt/hyper-clipaudio/server.py" ]; then
    curl -s https://raw.githubusercontent.com/pentestfunctions/hyper-clipaudio/refs/heads/main/linux_listener.py -o /opt/hyper-clipaudio/server.py
fi

# Start the process in a new screen session
screen -dmS audio-clipboard python3 /opt/hyper-clipaudio/server.py

# Verify the process is running
if screen -ls | grep -q "audio-clipboard"; then
    echo "Audio Clipboard is running in background"
else
    echo "Failed to start Audio Clipboard"
    exit 1
fi

# Exit successfully
exit 0
