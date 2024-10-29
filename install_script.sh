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

# Function to handle errors
handle_error() {
    print_error "$1"
    exit 1
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
    
    # Remove service files
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
    pkill -f "hyper-clipaudio" || true
    
    print_status "Cleanup complete!"
}

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    handle_error "Please run as root"
fi

# Get the actual user who ran the script with sudo
ACTUAL_USER=$(who am i | awk '{print $1}')
if [ -z "$ACTUAL_USER" ]; then
    ACTUAL_USER=$SUDO_USER
fi

if [ -z "$ACTUAL_USER" ]; then
    handle_error "Could not determine the actual user"
fi

USER_ID=$(id -u $ACTUAL_USER)
USER_HOME=$(eval echo ~$ACTUAL_USER)

print_status "Installing for user: $ACTUAL_USER (UID: $USER_ID)"

# Run cleanup
cleanup_previous_install

# Install required packages
print_status "Installing required packages..."
pacman -Sq --noconfirm python python-pip xsel pulseaudio pulseaudio-alsa alsa-utils portaudio || \
    handle_error "Failed to install required packages"

# Install PyAudio using pip
print_status "Installing PyAudio using pip..."
sudo -u $ACTUAL_USER pip install --user pyaudio || \
    handle_error "Failed to install PyAudio"

# Create required directories
print_status "Creating required directories..."
mkdir -p /opt/hyper-clipaudio
mkdir -p /var/log/hyper-clipaudio
mkdir -p /run/user/${USER_ID}/pulse
chown -R $ACTUAL_USER:$ACTUAL_USER /var/log/hyper-clipaudio
chown -R $ACTUAL_USER:$ACTUAL_USER /run/user/${USER_ID}
chmod 755 /var/log/hyper-clipaudio
chmod 700 /run/user/${USER_ID}

# Create service file
print_status "Creating systemd service..."
cat > /etc/systemd/system/hyper-clipaudio.service << EOL
[Unit]
Description=Unified Clipboard and Audio Server
After=network.target sound.target
Wants=network.target sound.target

[Service]
Type=simple
User=${ACTUAL_USER}
Group=audio
RuntimeDirectory=hyper-clipaudio
RuntimeDirectoryMode=0755
Environment=DISPLAY=:0
Environment=XAUTHORITY=${USER_HOME}/.Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/${USER_ID}
Environment=HOME=${USER_HOME}
Environment=PULSE_SERVER=unix:/run/user/${USER_ID}/pulse/native
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:${USER_HOME}/.local/bin
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=/opt/hyper-clipaudio

# Start PulseAudio if not running
ExecStartPre=/bin/sh -c 'mkdir -p /run/user/${USER_ID}/pulse'
ExecStartPre=/bin/sh -c 'chown -R ${ACTUAL_USER}:${ACTUAL_USER} /run/user/${USER_ID}'
ExecStartPre=/bin/sh -c 'chmod -R 700 /run/user/${USER_ID}'
ExecStartPre=/bin/sh -c '/usr/bin/pulseaudio --check || { /usr/bin/pulseaudio --start --log-target=syslog --exit-idle-time=-1 & sleep 2; }'

ExecStart=/usr/bin/bash -c '/opt/hyper-clipaudio/run_server.sh 2>&1 | tee -a /var/log/hyper-clipaudio/debug.log'
Restart=always
RestartSec=30
StartLimitInterval=300
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOL

# Create wrapper script
print_status "Creating wrapper script..."
cat > /opt/hyper-clipaudio/run_server.sh << EOL
#!/bin/bash

# Enable error reporting
set -e
set -o pipefail

# Log function
log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a /var/log/hyper-clipaudio/debug.log
}

# Error handler
handle_error() {
    log "Error on line \$1"
    exit 1
}

trap 'handle_error \$LINENO' ERR

# Ensure directories exist
log "Setting up directories..."
mkdir -p /run/user/${USER_ID}/pulse
chmod 700 /run/user/${USER_ID}
chown -R ${ACTUAL_USER}:${ACTUAL_USER} /run/user/${USER_ID}

