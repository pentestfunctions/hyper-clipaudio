param(
    [Parameter(Mandatory=$false)]
    [string]$ServerIP
)

# Hide the PowerShell Console
Add-Type -Name Window -Namespace Console -MemberDefinition '
[DllImport("Kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'
$consolePtr = [Console.Window]::GetConsoleWindow()
[Console.Window]::ShowWindow($consolePtr, 0) # 0 = hide


if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
        $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
        Start-Process -FilePath PowerShell.exe -Verb Runas -ArgumentList $CommandLine
        Exit
    }
}

# Load Windows Forms assembly
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region Variables
$vlcPath = "C:\Program Files\VideoLAN\VLC\vlc.exe"
$verbose = $true
$DebugPreference = "Continue"
$syncDir = Join-Path $env:USERPROFILE "ClipboardSync"
$clipboardPort = 12345  # Hardcoded clipboard sync port
$audioPort = 5001       # Audio streaming port

# UI Constants
$WINDOW_WIDTH = 500
$WINDOW_HEIGHT = 400
$PADDING = 20
$CONTROL_HEIGHT = 35
$BUTTON_HEIGHT = 45
#endregion

# Create sync directory if it doesn't exist
if (-not (Test-Path $syncDir)) {
    New-Item -ItemType Directory -Path $syncDir | Out-Null
    Write-DebugLog "Created sync directory at $syncDir" "INFO"
}

