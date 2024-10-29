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

USER_ID=$(id -u $ACTUAL_USER)
USER_HOME=$(eval echo ~$ACTUAL_USER)

print_status "Installing for user: $ACTUAL_USER (UID: $USER_ID)"

# Install required packages
print_status "Installing required packages..."
pacman -Sq --noconfirm python python-pip xsel pulseaudio pulseaudio-alsa alsa-utils portaudio || {
    print_error "Failed to install required packages"
    exit 1
}

# Install PyAudio using pip
print_status "Installing PyAudio using pip..."
sudo -u $ACTUAL_USER pip install --user pyaudio || {
    print_error "Failed to install PyAudio"
    exit 1
}

# Create required directories
print_status "Creating required directories..."
mkdir -p /opt/hyper-clipaudio
mkdir -p /var/log/hyper-clipaudio
mkdir -p /run/user/${USER_ID}/pulse
chown -R $ACTUAL_USER:$ACTUAL_USER /var/log/hyper-clipaudio
chown -R $ACTUAL_USER:$ACTUAL_USER /run/user/${USER_ID}

# Download the script
print_status "Downloading latest version of the server script..."
curl -s https://raw.githubusercontent.com/pentestfunctions/hyper-clipaudio/main/linux_listener.py > /opt/hyper-clipaudio/server.py || {
    print_error "Failed to download server script"
    exit 1
}

# Make script executable
chmod +x /opt/hyper-clipaudio/server.py
chown -R $ACTUAL_USER:$ACTUAL_USER /opt/hyper-clipaudio

# Create wrapper script to set up environment
print_status "Creating wrapper script..."
cat > /opt/hyper-clipaudio/run_server.sh << EOL
#!/bin/bash
export HOME="${USER_HOME}"
export XDG_RUNTIME_DIR="/run/user/${USER_ID}"
export PULSE_RUNTIME_PATH="/run/user/${USER_ID}/pulse"
export PULSE_SERVER="unix:/run/user/${USER_ID}/pulse/native"
export PATH="\$PATH:${USER_HOME}/.local/bin"
export PYTHONPATH="${USER_HOME}/.local/lib/python3.12/site-packages:\$PYTHONPATH"

# Start pulseaudio if not running
pulseaudio --check || pulseaudio --start --log-target=syslog

# Wait for PulseAudio to be ready
sleep 2

# Run the server
exec python /opt/hyper-clipaudio/server.py
EOL

chmod +x /opt/hyper-clipaudio/run_server.sh
chown $ACTUAL_USER:$ACTUAL_USER /opt/hyper-clipaudio/run_server.sh

# Create systemd service file
print_status "Creating systemd service..."
cat > /etc/systemd/system/hyper-clipaudio.service << EOL
[Unit]
Description=Unified Clipboard and Audio Server
After=network.target sound.target
Wants=network.target sound.target

[Service]
Type=simple
User=$ACTUAL_USER
Group=audio
Environment=DISPLAY=:0
Environment=XAUTHORITY=${USER_HOME}/.Xauthority
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_ID}/bus
WorkingDirectory=/opt/hyper-clipaudio
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

# Add user to required groups
usermod -a -G audio,pulse,pulse-access $ACTUAL_USER

# Ensure proper permissions for XDG_RUNTIME_DIR
mkdir -p /run/user/${USER_ID}
chmod 700 /run/user/${USER_ID}
chown $ACTUAL_USER:$ACTUAL_USER /run/user/${USER_ID}

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

print_warning "Make sure these ports are allowed through your firewall!"
print_warning "If you experience issues, try the following:"
echo "1. Check service status: systemctl status hyper-clipaudio"
echo "2. Check logs: journalctl -u hyper-clipaudio"
echo "3. Check audio devices: pactl list sources"
echo "4. Manually run: /opt/hyper-clipaudio/run_server.sh"
