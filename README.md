# 🔄 Hyper-ClipAudio

![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-lightgrey)
![Python Version](https://img.shields.io/badge/python-3.6%2B-blue)
![PowerShell Version](https://img.shields.io/badge/powershell-5.1%2B-blue)

> Restore clipboard synchronization and audio streaming functionality to Hyper-V basic sessions without compromising performance.

<p align="center">
  <img src="https://github.com/pentestfunctions/hyper-clipaudio/blob/main/images/demo.gif?raw=true">
</p>



https://github.com/user-attachments/assets/70ff3102-2544-44e3-b73c-b579b2ae726e



## 🎯 Overview

Hyper-ClipAudio is designed to bridge the functionality gap in Hyper-V basic sessions. While Enhanced sessions provide audio and clipboard support through RDP, they often come with performance penalties. This project enables these features in basic sessions while maintaining optimal performance.

### Features

- 🔊 Real-time audio streaming
- 📋 Bi-directional clipboard synchronization
- 📁 File transfer support (Needs contributor help)
- 🔄 Automatic reconnection
- 🖥️ System tray integration
- 📊 Connection status monitoring

> Mainly using pyaudio & xsel

## 🚀 Quick Start

### Linux (Host VM) Setup

1. Clone the repository:
```bash
git clone https://github.com/pentestfunctions/hyper-clipaudio
cd hyper-clipaudio
```

2. Install requirements:
```bash
# For Debian/Ubuntu-based systems (including Kali):
sudo apt update
sudo apt install -y python3-pip xsel
pip install pyaudio

# You can run ip a to find your IPv4 address or check your Hyper-V machine settings in the Hyper-V Manager for the IP

# For Arch Linux:
sudo pacman -S python-pip xsel pyaudio
```

3. Start the server:
```bash
python3 linux_listener.py
```

### Windows (Host) Setup

1. Download the `windows_connector.ps1` script
2. Ensure VLC is installed (script will auto-install using winget if missing)
3. Run the PowerShell script either by double clicking it or running in your terminal:
```powershell
powershell -ExecutionPolicy Bypass -File windows_connector.ps1
```

## 📋 Requirements

### Linux (Host VM)
```txt
pyaudio==0.2.13
```

### Windows (Host)
- PowerShell 5.1 or newer
- VLC Media Player (auto-installed if missing)
- Windows 10/11

## 🔧 Usage

### Linux Server (VM)

The Linux server runs two services:
- Audio streaming server (Port 5001)
- Clipboard synchronization server (Port 12345)

```bash
python3 linux_listener.py
```

The server will automatically:
- Create necessary directories
- Set up logging
- Start both services
- Monitor connections
- Handle client disconnections gracefully

### Windows Client

The Windows connector provides a GUI interface with system tray integration:

| Feature | Description |
|---------|-------------|
| 🔌 Connection | Enter VM's IP address and click "Start Services" |
| 🔄 System Tray | Right-click icon for quick actions |
| 📊 Status | Monitor connection status in real-time |
| 🛑 Disconnect | "Stop Services" or right-click tray icon |

#### System Tray Features:
- Double-click: Show/hide main window
- Right-click menu:
  - Show Window
  - Start Services
  - Stop Services
  - Exit

## 🔄 Automation

### Linux Side
- Automatic directory creation
- Logging rotation (5MB max file size, 5 backup files)
- Auto-reconnect handling
- Dead client cleanup

### Windows Side
- Automatic VLC installation using winget
- Background services with auto-reconnect
- Clipboard monitoring with update threshold
- File transfer handling
- System tray integration with auto-minimize

## 🛠️ Technical Details

### Port Usage
| Service | Port | Protocol |
|---------|------|----------|
| Audio Stream | 5001 | TCP |
| Clipboard Sync | 12345 | TCP |

### Audio Configuration
- Sample Rate: 44100 Hz
- Channels: 2 (Stereo)
- Format: 16-bit PCM
- Chunk Size: 1024 bytes

### Clipboard Features
- Text synchronization
- File transfer support
- Base64 encoding for binary data
- Compression for large transfers

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 🙏 Acknowledgments

- Thanks to VideoLAN for VLC media player
- PyAudio developers for audio streaming capabilities
- Windows PowerShell team for robust scripting support

## ⚠️ Notes

- Ensure firewall rules allow the specified ports (Should be fine by default due to hyper-v)
- Run in basic session mode
- Audio quality can be adjusted through VLC parameters
- Connection issues? Check network connectivity and firewall rules - ensure you can ping between your host and machine