#region Functions
function Write-DebugLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $color = switch($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "INFO"  { "White" }
        "DEBUG" { "Gray" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Write-VerboseOutput {
    param($Message)
    if ($verbose) {
        Write-Host "[DEBUG] $Message"
    }
}

function Check-VLCInstalled {
    return Test-Path $vlcPath
}

function Install-VLC {
    Write-VerboseOutput "VLC is not installed. Attempting to install using winget..."
    try {
        Start-Process -FilePath "winget" -ArgumentList "install", "VideoLAN.VLC" -Wait -NoNewWindow
        Write-Host "VLC installation completed."
    } catch {
        Write-Host "Failed to install VLC: $_"
    }
}

function Test-StreamConnection {
    param($IP, $Port)
    Write-VerboseOutput "Testing connection to ${IP}:${Port}..."
    
    try {
        $testConnection = Test-NetConnection -ComputerName $IP -Port $Port -WarningAction SilentlyContinue
        return $testConnection.TcpTestSucceeded
    } catch {
        Write-VerboseOutput "Connection test failed: $_"
        return $false
    }
}

function Start-PersistentAudioStream {
    param($ServerIP, $AudioPort, $VLCPath)
    
    Start-Job -ScriptBlock {
        param($ServerIP, $AudioPort, $VLCPath)
        
        $streamUrl = "tcp://${ServerIP}:${AudioPort}"
        $reconnectDelay = 1
        
        while ($true) {
            try {
                # Test connection before starting VLC
                $testConnection = Test-NetConnection -ComputerName $ServerIP -Port $AudioPort -WarningAction SilentlyContinue
                
                if ($testConnection.TcpTestSucceeded) {
                    $vlcArgs = @(
                        "--intf", "dummy",
                        "--no-video",
                        "--demux", "rawaud",
                        "--rawaud-channels", "2",
                        "--rawaud-samplerate", "44100",
                        "--rawaud-fourcc", "s16l",
                        "--network-caching", "50",
                        "--live-caching", "50",
                        "--sout-mux-caching", "50",
                        $streamUrl
                    )
                    
                    $process = Start-Process -FilePath $VLCPath -ArgumentList $vlcArgs -PassThru -NoNewWindow
                    
                    # Monitor the VLC process
                    while (!$process.HasExited) {
                        Start-Sleep -Seconds 1
                        $testConnection = Test-NetConnection -ComputerName $ServerIP -Port $AudioPort -WarningAction SilentlyContinue
                        if (!$testConnection.TcpTestSucceeded) {
                            $process.Kill()
                            break
                        }
                    }
                }
            }
            catch {
                Write-Host "Audio connection error: $_"
            }
            
            # Cleanup and wait before retry
            Get-Process vlc -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq $process.Id } | Stop-Process -Force
            Start-Sleep -Seconds $reconnectDelay
        }
    } -ArgumentList $ServerIP, $AudioPort, $VLCPath
}

function Kill-AllVLC {
    Get-Process vlc -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host "All VLC processes have been killed."
}

# Colors
$darkBlue = [System.Drawing.Color]::FromArgb(45, 66, 99)
$lightBlue = [System.Drawing.Color]::FromArgb(92, 164, 169)
$titleBarColor = [System.Drawing.Color]::FromArgb(35, 50, 75)
$buttonColor = [System.Drawing.Color]::FromArgb(65, 105, 225)
$hoverColor = [System.Drawing.Color]::FromArgb(70, 130, 255)
$white = [System.Drawing.Color]::White

function Show-MainForm {

    # Create the form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Audio Clipboard Sync"
    $form.Size = New-Object System.Drawing.Size(400, 300)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = $darkBlue
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.MaximizeBox = $false
    $form.Padding = New-Object System.Windows.Forms.Padding(0)
    $form.ShowInTaskbar = $true
    $form.MinimizeBox = $true

    # Create NotifyIcon (System Tray Icon)
    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Visible = $true
    $notifyIcon.Text = "Audio Clipboard Sync"
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information

    # Create context menu for NotifyIcon
    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

    # Status menu item (non-clickable)
    $statusMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusMenuItem.Text = "Status: Disconnected"
    $statusMenuItem.Enabled = $false
    $contextMenu.Items.Add($statusMenuItem)

    $separator = New-Object System.Windows.Forms.ToolStripSeparator
    $contextMenu.Items.Add($separator)

    $showMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $showMenuItem.Text = "Show Window"
    $contextMenu.Items.Add($showMenuItem)

    $exitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitMenuItem.Text = "Exit"
    $contextMenu.Items.Add($exitMenuItem)

    # Assign context menu to notify icon
    $notifyIcon.ContextMenuStrip = $contextMenu

    $titleBar = New-Object System.Windows.Forms.Panel
    $titleBar.Size = New-Object System.Drawing.Size(400, 30)
    $titleBar.Location = New-Object System.Drawing.Point(0, 0)
    $titleBar.BackColor = $titleBarColor
    $form.Controls.Add($titleBar)

    # Add drag
    $titleBar.Add_MouseDown({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:mouseDown = $true
            $script:lastLocation = $_.Location
        }
    })
    $titleBar.Add_MouseMove({
        if ($script:mouseDown) {
            $form.Location = New-Object System.Drawing.Point(
                ($form.Location.X + $_.X - $script:lastLocation.X),
                ($form.Location.Y + $_.Y - $script:lastLocation.Y))
        }
    })
    $titleBar.Add_MouseUp({ $script:mouseDown = $false })

    $titleText = New-Object System.Windows.Forms.Label
    $titleText.Text = "Audio Clipboard Sync"
    $titleText.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $titleText.ForeColor = $white
    $titleText.AutoSize = $true
    $titleText.Location = New-Object System.Drawing.Point(10, 7)
    $titleBar.Controls.Add($titleText)

    # Close button with Unicode
    $closeButton = New-Object System.Windows.Forms.Label
    $closeButton.Text = [char]0x2716
    $closeButton.Size = New-Object System.Drawing.Size(30, 30)
    $closeButton.Location = New-Object System.Drawing.Point(370, 0)
    $closeButton.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $closeButton.ForeColor = $white
    $closeButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $closeButton.Add_Click({ 
        $form.Hide()
        $notifyIcon.Visible = $true
        $notifyIcon.ShowBalloonTip(2000, "Audio Clipboard Sync", "Application minimized to tray", [System.Windows.Forms.ToolTipIcon]::Info)
    })
    $closeButton.Add_MouseEnter({ 
        $this.BackColor = [System.Drawing.Color]::Red
        $this.Cursor = [System.Windows.Forms.Cursors]::Hand
    })
    $closeButton.Add_MouseLeave({ 
        $this.BackColor = $titleBarColor
    })
    $titleBar.Controls.Add($closeButton)

    # Create minimize button with Unicode symbol
    $minimizeButton = New-Object System.Windows.Forms.Label
    $minimizeButton.Text = [char]0x2212
    $minimizeButton.Size = New-Object System.Drawing.Size(30, 30)
    $minimizeButton.Location = New-Object System.Drawing.Point(340, 0)
    $minimizeButton.Font = New-Object System.Drawing.Font("Segoe UI", 12)
    $minimizeButton.ForeColor = $white
    $minimizeButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $minimizeButton.Add_Click({ 
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
    })
    $minimizeButton.Add_MouseEnter({ 
        $this.BackColor = $hoverColor
        $this.Cursor = [System.Windows.Forms.Cursors]::Hand
    })
    $minimizeButton.Add_MouseLeave({ 
        $this.BackColor = $titleBarColor
    })
    $titleBar.Controls.Add($minimizeButton)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Audio Clipboard Sync"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $white
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(20, 50)
    $form.Controls.Add($titleLabel)

    $ipLabel = New-Object System.Windows.Forms.Label
    $ipLabel.Text = "Server IP Address"
    $ipLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $ipLabel.ForeColor = $white
    $ipLabel.AutoSize = $true
    $ipLabel.Location = New-Object System.Drawing.Point(20, 100)
    $form.Controls.Add($ipLabel)

    # Create ComboBox
    $comboBox = New-Object System.Windows.Forms.ComboBox
    $comboBox.Location = New-Object System.Drawing.Point(20, 130)
    $comboBox.Size = New-Object System.Drawing.Size(350, 30)
    $comboBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $comboBox.BackColor = $white
    $comboBox.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $form.Controls.Add($comboBox)

    # Create buttons
    function Create-StyledButton {
        param($text, $x, $y, $width = 100)
        
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $text
        $button.Location = New-Object System.Drawing.Point($x, $y)
        $button.Size = New-Object System.Drawing.Size($width, 35)
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.BackColor = $buttonColor
        $button.ForeColor = $white
        $button.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        $button.FlatAppearance.BorderSize = 0
        
        $button.Add_MouseEnter({
            $this.BackColor = $hoverColor
            $this.Cursor = [System.Windows.Forms.Cursors]::Hand
        })
        $button.Add_MouseLeave({
            $this.BackColor = $buttonColor
        })
        
        return $button
    }

    # Status label
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Status: Not Connected"
    $statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $statusLabel.ForeColor = [System.Drawing.Color]::Gray
    $statusLabel.AutoSize = $true
    $statusLabel.Location = New-Object System.Drawing.Point(20, 160)
    $form.Controls.Add($statusLabel)

    # Buttons
    $startButton = Create-StyledButton "Start" 20 190
    $stopButton = Create-StyledButton "Stop" 140 190
    $scanButton = Create-StyledButton "Scan" 260 190
    
    $form.Controls.Add($startButton)
    $form.Controls.Add($stopButton)
    $form.Controls.Add($scanButton)

    $comboBox.Add_SelectedIndexChanged({
        if ($comboBox.SelectedItem -and $comboBox.SelectedItem.ToString().Contains(": ")) {
            $selectedIP = ($comboBox.SelectedItem -split ': ')[1].Trim()
            $comboBox.Text = $selectedIP
        }
    })

    $scanButton.Add_Click({
        $comboBox.Items.Clear()
        try {
            if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
                throw "Hyper-V module not found. Please ensure Hyper-V is installed."
            }

            Import-Module Hyper-V -ErrorAction Stop
            $vms = Get-VM | Where-Object { $_.State -eq 'Running' }
            
            if ($vms.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show(
                    "No running Hyper-V virtual machines found.",
                    "VM Scan Result",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information)
                return
            }

            foreach ($vm in $vms) {
                $networkAdapter = Get-VMNetworkAdapter -VMName $vm.Name
                $ipv4Addresses = $networkAdapter.IPAddresses | 
                    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }
                
                if ($ipv4Addresses) {
                    foreach ($ip in $ipv4Addresses) {
                        $comboBox.Items.Add("$ip")
                    }
                }
            }

            if ($comboBox.Items.Count -gt 0) {
                $comboBox.SelectedIndex = 0
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "No IPv4 addresses found for running VMs.",
                    "VM Scan Result",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information)
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Error scanning Hyper-V VMs: $_",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })

    # Start button click handler
    $startButton.Add_Click({
        $script:ServerIP = $comboBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($ServerIP)) {
            [System.Windows.Forms.MessageBox]::Show("Please enter a server IP address.", "Error", 
                [System.Windows.Forms.MessageBoxButtons]::OK, 
                [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }

        # Start persistent audio stream
        $script:audioJob = Start-PersistentAudioStream -ServerIP $ServerIP -AudioPort $audioPort -VLCPath $vlcPath

        # Start clipboard sync in a separate runspace
        $script:runspace = [runspacefactory]::CreateRunspace()
        $script:runspace.ApartmentState = "STA"
        $script:runspace.ThreadOptions = "ReuseThread"
        $script:runspace.Open()

        $script:runspace.SessionStateProxy.SetVariable('ServerIP', $ServerIP)
        $script:runspace.SessionStateProxy.SetVariable('clipboardPort', $clipboardPort)
        $script:runspace.SessionStateProxy.SetVariable('syncDir', $syncDir)
        $script:runspace.SessionStateProxy.SetVariable('DebugPreference', $DebugPreference)
        
        $script:powershell = [powershell]::Create().AddScript({
            param($ServerIP, $ClipboardPort, $SyncDir)

            Add-Type -AssemblyName System.Windows.Forms

            function Write-DebugLog {
                param(
                    [string]$Message,
                    [string]$Level = "INFO"
                )
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
                $color = switch($Level) {
                    "ERROR" { "Red" }
                    "WARN"  { "Yellow" }
                    "INFO"  { "White" }
                    "DEBUG" { "Gray" }
                    default { "White" }
                }
                Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
            }

            function Read-NetworkStream {
                param([System.Net.Sockets.NetworkStream]$Stream)
                try {
                    $buffer = New-Object byte[] 4096
                    $data = New-Object System.Text.StringBuilder
                    $Stream.ReadTimeout = 100
                    do {
                        try {
                            $bytesRead = $Stream.Read($buffer, 0, $buffer.Length)
                            if ($bytesRead -gt 0) {
                                $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $bytesRead)
                                [void]$data.Append($text)
                                if ($text.Contains("`n")) { break }
                            }
                            else { break }
                        }
                        catch [System.IO.IOException] { break }
                    } while ($Stream.DataAvailable)
                    return $data.ToString()
                }
                catch {
                    Write-DebugLog "Error reading from network stream: $_" "ERROR"
                    throw
                }
            }

            $lastClipboard = ""
            $lastUpdate = Get-Date
            $updateThreshold = [TimeSpan]::FromMilliseconds(500)
            $client = $null
            $reconnectDelay = 2

            Write-DebugLog "Starting clipboard sync with server $ServerIP`:$ClipboardPort" "INFO"

            try {
                while ($true) {
                    try {
                        if ($null -eq $client -or -not $client.Connected) {
                            Write-DebugLog "Attempting connection to $ServerIP`:$ClipboardPort..." "INFO"
                            $client = New-Object System.Net.Sockets.TcpClient
                            $client.Connect($ServerIP, $ClipboardPort)
                            $stream = $client.GetStream()
                            Write-DebugLog "Connected successfully" "INFO"
                        }
                        
                        if ($client.Available -gt 0) {
                            $data = Read-NetworkStream -Stream $stream
                            
                            if ($data) {
                                $lines = $data -split "`n"
                                foreach ($line in $lines) {
                                    $trimmedLine = $line.Trim()
                                    if ($trimmedLine -and $trimmedLine -ne "OK") {
                                        try {
                                            $decoded = $trimmedLine | ConvertFrom-Json
                                            
                                            if ($decoded.type -eq 'file') {
                                                $filePath = Join-Path $SyncDir $decoded.filename
                                                [System.IO.File]::WriteAllBytes($filePath, 
                                                    [Convert]::FromBase64String($decoded.content))
                                                [System.Windows.Forms.Clipboard]::SetFileDropList(
                                                    [string[]]@($filePath))
                                            }
                                            else {
                                                [System.Windows.Forms.Clipboard]::SetText($decoded.content)
                                                $lastClipboard = $decoded.content
                                                $lastUpdate = Get-Date
                                            }
                                            
                                            $writer = New-Object System.IO.StreamWriter($stream)
                                            $writer.WriteLine("OK")
                                            $writer.Flush()
                                        }
                                        catch {
                                            Write-DebugLog "Error processing server data: $_" "ERROR"
                                        }
                                    }
                                }
                            }
                        }
                        
                        $currentClipboard = [System.Windows.Forms.Clipboard]::GetText()
                        $now = Get-Date
                        
                        if ($currentClipboard -and ($currentClipboard -ne $lastClipboard) -and 
                            (($now - $lastUpdate) -gt $updateThreshold)) {
                            
                            $payload = @{
                                "type" = "text"
                                "content" = $currentClipboard
                                "filename" = ""
                                "timestamp" = Get-Date -Format "o"
                            }
                            
                            $jsonPayload = $payload | ConvertTo-Json -Compress
                            $writer = New-Object System.IO.StreamWriter($stream)
                            $writer.WriteLine($jsonPayload)
                            $writer.Flush()
                            
                            $lastClipboard = $currentClipboard
                            $lastUpdate = $now
                        }
                        
                        Start-Sleep -Milliseconds 50
                    }
                    catch {
                        Write-DebugLog "Connection error: $_" "ERROR"
                        
                        if ($client) {
                            $client.Close()
                            $client.Dispose()
                            $client = $null
                        }
                        
                        Write-DebugLog "Waiting $reconnectDelay seconds before reconnecting..." "WARN"
                        Start-Sleep -Seconds $reconnectDelay
                    }
                }
            }
            finally {
                if ($client) {
                    $client.Close()
                    $client.Dispose()
                }
            }
        }).AddArgument($ServerIP).AddArgument($clipboardPort).AddArgument($syncDir)

        $script:powershell.Runspace = $script:runspace
        $script:handle = $script:powershell.BeginInvoke()

        $statusLabel.Text = "Status: Connected"
        $statusLabel.ForeColor = [System.Drawing.Color]::LightGreen
        $startButton.Enabled = $false
        $stopButton.Enabled = $true
        $startMenuItem.Enabled = $false
        $stopMenuItem.Enabled = $true
    })

    # Stop button click handler
    $stopButton.Add_Click({
        if ($script:audioJob) {
            Stop-Job -Job $script:audioJob
            Remove-Job -Job $script:audioJob
        }

        if ($script:powershell) {
            $script:powershell.Stop()
            $script:powershell.Dispose()
        }

        if ($script:runspace) {
            $script:runspace.Close()
            $script:runspace.Dispose()
        }

        Kill-AllVLC
        $statusLabel.Text = "Status: Not Connected"
        $statusLabel.ForeColor = [System.Drawing.Color]::Gray
        $startButton.Enabled = $true
        $stopButton.Enabled = $false
        $startMenuItem.Enabled = $true
        $stopMenuItem.Enabled = $false
    })
    
    $form.Add_Closing({
        $stopButton.PerformClick()
        $notifyIcon.Visible = $false
    })

    # Show the form
    $form.Add_Shown({$form.Activate()})
    [void]$form.ShowDialog()
}

function Check-VLCInstalled {
    return Test-Path $vlcPath
}

if ($MyInvocation.MyCommand.CommandType -eq "ExternalScript") {
    # Check if VLC is installed
    if (-not (Check-VLCInstalled)) {
        Install-VLC
    }

    Show-MainForm
}
