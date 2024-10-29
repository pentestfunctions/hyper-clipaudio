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

# Get user ID for runtime directory
USER_ID=$(id -u $ACTUAL_USER)

print_status "Installing for user: $ACTUAL_USER (UID: $USER_ID)"

# Install required packages
print_status "Installing required packages..."
pacman -Sq --noconfirm python python-pyaudio python-pip xsel pulseaudio pulseaudio-alsa alsa-utils || {
    print_error "Failed to install required packages"
    exit 1
}

# Setup audio configuration
print_status "Setting up audio configuration..."

# Create pulse config directory
sudo -u $ACTUAL_USER mkdir -p /home/$ACTUAL_USER/.config/pulse

# Configure PulseAudio for the user
cat > /home/$ACTUAL_USER/.config/pulse/client.conf << EOL
# Connect to the system-wide PulseAudio server
default-server = unix:/run/user/${USER_ID}/pulse/native
autospawn = yes
daemon-binary = /usr/bin/pulseaudio
EOL

# Set proper ownership
chown -R $ACTUAL_USER:$ACTUAL_USER /home/$ACTUAL_USER/.config/pulse

# Create ALSA configuration if it doesn't exist
if [ ! -f "/home/$ACTUAL_USER/.asoundrc" ]; then
    cat > /home/$ACTUAL_USER/.asoundrc << EOL
pcm.!default {
    type pulse
}

ctl.!default {
    type pulse
}
EOL
    chown $ACTUAL_USER:$ACTUAL_USER /home/$ACTUAL_USER/.asoundrc
fi

# Create required directories
print_status "Creating required directories..."
mkdir -p /opt/hyper-clipaudio
mkdir -p /var/log/hyper-clipaudio
mkdir -p /run/user/${USER_ID}/pulse
chown -R $ACTUAL_USER:$ACTUAL_USER /var/log/hyper-clipaudio
chown -R $ACTUAL_USER:$ACTUAL_USER /run/user/${USER_ID}

# Download the latest version of the script
print_status "Downloading latest version of the server script..."
curl -s https://raw.githubusercontent.com/pentestfunctions/hyper-clipaudio/main/linux_listener.py > /opt/hyper-clipaudio/server.py || {
    print_error "Failed to download server script"
    exit 1
}

# Make script executable
chmod +x /opt/hyper-clipaudio/server.py
chown -R $ACTUAL_USER:$ACTUAL_USER /opt/hyper-clipaudio

# Create systemd service file
print_status "Creating systemd service..."
cat > /etc/systemd/system/hyper-clipaudio.service << EOL
[Unit]
Description=Unified Clipboard and Audio Server
After=network.target sound.target pulseaudio.service
Wants=network.target sound.target

[Service]
Type=simple
User=$ACTUAL_USER
Group=audio
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$ACTUAL_USER/.Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/${USER_ID}
Environment=PULSE_RUNTIME_PATH=/run/user/${USER_ID}/pulse
Environment=PULSE_SERVER=unix:/run/user/${USER_ID}/pulse/native
WorkingDirectory=/opt/hyper-clipaudio
ExecStartPre=/usr/bin/pulseaudio --start --log-target=syslog
ExecStart=/usr/bin/python /opt/hyper-clipaudio/server.py
Restart=always
RestartSec=30
StartLimitInterval=300
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOL

# Add user to required groups
usermod -a -G audio,pulse,pulse-access $ACTUAL_USER

# Start pulseaudio for the user
print_status "Starting PulseAudio..."
sudo -u $ACTUAL_USER pulseaudio --start

# Wait for PulseAudio to start
sleep 2

# Test audio setup
print_status "Testing audio setup..."
sudo -u $ACTUAL_USER pactl list short sources || print_warning "No audio sources found"

# Reload systemd daemon
print_status "Reloading systemd daemon..."
systemctl daemon-reload

# Enable and start the service
print_status "Enabling and starting service..."
systemctl enable hyper-clipaudio
systemctl start hyper-clipaudio

# Wait a moment for the service to start
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
print_status "Current port configuration:"
echo "Audio Port: 5001"
echo "Clipboard Port: 12345"
echo ""
print_warning "Make sure these ports are allowed through your firewall!"
print_warning "If you experience issues, try rebooting the system to ensure all audio services are properly initialized."
