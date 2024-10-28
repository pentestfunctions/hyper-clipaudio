param(
    [Parameter(Mandatory=$false)]
    [string]$ServerIP
)

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

function Start-AudioStream {
    param($StreamUrl)
    Write-VerboseOutput "Attempting to start stream from: $StreamUrl"
    
    try {
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
            $StreamUrl
        )
        
        $process = Start-Process -FilePath $vlcPath -ArgumentList $vlcArgs -PassThru
        Write-VerboseOutput "VLC started with PID: $($process.Id)"
        
        Start-Sleep -Seconds 2
        if ($process.HasExited) {
            Write-Host "VLC process terminated unexpectedly. Exit code: $($process.ExitCode)"
            return $false
        }
        
        return $true
    } catch {
        Write-Host "Failed to start VLC: $_"
        return $false
    }
}

function Kill-AllVLC {
    Get-Process vlc -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host "All VLC processes have been killed."
}

function Show-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Audio & Clipboard Sync"
    $form.Size = New-Object System.Drawing.Size($WINDOW_WIDTH, $WINDOW_HEIGHT)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#1E1E1E")
    $form.ForeColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    
    # Calculate positions
    [int]$currentY = $PADDING

    # Title Label
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Audio & Clipboard Sync"
    $titleLabel.AutoSize = $true
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    # Calculate center position for title
    $titleLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    [int]$titleX = ($WINDOW_WIDTH - $titleLabel.PreferredWidth) / 2
    $titleLabel.Location = New-Object System.Drawing.Point($titleX, $currentY)
    $form.Controls.Add($titleLabel)
    
    $currentY = $currentY + $titleLabel.PreferredHeight + ([int]($PADDING * 1.5))

    # IP Label
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Server IP Address:"
    $label.AutoSize = $true
    $label.ForeColor = [System.Drawing.Color]::White
    $label.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    # Calculate center position for IP label
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    [int]$labelX = ($WINDOW_WIDTH - $label.PreferredWidth) / 2
    $label.Location = New-Object System.Drawing.Point($labelX, $currentY)
    $form.Controls.Add($label)
    
    $currentY = $currentY + $label.PreferredHeight + 8

    # Create ComboBox for IP selection with manual entry
    $comboBox = New-Object System.Windows.Forms.ComboBox
    $comboBox.Location = New-Object System.Drawing.Point($PADDING, $currentY)
    [int]$comboBoxWidth = $WINDOW_WIDTH - ($PADDING * 6)  # Make room for scan button
    $comboBox.Width = $comboBoxWidth
    $comboBox.Height = $CONTROL_HEIGHT
    $comboBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#2D2D2D")
    $comboBox.ForeColor = [System.Drawing.Color]::White
    $comboBox.Font = New-Object System.Drawing.Font("Segoe UI", 12)
    $comboBox.FlatStyle = "Flat"
    $comboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $form.Controls.Add($comboBox)

    # Scan Button
    $scanButton = New-Object System.Windows.Forms.Button
    [int]$scanButtonWidth = ($PADDING * 6)
    [int]$scanButtonX = $WINDOW_WIDTH - $scanButtonWidth
    $scanButton.Location = New-Object System.Drawing.Point($scanButtonX, $currentY)
    $scanButton.Width = $scanButtonWidth
    $scanButton.Height = $CONTROL_HEIGHT
    $scanButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#404040")
    $scanButton.ForeColor = [System.Drawing.Color]::White
    $scanButton.FlatStyle = "Flat"
    $scanButton.Text = "Scan"  # Unicode refresh symbol
    $scanButton.Font = New-Object System.Drawing.Font("Segoe UI", 12)
    $form.Controls.Add($scanButton)

    $currentY = $currentY + $CONTROL_HEIGHT + $PADDING

    # Status Label
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Status: Not Connected"
    $statusLabel.AutoSize = $true
    $statusLabel.Location = New-Object System.Drawing.Point($PADDING, $currentY)
    $statusLabel.ForeColor = [System.Drawing.Color]::Gray
    $statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $form.Controls.Add($statusLabel)
    
    $currentY = $currentY + $statusLabel.PreferredHeight + ([int]($PADDING * 1.5))

    # Button container panel for better alignment
    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Location = New-Object System.Drawing.Point($PADDING, $currentY)
    $buttonPanel.Width = $WINDOW_WIDTH - ($PADDING * 2)
    $buttonPanel.Height = $BUTTON_HEIGHT
    $buttonPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#1E1E1E")
    $form.Controls.Add($buttonPanel)

    # Calculate button widths and spacing with smaller width
    [int]$buttonWidth = [Math]::Floor($buttonPanel.Width * 0.3)  # 30% of panel width for each button
    [int]$totalButtonsWidth = ($buttonWidth * 2) + $PADDING     # Total width of both buttons plus padding
    [int]$startX = ($buttonPanel.Width - $totalButtonsWidth) / 2  # Center point minus half of total button width

    # Start Button
    $startButton = New-Object System.Windows.Forms.Button
    $startButton.Text = "Start Services"
    $startButton.Location = New-Object System.Drawing.Point($startX, 0)
    $startButton.Width = $buttonWidth
    $startButton.Height = $BUTTON_HEIGHT
    $startButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#007ACC")
    $startButton.ForeColor = [System.Drawing.Color]::White
    $startButton.FlatStyle = "Flat"
    $startButton.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $buttonPanel.Controls.Add($startButton)

    # Stop Button
    $stopButton = New-Object System.Windows.Forms.Button
    $stopButton.Text = "Stop Services"
    [int]$stopButtonX = $startX + $buttonWidth + $PADDING
    $stopButton.Location = New-Object System.Drawing.Point($stopButtonX, 0)
    $stopButton.Width = $buttonWidth
    $stopButton.Height = $BUTTON_HEIGHT
    $stopButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#CC2222")
    $stopButton.ForeColor = [System.Drawing.Color]::White
    $stopButton.FlatStyle = "Flat"
    $stopButton.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $stopButton.Enabled = $false
    $buttonPanel.Controls.Add($stopButton)

    # Create NotifyIcon with modern context menu
    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
    $notifyIcon.Text = "Audio & Clipboard Sync"
    $notifyIcon.Visible = $true

    # Create context menu for NotifyIcon
    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $contextMenu.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#2D2D2D")
    $contextMenu.ForeColor = [System.Drawing.Color]::White
    $contextMenu.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $showMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Show Window")
    $startMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Start Services")
    $stopMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Stop Services")
    $exitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")

    # Configure menu items
    @($showMenuItem, $startMenuItem, $stopMenuItem, $exitMenuItem) | ForEach-Object {
        $_.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#2D2D2D")
        $_.ForeColor = [System.Drawing.Color]::White
    }

    $showMenuItem.Add_Click({ $form.Show(); $form.WindowState = "Normal" })
    $startMenuItem.Add_Click({ $startButton.PerformClick() })
    $stopMenuItem.Add_Click({ $stopButton.PerformClick() })
    $stopMenuItem.Enabled = $false
    $exitMenuItem.Add_Click({
        $notifyIcon.Visible = $false
        $form.Close()
    })

    # Add the scan button click handler
    $scanButton.Add_Click({
        $comboBox.Items.Clear()
        try {
            # Check if Hyper-V module is available
            if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
                throw "Hyper-V module not found. Please ensure Hyper-V is installed."
            }

            # Import Hyper-V module
            Import-Module Hyper-V -ErrorAction Stop

            # Get running VMs and their IP addresses
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

    # Add ComboBox selection changed handler
    $comboBox.Add_SelectedIndexChanged({
        if ($comboBox.SelectedItem -and $comboBox.SelectedItem.ToString().Contains(": ")) {
            $selectedIP = ($comboBox.SelectedItem -split ': ')[1].Trim()
            $comboBox.Text = $selectedIP
        }
    })
  
    $contextMenu.Items.AddRange(@(
        $showMenuItem,
        (New-Object System.Windows.Forms.ToolStripSeparator),
        $startMenuItem,
        $stopMenuItem,
        (New-Object System.Windows.Forms.ToolStripSeparator),
        $exitMenuItem
    ))
    $notifyIcon.ContextMenuStrip = $contextMenu

    # Double-click on tray icon shows the form
    $notifyIcon.Add_MouseDoubleClick({
        $form.Show()
        $form.WindowState = "Normal"
    })

    # Minimize to tray
    $form.Add_Resize({
        if ($form.WindowState -eq "Minimized") {
            $form.Hide()
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

        # Start audio stream in a background job
        $streamUrl = "tcp://${ServerIP}:${audioPort}"
        $script:audioJob = Start-Job -ScriptBlock {
            param($VLCPath, $StreamUrl)
            
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
                $StreamUrl
            )
            
            Start-Process -FilePath $VLCPath -ArgumentList $vlcArgs -NoNewWindow -Wait
        } -ArgumentList $vlcPath, $streamUrl

        # Start clipboard sync in a separate runspace
        $script:runspace = [runspacefactory]::CreateRunspace()
        $script:runspace.ApartmentState = "STA"
        $script:runspace.ThreadOptions = "ReuseThread"
        $script:runspace.Open()

        # Add necessary functions and variables to runspace
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
            $reconnectDelay = 5
            
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

    # Handle form closing
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

# Main execution block - This ensures the script runs properly when double-clicked
if ($MyInvocation.MyCommand.CommandType -eq "ExternalScript") {
    # Check if VLC is installed
    if (-not (Check-VLCInstalled)) {
        Install-VLC
    }

    # Show the main form
    Show-MainForm
}