# Set up environment
export HOME="${USER_HOME}"
export XDG_RUNTIME_DIR="/run/user/${USER_ID}"
export PULSE_RUNTIME_PATH="/run/user/${USER_ID}/pulse"
export PULSE_SERVER="unix:/run/user/${USER_ID}/pulse/native"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:${USER_HOME}/.local/bin:\$PATH"
export PYTHONPATH="${USER_HOME}/.local/lib/python3.12/site-packages:\$PYTHONPATH"
export PYTHONUNBUFFERED=1

# Log environment
log "Environment setup:"
log "HOME: \$HOME"
log "XDG_RUNTIME_DIR: \$XDG_RUNTIME_DIR"
log "PULSE_SERVER: \$PULSE_SERVER"
log "PATH: \$PATH"
log "PYTHONPATH: \$PYTHONPATH"

# Check PulseAudio
log "Checking PulseAudio status..."
if ! pulseaudio --check; then
    log "Starting PulseAudio..."
    pulseaudio --start --log-target=syslog --exit-idle-time=-1
    sleep 2
fi

# Verify PulseAudio is running
if pulseaudio --check; then
    log "PulseAudio is running"
else
    log "Failed to start PulseAudio"
    exit 1
fi

# Check audio devices
log "Checking audio devices..."
pactl list short sources || log "No audio sources found"

# Start the server with error logging
log "Starting Python server..."
exec python /opt/hyper-clipaudio/server.py 2>&1
EOL

# Set permissions
chmod +x /opt/hyper-clipaudio/run_server.sh
chown $ACTUAL_USER:$ACTUAL_USER /opt/hyper-clipaudio/run_server.sh

# Set up PulseAudio configuration
print_status "Setting up PulseAudio configuration..."
sudo -u $ACTUAL_USER mkdir -p ${USER_HOME}/.config/pulse
cat > ${USER_HOME}/.config/pulse/client.conf << EOL
autospawn = yes
daemon-binary = /usr/bin/pulseaudio
EOL
chown -R $ACTUAL_USER:$ACTUAL_USER ${USER_HOME}/.config/pulse

# Add user to required groups
print_status "Adding user to required groups..."
usermod -a -G audio,pulse,pulse-access $ACTUAL_USER

# Download the script
print_status "Downloading latest version of the server script..."
curl -s https://raw.githubusercontent.com/pentestfunctions/hyper-clipaudio/main/linux_listener.py > /opt/hyper-clipaudio/server.py || \
    handle_error "Failed to download server script"

chmod +x /opt/hyper-clipaudio/server.py
chown -R $ACTUAL_USER:$ACTUAL_USER /opt/hyper-clipaudio

# Reload systemd
print_status "Reloading systemd daemon..."
systemctl daemon-reload

# Start service
print_status "Starting service..."
systemctl enable hyper-clipaudio
systemctl start hyper-clipaudio

# Wait for service to start
sleep 3

# Check service status
if systemctl is-active --quiet hyper-clipaudio; then
    print_status "Service successfully started!"
    print_status "You can check the status using: systemctl status hyper-clipaudio"
    print_status "View logs using: journalctl -u hyper-clipaudio"
else
    print_warning "Service failed to start. Checking logs..."
    journalctl -u hyper-clipaudio -n 50 --no-pager
fi

print_status "Installation complete!"
print_status "You can manage the service using:"
echo "  systemctl status hyper-clipaudio    # Check status"
echo "  systemctl restart hyper-clipaudio   # Restart service"
echo "  journalctl -u hyper-clipaudio -f    # View logs"
echo ""
print_status "Current port configuration:"
echo "Audio Port: 5001"
echo "Clipboard Port: 12345"
echo ""
print_warning "Make sure these ports are allowed through your firewall!"
print_warning "If you experience issues, try:"
echo "1. Check service status: systemctl status hyper-clipaudio"
echo "2. Check logs: journalctl -u hyper-clipaudio"
echo "3. Check detailed logs: cat /var/log/hyper-clipaudio/debug.log"
echo "4. Check audio devices: pactl list sources"
echo "5. Manually run: /opt/hyper-clipaudio/run_server.sh"
echo "6. You may need to log out and back in for group changes to take effect"
