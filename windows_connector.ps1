param(
    [Parameter(Mandatory=$false)]
    [string]$ServerIP
)

# Load Windows Forms assembly
Add-Type -AssemblyName System.Windows.Forms

#region Variables
$vlcPath = "C:\Program Files\VideoLAN\VLC\vlc.exe"
$verbose = $true
$DebugPreference = "Continue"
$syncDir = Join-Path $env:USERPROFILE "ClipboardSync"
$clipboardPort = 12345  # Hardcoded clipboard sync port
$audioPort = 5001       # Audio streaming port
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
    [System.Windows.Forms.MessageBox]::Show("All VLC processes have been killed.", "Kill All VLC", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Show-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Audio & Clipboard Sync"
    $form.Size = New-Object System.Drawing.Size(400, 300)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#1E1E1E")
    $form.ForeColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    # Title Label
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Audio & Clipboard Sync"
    $titleLabel.AutoSize = $true
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Location = New-Object System.Drawing.Point(20, 20)
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($titleLabel)

    # IP Label
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Server IP Address:"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(20, 80)
    $label.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($label)

    # IP TextBox
    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(20, 105)
    $textBox.Width = 360
    $textBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#2D2D2D")
    $textBox.ForeColor = [System.Drawing.Color]::White
    $textBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $textBox.BorderStyle = "FixedSingle"
    $form.Controls.Add($textBox)

    # Status Label
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Status: Not Connected"
    $statusLabel.AutoSize = $true
    $statusLabel.Location = New-Object System.Drawing.Point(20, 140)
    $statusLabel.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($statusLabel)

    # Start Button
    $startButton = New-Object System.Windows.Forms.Button
    $startButton.Text = "Start Services"
    $startButton.Location = New-Object System.Drawing.Point(20, 180)
    $startButton.Width = 170
    $startButton.Height = 40
    $startButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#007ACC")
    $startButton.ForeColor = [System.Drawing.Color]::White
    $startButton.FlatStyle = "Flat"
    $startButton.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($startButton)

    # Stop Button
    $stopButton = New-Object System.Windows.Forms.Button
    $stopButton.Text = "Stop Services"
    $stopButton.Location = New-Object System.Drawing.Point(210, 180)
    $stopButton.Width = 170
    $stopButton.Height = 40
    $stopButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#CC2222")
    $stopButton.ForeColor = [System.Drawing.Color]::White
    $stopButton.FlatStyle = "Flat"
    $stopButton.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $stopButton.Enabled = $false
    $form.Controls.Add($stopButton)

    # Create NotifyIcon
    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
    $notifyIcon.Text = "Audio & Clipboard Sync"
    $notifyIcon.Visible = $true

    # Create context menu for NotifyIcon
    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

    $showMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Show Window")
    $showMenuItem.Add_Click({ $form.Show(); $form.WindowState = "Normal" })

    $startMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Start Services")
    $startMenuItem.Add_Click({ $startButton.PerformClick() })

    $stopMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Stop Services")
    $stopMenuItem.Add_Click({ $stopButton.PerformClick() })
    $stopMenuItem.Enabled = $false

    $exitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
    $exitMenuItem.Add_Click({
        $notifyIcon.Visible = $false
        $form.Close()
    })

    $contextMenu.Items.AddRange(@($showMenuItem, 
        (New-Object System.Windows.Forms.ToolStripSeparator),
        $startMenuItem, $stopMenuItem,
        (New-Object System.Windows.Forms.ToolStripSeparator),
        $exitMenuItem))
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
        $script:ServerIP = $textBox.Text.Trim()
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
        $textBox.Enabled = $false
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
        $textBox.Enabled = $true
    })

    # Handle form closing
    $form.Add_Closing({
        $stopButton.PerformClick()
        $notifyIcon.Visible = $false
    })

    # Set initial text if ServerIP is provided
    if ($ServerIP) {
        $textBox.Text = $ServerIP
    }

    # Show the form
    $form.Add_Shown({$form.Activate()})
    [void]$form.ShowDialog()
}

#region Main Execution
# Check if VLC is installed
if (-not (Check-VLCInstalled)) {
    Install-VLC
}

# Show the main form
Show-MainForm
#endregion
