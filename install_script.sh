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
    print_error "Installation failed!"
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

# Stop any existing processes and clean up
print_status "Cleaning up existing installation..."
systemctl stop hyper-clipaudio 2>/dev/null || true
systemctl disable hyper-clipaudio 2>/dev/null || true
rm -f /etc/systemd/system/hyper-clipaudio.service
systemctl daemon-reload
systemctl reset-failed

# Stop any existing PulseAudio instances
sudo -u $ACTUAL_USER pkill pulseaudio || true
sleep 2

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

# Create ALSA configuration
print_status "Setting up ALSA configuration..."
cat > /etc/asound.conf << EOL
defaults.pcm.card 0
defaults.ctl.card 0
pcm.pulse {
    type pulse
}
ctl.pulse {
    type pulse
}
pcm.!default {
    type pulse
}
ctl.!default {
    type pulse
}
EOL

# Create PulseAudio configuration
print_status "Setting up PulseAudio configuration..."
sudo -u $ACTUAL_USER mkdir -p ${USER_HOME}/.config/pulse
cat > ${USER_HOME}/.config/pulse/client.conf << EOL
autospawn = yes
daemon-binary = /usr/bin/pulseaudio
EOL
chown -R $ACTUAL_USER:$ACTUAL_USER ${USER_HOME}/.config/pulse

cat > ${USER_HOME}/.config/pulse/daemon.conf << EOL
daemonize = yes
allow-module-loading = yes
allow-exit = yes
resample-method = speex-float-1
enable-remixing = yes
enable-lfe-remixing = no
flat-volumes = no
EOL

# Download the server script
print_status "Downloading server script..."
curl -s https://raw.githubusercontent.com/pentestfunctions/hyper-clipaudio/main/linux_listener.py > /opt/hyper-clipaudio/server.py || \
    handle_error "Failed to download server script"
chmod +x /opt/hyper-clipaudio/server.py
verify_file "/opt/hyper-clipaudio/server.py"

# Create wrapper script
print_status "Creating wrapper script..."
cat > /opt/hyper-clipaudio/run_server.sh << 'EOL'
#!/bin/bash

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/hyper-clipaudio/debug.log
}

# Ensure log directory exists
mkdir -p /var/log/hyper-clipaudio

log "Starting server wrapper"

# Function to check PulseAudio status
check_pulseaudio() {
    # Try to get PulseAudio info
    if pactl info >/dev/null 2>&1; then
        return 0  # PulseAudio is running
    else
        return 1  # PulseAudio is not running
    fi
}

# Initialize PulseAudio
log "Initializing PulseAudio..."

# Kill any existing PulseAudio processes
pulseaudio -k || true
sleep 1

# Start PulseAudio with specific configuration
pulseaudio --start --log-target=syslog --exit-idle-time=-1 --daemon 2>&1 | while read -r line; do
    log "PulseAudio: $line"
done

# Wait for PulseAudio to initialize
sleep 2

# Verify PulseAudio is working
retry_count=0
max_retries=5
while ! check_pulseaudio && [ $retry_count -lt $max_retries ]; do
    log "Waiting for PulseAudio to start (attempt $((retry_count + 1))/$max_retries)..."
    sleep 2
    retry_count=$((retry_count + 1))
done

if check_pulseaudio; then
    log "PulseAudio is operational"
else
    log "Failed to initialize PulseAudio after $max_retries attempts"
    exit 1
fi

# Load required PulseAudio modules
pactl load-module module-null-sink sink_name=virtual_speaker sink_properties=device.description=Virtual_Speaker || log "Warning: Failed to load null-sink module"
pactl load-module module-virtual-source source_name=virtual_mic || log "Warning: Failed to load virtual-source module"

# List audio devices
log "Available audio devices:"
pactl list short sources || log "No audio sources found"
pactl list short sinks || log "No audio sinks found"

# Start the server
log "Starting Python server..."
exec python /opt/hyper-clipaudio/server.py 2>&1
EOL

