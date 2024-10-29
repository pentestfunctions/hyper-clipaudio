#!/bin/bash

# Path to the Python script
SCRIPT_PATH="/opt/hyper-clipaudio/server.py"

# Function to kill process and children
kill_process() {
    local pid=$1
    local children=$(pgrep -P $pid)
    
    # Kill children first
    for child in $children; do
        kill_process $child
    done
    
    # Kill parent
    kill -TERM $pid 2>/dev/null || true
}

# Function to check if script is running
is_running() {
    pgrep -f "python3.*$SCRIPT_PATH" > /dev/null
    return $?
}

# Kill existing instance if running
if is_running; then
    # Get the PID of the running script
    PID=$(pgrep -f "python3.*$SCRIPT_PATH")
    kill_process $PID
    
    # Wait for process to die
    count=0
    while is_running && [ $count -lt 10 ]; do
        sleep 0.5
        count=$((count + 1))
    done
    
    # Force kill if still running
    if is_running; then
        pkill -9 -f "python3.*$SCRIPT_PATH"
    fi
fi

# Set up environment
export HOME=/home/robot
export DISPLAY=:0
export XAUTHORITY=/home/robot/.Xauthority
export XDG_RUNTIME_DIR=/run/user/1000
export PYTHONUNBUFFERED=1

# Start the script
exec python3 $SCRIPT_PATH
