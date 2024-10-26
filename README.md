# Windows Machine Requirements

1. Python Packages (install via pip):
```bash
pip install pywin32      # For Windows clipboard operations
pip install pyaudio      # For audio handling
```

2. System Requirements:
- Python 3.6 or higher
- Working microphone (for audio features)
- Windows 10/11 (for clipboard API compatibility)

3. Additional Dependencies:
- Visual C++ Build Tools (required for PyAudio)
  - Download from: Visual Studio Build Tools installer
  - Select "Desktop Development with C++"
  - Or install minimal version via: `pip install pipwin` then `pipwin install pyaudio`

4. Environment Setup:
```python
# Required folder structure:
%USERPROFILE%/ClipboardSync/
%USERPROFILE%/ClipboardSync/logs/
```

```bash
# Create required directories
mkdir -p ~/ClipboardSync/logs
```
# Linux VM Requirements

1. System Packages:
```bash
# For Debian/Ubuntu-based systems:
sudo apt-get update
sudo apt-get install python3-pip
sudo apt-get install python3-pyaudio
sudo apt-get install portaudio19-dev
sudo apt-get install xclip
sudo apt-get install pulseaudio

# For Arch Linux:
sudo pacman -S python-pip
sudo pacman -S python-pyaudio
sudo pacman -S portaudio
sudo pacman -S xclip
sudo pacman -S pulseaudio
```

2. Python Packages:
```bash
pip3 install pyaudio
```

3. System Requirements:
- Python 3.6 or higher
- Working audio setup (for audio features)
- X11 display server (for clipboard operations)



# Testing Setup

1. Windows:
```powershell
# Check Python installation
python --version

# Test audio
python -c "import pyaudio; p = pyaudio.PyAudio(); print(p.get_device_count())"

# Test clipboard
python -c "import win32clipboard; win32clipboard.OpenClipboard(); win32clipboard.CloseClipboard()"
```

2. Linux:
```bash
# Check Python installation
python3 --version

# Test audio
python3 -c "import pyaudio; p = pyaudio.PyAudio(); print(p.get_device_count())"

# Test clipboard
xclip -selection clipboard -i <<< "test" && xclip -selection clipboard -o
```

# Running the Scripts

1. Windows:
```powershell
# From the script directory
python windows.py <linux_vm_ip>
```

2. Linux:
```bash
# From the script directory
python3 linux.py
```

# Troubleshooting

1. Common Windows Issues:
- PyAudio installation fails: Use `pipwin install pyaudio` instead
- Clipboard access denied: Run as administrator or check permissions
- Audio device not found: Check Windows sound settings

2. Common Linux Issues:
- xclip not found: Install using package manager
- Audio permission denied: Add user to audio group (`sudo usermod -a -G audio $USER`)
- PulseAudio not running: Start with `pulseaudio --start`

3. Network Issues:
- Check VM network settings (ensure it's on the same network as Windows host)
- Verify firewall rules are properly set
- Test connectivity: `ping <ip_address>`
