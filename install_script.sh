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

# Function to verify file creation
verify_file() {
    if [ ! -f "$1" ]; then
        handle_error "Failed to create file: $1"
    fi
    print_status "Successfully created: $1"
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

# Create required directories
print_status "Creating required directories..."
mkdir -p /opt/hyper-clipaudio
mkdir -p /var/log/hyper-clipaudio
mkdir -p /run/user/${USER_ID}/pulse

# Install required packages
print_status "Installing required packages..."
pacman -Sq --noconfirm python python-pip xsel pulseaudio pulseaudio-alsa alsa-utils portaudio || \
    handle_error "Failed to install required packages"

# Install PyAudio using pip
print_status "Installing PyAudio using pip..."
sudo -u $ACTUAL_USER pip install --user pyaudio || \
    handle_error "Failed to install PyAudio"

# Create the server script
print_status "Creating server script..."
mkdir -p /opt/hyper-clipaudio
curl -s https://raw.githubusercontent.com/pentestfunctions/hyper-clipaudio/main/linux_listener.py > /opt/hyper-clipaudio/server.py
verify_file "/opt/hyper-clipaudio/server.py"
chmod +x /opt/hyper-clipaudio/server.py

# Create the wrapper script
print_status "Creating wrapper script..."
cat > /opt/hyper-clipaudio/run_server.sh << 'EOL'
#!/bin/bash

# Enable error reporting
set -e
set -o pipefail

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/hyper-clipaudio/debug.log
}

# Error handler
handle_error() {
    log "Error on line $1"
    exit 1
}

trap 'handle_error $LINENO' ERR

log "Starting server wrapper script"
log "Current user: $(whoami)"
log "Current directory: $(pwd)"

# Start the server
exec python /opt/hyper-clipaudio/server.py 2>&1
EOL

verify_file "/opt/hyper-clipaudio/run_server.sh"
chmod +x /opt/hyper-clipaudio/run_server.sh

# Create the systemd service file
print_status "Creating systemd service file..."
cat > /etc/systemd/system/hyper-clipaudio.service << EOL
[Unit]
Description=Unified Clipboard and Audio Server
After=network.target sound.target
Wants=network.target sound.target

[Service]
Type=simple
User=${ACTUAL_USER}
Group=audio
Environment=DISPLAY=:0
Environment=XAUTHORITY=${USER_HOME}/.Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/${USER_ID}
Environment=HOME=${USER_HOME}
Environment=PULSE_SERVER=unix:/run/user/${USER_ID}/pulse/native
Environment=PULSE_RUNTIME_PATH=/run/user/${USER_ID}/pulse
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:${USER_HOME}/.local/bin
Environment=PYTHONPATH=${USER_HOME}/.local/lib/python3.12/site-packages
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=/opt/hyper-clipaudio

ExecStartPre=/bin/mkdir -p /run/user/${USER_ID}/pulse
ExecStartPre=/bin/chown -R ${ACTUAL_USER}:${ACTUAL_USER} /run/user/${USER_ID}
ExecStartPre=/bin/chmod -R 700 /run/user/${USER_ID}
ExecStart=/opt/hyper-clipaudio/run_server.sh

Restart=always
RestartSec=30
StartLimitInterval=300
StartLimitBurst=5

StandardOutput=append:/var/log/hyper-clipaudio/stdout.log
StandardError=append:/var/log/hyper-clipaudio/stderr.log

[Install]
WantedBy=multi-user.target
EOL

verify_file "/etc/systemd/system/hyper-clipaudio.service"

# Set correct permissions
print_status "Setting permissions..."
chown -R $ACTUAL_USER:$ACTUAL_USER /opt/hyper-clipaudio
chown -R $ACTUAL_USER:$ACTUAL_USER /var/log/hyper-clipaudio
chown -R $ACTUAL_USER:$ACTUAL_USER /run/user/${USER_ID}
chmod 755 /var/log/hyper-clipaudio
chmod 700 /run/user/${USER_ID}

# Add user to required groups
print_status "Adding user to required groups..."
usermod -a -G audio,pulse,pulse-access $ACTUAL_USER

# Set up PulseAudio configuration
print_status "Setting up PulseAudio configuration..."
mkdir -p ${USER_HOME}/.config/pulse
cat > ${USER_HOME}/.config/pulse/client.conf << EOL
autospawn = yes
daemon-binary = /usr/bin/pulseaudio
EOL
chown -R $ACTUAL_USER:$ACTUAL_USER ${USER_HOME}/.config/pulse

# Reload systemd
print_status "Reloading systemd daemon..."
systemctl daemon-reload

# Enable and start the service
print_status "Enabling and starting service..."
systemctl enable hyper-clipaudio
systemctl start hyper-clipaudio

# Wait for service to start
sleep 3

# Verify service creation and status
if [ ! -f "/etc/systemd/system/hyper-clipaudio.service" ]; then
    print_error "Service file was not created properly"
    exit 1
fi

# Check service status
if systemctl is-active --quiet hyper-clipaudio; then
    print_status "Service successfully started!"
else
    print_warning "Service failed to start. Checking logs..."
    journalctl -u hyper-clipaudio -n 50 --no-pager
fi

print_status "Installation complete!"
print_status "Service status:"
systemctl status hyper-clipaudio

print_warning "You can manage the service using:"
echo "  systemctl status hyper-clipaudio    # Check status"
echo "  systemctl restart hyper-clipaudio   # Restart service"
echo "  journalctl -u hyper-clipaudio -f    # View logs"
echo ""
print_status "Current port configuration:"
echo "Audio Port: 5001"
echo "Clipboard Port: 12345"

print_warning "If the service isn't working correctly, try:"
echo "1. Check service status: systemctl status hyper-clipaudio"
echo "2. View logs: journalctl -u hyper-clipaudio -f"
echo "3. Check log files in /var/log/hyper-clipaudio/"
echo "4. Consider logging out and back in for group changes to take effect"
