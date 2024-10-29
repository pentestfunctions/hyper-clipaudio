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

# Function to get current groups for user
get_current_groups() {
    local user=$1
    groups $user | cut -d: -f2 | sed 's/^[ \t]*//'
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

# Store current groups
CURRENT_GROUPS=$(get_current_groups $ACTUAL_USER)

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

[Previous service file and wrapper script creation remains the same...]

# Add user to required groups WITHOUT logging out
print_status "Setting up group permissions..."
for group in audio pulse pulse-access; do
    if ! echo $CURRENT_GROUPS | grep -q "\b$group\b"; then
        usermod -a -G $group $ACTUAL_USER
        print_warning "Added user to $group group"
    fi
done

# Create a temporary group activation script
print_status "Creating temporary group activation..."
cat > /opt/hyper-clipaudio/activate_groups.sh << EOL
#!/bin/bash
exec sg audio -c "sg pulse -c \"sg pulse-access -c '/opt/hyper-clipaudio/run_server.sh'\""
EOL

chmod +x /opt/hyper-clipaudio/activate_groups.sh
chown $ACTUAL_USER:$ACTUAL_USER /opt/hyper-clipaudio/activate_groups.sh

# Update the service file to use the group activation script
sed -i "s|ExecStart=.*|ExecStart=/opt/hyper-clipaudio/activate_groups.sh|" /etc/systemd/system/hyper-clipaudio.service

# Set up PulseAudio configuration
print_status "Setting up PulseAudio configuration..."
sudo -u $ACTUAL_USER mkdir -p ${USER_HOME}/.config/pulse
cat > ${USER_HOME}/.config/pulse/client.conf << EOL
autospawn = yes
daemon-binary = /usr/bin/pulseaudio
EOL
chown -R $ACTUAL_USER:$ACTUAL_USER ${USER_HOME}/.config/pulse

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
print_warning "NOTE: Group changes have been applied but will take full effect after your next login"
print_warning "The service will work now, but for complete functionality, consider logging out and back in when convenient"
