#!/bin/bash

# Print status message
echo "Starting/Restarting Audio Clipboard"

# Create directory if it doesn't exist
mkdir -p /opt/hyper-clipaudio

# Kill any existing instances
pkill -f "python3 /opt/hyper-clipaudio/server.py"

# Check if the server file exists, if not download it
if [ ! -f "/opt/hyper-clipaudio/server.py" ]; then
    curl -s https://raw.githubusercontent.com/pentestfunctions/hyper-clipaudio/refs/heads/main/linux_listener.py -o /opt/hyper-clipaudio/server.py
fi

# Start the process in background
nohup python3 /opt/hyper-clipaudio/server.py > /dev/null 2>&1 &

# Exit successfully
exit 0
