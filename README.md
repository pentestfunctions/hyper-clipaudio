# Windows Machine Requirements


# For Debian/Ubuntu-based systems:
```
sudo apt-get update
sudo apt-get install python3-pip
sudo apt-get install portaudio19-dev
sudo apt-get install xclip
sudo apt-get install pulseaudio
```

# For Arch Linux:
```
sudo pacman -S python-pip
sudo pacman -S python-pyaudio
sudo pacman -S portaudio
sudo pacman -S xclip
sudo pacman -S pulseaudio
```
Then run `python linux.py`


# For the host client
```
pip install pywin32
pip install pyaudio
```

Then run `python windows.py $IP` 