chmod +x /opt/hyper-clipaudio/run_server.sh
verify_file "/opt/hyper-clipaudio/run_server.sh"

# Create systemd service file
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
RuntimeDirectory=hyper-clipaudio
RuntimeDirectoryMode=0755

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

# Set up runtime directory
ExecStartPre=/bin/sh -c 'mkdir -p /run/user/${USER_ID}/pulse'
ExecStartPre=/bin/sh -c 'chown ${ACTUAL_USER}:${ACTUAL_USER} /run/user/${USER_ID}/pulse'
ExecStartPre=/bin/sh -c 'chmod 700 /run/user/${USER_ID}/pulse'

ExecStart=/opt/hyper-clipaudio/run_server.sh

Restart=on-failure
RestartSec=30
StartLimitInterval=300
StartLimitBurst=5

StandardOutput=append:/var/log/hyper-clipaudio/stdout.log
StandardError=append:/var/log/hyper-clipaudio/stderr.log

[Install]
WantedBy=multi-user.target
EOL

verify_file "/etc/systemd/system/hyper-clipaudio.service"

# Set permissions
print_status "Setting permissions..."
chown -R $ACTUAL_USER:$ACTUAL_USER /opt/hyper-clipaudio
chmod -R 755 /opt/hyper-clipaudio

# Add user to required groups
print_status "Adding user to required groups..."
usermod -a -G audio,pulse,pulse-access $ACTUAL_USER

# Create PulseAudio socket directory with correct permissions
mkdir -p /run/user/${USER_ID}/pulse
chown -R $ACTUAL_USER:$ACTUAL_USER /run/user/${USER_ID}
chmod -R 700 /run/user/${USER_ID}

# Ensure ALSA modules are loaded
print_status "Loading ALSA modules..."
modprobe snd-seq || print_warning "Failed to load snd-seq module"
modprobe snd-pcm || print_warning "Failed to load snd-pcm module"

# Reload systemd and start service
print_status "Starting service..."
systemctl daemon-reload
systemctl enable hyper-clipaudio
systemctl start hyper-clipaudio

# Wait for service to initialize
sleep 3

# Verify service
if systemctl is-active --quiet hyper-clipaudio; then
    print_status "Service successfully started!"
    systemctl status hyper-clipaudio
else
    print_warning "Service failed to start. Checking logs..."
    journalctl -u hyper-clipaudio -n 50 --no-pager
    
    print_warning "Attempting to diagnose issues..."
    print_status "PulseAudio status:"
    sudo -u $ACTUAL_USER pulseaudio --check || echo "PulseAudio not running"
    
    print_status "ALSA devices:"
    aplay -l || echo "No ALSA devices found"
    
    print_status "PulseAudio devices:"
    sudo -u $ACTUAL_USER pactl list || echo "No PulseAudio devices found"
fi

print_status "Installation complete!"
echo ""
print_status "Service management commands:"
echo "  systemctl status hyper-clipaudio    # Check status"
echo "  systemctl restart hyper-clipaudio   # Restart service"
echo "  journalctl -u hyper-clipaudio -f    # View logs"
echo ""
print_status "Port configuration:"
echo "  Audio Port: 5001"
echo "  Clipboard Port: 12345"
echo ""
print_warning "Troubleshooting steps if needed:"
echo "1. Check service status: systemctl status hyper-clipaudio"
echo "2. View logs: journalctl -u hyper-clipaudio -f"
echo "3. Check debug log: cat /var/log/hyper-clipaudio/debug.log"
echo "4. Test audio: pactl list sources"
echo "5. Try running manually: sudo -u $ACTUAL_USER /opt/hyper-clipaudio/run_server.sh"
echo "6. If needed, restart PulseAudio: pulseaudio -k && pulseaudio --start"
echo "7. Check ALSA configuration: cat /proc/asound/cards"
echo "8. Verify runtime directory: ls -la /run/user/${USER_ID}/pulse"
