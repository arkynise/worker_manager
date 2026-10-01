# ============================================================
# RedisWorkerPanel.ps1
# Symfony Redis Worker Control Panel
# Folder-Based BAT Manager  (in-memory live output, no log files)
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
# WORKER HOST (pure PowerShell, no Add-Type / no compiling)
# Output is read with async ReadLineAsync and polled by a timer.
# ============================================================

function New-WorkerHost {

    $h = [pscustomobject]@{
        Proc       = $null
        Lines      = (New-Object 'System.Collections.Generic.List[string]')
        Trimmed    = [long]0
        ReadNext   = [long]0
        OutTask    = $null
        ErrTask    = $null
        ExitLogged = $true
    }

    Add-Member -InputObject $h -MemberType ScriptMethod -Name Add -Value {
        param([string]$s)
        $this.Lines.Add($s)
        if ($this.Lines.Count -gt 5000) {
            $r = $this.Lines.Count - 5000
            $this.Lines.RemoveRange(0, $r)
            $this.Trimmed += $r
        }
    }

    Add-Member -InputObject $h -MemberType ScriptProperty -Name Total -Value {
        [long]($this.Trimmed + $this.Lines.Count)
    }

    Add-Member -InputObject $h -MemberType ScriptProperty -Name IsAlive -Value {
        try { ($null -ne $this.Proc) -and (-not $this.Proc.HasExited) } catch { $false }
    }

    Add-Member -InputObject $h -MemberType ScriptMethod -Name ReadFrom -Value {
        param([long]$abs)
        if ($abs -lt $this.Trimmed) { $abs = $this.Trimmed }
        $idx = [int]($abs - $this.Trimmed)
        $sb = New-Object System.Text.StringBuilder
        for ($i = $idx; $i -lt $this.Lines.Count; $i++) {
            [void]$sb.Append($this.Lines[$i]).Append("`r`n")
        }
        $this.ReadNext = $this.Trimmed + $this.Lines.Count
        return $sb.ToString()
    }

    Add-Member -InputObject $h -MemberType ScriptMethod -Name Pump -Value {

        if ($null -eq $this.Proc) { return }

        foreach ($which in 'Out', 'Err') {

            $taskName = "${which}Task"
            $guard = 0

            while ($null -ne $this.$taskName -and $this.$taskName.IsCompleted -and $guard -lt 500) {

                $guard++
                $line  = $null
                $ended = $false

                try { $line = $this.$taskName.Result } catch { $ended = $true }

                if ($ended -or $null -eq $line) {
                    $this.$taskName = $null
                    break
                }

                $this.Add([string]$line)

                if ($which -eq 'Out') { $reader = $this.Proc.StandardOutput }
                else                  { $reader = $this.Proc.StandardError }

                $this.$taskName = $reader.ReadLineAsync()
            }
        }

        if (-not $this.ExitLogged -and
            $null -eq $this.OutTask -and
            $null -eq $this.ErrTask) {

            $this.ExitLogged = $true
            try   { $this.Add("[process exited, code $($this.Proc.ExitCode)]") }
            catch { $this.Add('[process exited]') }
        }
    }

    return $h
}

function Pump-Hosts {
    foreach ($id in @($script:Hosts.Keys)) {
        try { $script:Hosts[$id].Pump() } catch { }
    }
}

# ============================================================
# CONFIGURATION
# ============================================================

$ProjectPath = 'C:\Users\dell\Desktop\newBooking'
$PanelPath   = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatePath   = Join-Path $PanelPath 'state'

$DefaultWorkersPath = $PanelPath

New-Item -ItemType Directory -Force -Path $StatePath | Out-Null

# ============================================================
# GLOBAL VARIABLES
# ============================================================

$script:WorkersPath    = $DefaultWorkersPath
$script:Workers        = [ordered]@{}
$script:Hosts          = @{}          # workerId -> WorkerHost (live output buffers)
$script:StatusLabels   = @{}
$script:PidLabels      = @{}
$script:SelectedWorker = $null
$script:ShownWorker    = $null        # which worker the log box currently shows
$script:ShownPos       = [long]0      # how much of that worker's buffer is already shown
$script:TickCount      = 0

$script:OutputBox    = $null
$script:LogBox       = $null
$script:LogTitle     = $null
$script:WorkerPanel  = $null
$script:FolderLabel  = $null
$script:PathTextBox  = $null

# ============================================================
# SAFE WORKER ID
# ============================================================

function Get-WorkerId {
    param([string]$BatPath)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($BatPath.ToLowerInvariant())
        $hash  = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 16)
    }
    finally { $sha.Dispose() }
}

# ============================================================
# PID STATE FILES (only used to stop workers started by an
# earlier panel session)
# ============================================================

function Get-StateFile {
    param([string]$WorkerId)
    return Join-Path $StatePath "$WorkerId.pid"
}

function Get-SavedPid {
    param([string]$WorkerId)

    $file = Get-StateFile $WorkerId
    if (-not (Test-Path $file)) { return $null }

    try {
        $raw = (Get-Content $file -Raw -ErrorAction Stop).Trim()
        if ($raw -match '^\d+$') { return [int]$raw }
    }
    catch { return $null }

    return $null
}

function Save-Pid {
    param([string]$WorkerId, [int]$WorkerProcessId)
    Set-Content -Path (Get-StateFile $WorkerId) -Value $WorkerProcessId -Encoding ascii
}

function Clear-Pid {
    param([string]$WorkerId)
    $file = Get-StateFile $WorkerId
    if (Test-Path $file) { Remove-Item $file -Force -ErrorAction SilentlyContinue }
}

# ============================================================
# CONTROL PANEL MESSAGE LOG
# ============================================================

function Add-Log {
    param([string]$Message)

    if ($null -eq $script:OutputBox) { return }

    $time = Get-Date -Format 'HH:mm:ss'
    $script:OutputBox.AppendText("[$time] $Message`r`n")
    $script:OutputBox.SelectionStart = $script:OutputBox.Text.Length
    $script:OutputBox.ScrollToCaret()
}

# ============================================================
# LOAD ALL BAT FILES
# ============================================================

function Load-Workers {

    $script:Workers = [ordered]@{}

    if (-not (Test-Path $script:WorkersPath -PathType Container)) {
        Add-Log 'Worker folder does not exist:'
        Add-Log $script:WorkersPath
        return
    }

    try {
        $batFiles = @(
            Get-ChildItem -Path $script:WorkersPath -Filter '*.bat' -File -ErrorAction Stop |
            Sort-Object Name
        )
    }
    catch {
        Add-Log 'Unable to read worker folder.'
        Add-Log $_.Exception.Message
        return
    }

    foreach ($batFile in $batFiles) {

        $workerId = Get-WorkerId $batFile.FullName

        $script:Workers[$workerId] = @{
            Id       = $workerId
            Name     = $batFile.BaseName
            Bat      = $batFile.FullName
            FileName = $batFile.Name
        }
    }

    Add-Log "Loaded $($script:Workers.Count) BAT file(s)."
}

# ============================================================
# RUNNING CHECKS
# ============================================================

function Get-WorkerPid {
    param([string]$WorkerId)

    if ($script:Hosts.ContainsKey($WorkerId) -and $script:Hosts[$WorkerId].IsAlive) {
        return $script:Hosts[$WorkerId].Proc.Id
    }

    return Get-SavedPid $WorkerId
}

function Test-WorkerRunning {
    param([string]$WorkerId)

    # Never name a variable $pid - PowerShell owns it.

    # Started by this panel: ask the live process object.
    if ($script:Hosts.ContainsKey($WorkerId) -and $script:Hosts[$WorkerId].IsAlive) {
        return $true
    }

    # Started by an earlier panel session: fall back to the PID file.
    $workerPid = Get-SavedPid $WorkerId
    if (-not $workerPid) { return $false }

    try {
        Get-Process -Id $workerPid -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Clear-Pid $WorkerId
        return $false
    }
}

# ============================================================
# START WORKER
# Output is captured through redirected pipes straight into
# memory - nothing is written to disk.
# ============================================================

function Start-Worker {
    param([string]$WorkerId)

    if (-not $script:Workers.Contains($WorkerId)) {
        Add-Log 'Worker no longer exists.'
        return
    }

    $worker = $script:Workers[$WorkerId]

    if (Test-WorkerRunning $WorkerId) {
        Add-Log "[$($worker.Name)] already running."
        return
    }

    $batFile = $worker.Bat

    if (-not (Test-Path $batFile)) {
        Add-Log "[$($worker.Name)] BAT file not found:"
        Add-Log $batFile
        return
    }

    Add-Log '========================================'
    Add-Log "[$($worker.Name)] starting..."
    Add-Log "[$($worker.Name)] BAT: $batFile"

    try {

        # Reuse the worker's buffer so history survives restarts.
        if (-not $script:Hosts.ContainsKey($WorkerId)) {
            $script:Hosts[$WorkerId] = New-WorkerHost
        }

        $workerHost = $script:Hosts[$WorkerId]

        $workerHost.Add('==================================================')
        $workerHost.Add("Worker starting: $($worker.Name)")
        $workerHost.Add("Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $workerHost.Add('==================================================')

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'cmd.exe'
        $psi.Arguments              = "/c call `"$batFile`""
        $psi.WorkingDirectory       = $ProjectPath
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        [void]$process.Start()

        $workerHost.Proc       = $process
        $workerHost.ExitLogged = $false
        $workerHost.OutTask    = $process.StandardOutput.ReadLineAsync()
        $workerHost.ErrTask    = $process.StandardError.ReadLineAsync()

        Save-Pid -WorkerId $WorkerId -WorkerProcessId $process.Id

        Add-Log "[$($worker.Name)] STARTED"
        Add-Log "[$($worker.Name)] CMD PID: $($process.Id)"
        Add-Log "[$($worker.Name)] STDOUT/STDERR -> live log (memory)"

        # Show this worker's output right away.
        $script:SelectedWorker = $WorkerId
    }
    catch {
        Add-Log "[$($worker.Name)] START ERROR"
        Add-Log $_.Exception.Message

        [System.Windows.Forms.MessageBox]::Show(
            "Could not start $($worker.Name):`r`n`r`n$($_.Exception.Message)",
            'Start error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }

    Update-Status
}

# ============================================================
# STOP WORKER
# ============================================================

function Stop-Worker {
    param([string]$WorkerId)

    if (-not $script:Workers.Contains($WorkerId)) {
        Add-Log 'Worker no longer exists.'
        return
    }

    $worker    = $script:Workers[$WorkerId]
    $workerPid = Get-WorkerPid $WorkerId

    if (-not $workerPid) {
        Add-Log "[$($worker.Name)] not running."
        Update-Status
        return
    }

    Add-Log "[$($worker.Name)] stopping PID $workerPid..."

    try {
        # /T = whole tree (cmd -> php -> worker), /F = force
        $result = & taskkill.exe /PID $workerPid /T /F 2>&1

        foreach ($line in $result) {
            if ($line) { Add-Log "[$($worker.Name)] $line" }
        }

        Add-Log "[$($worker.Name)] STOPPED"
    }
    catch {
        Add-Log "[$($worker.Name)] STOP ERROR"
        Add-Log $_.Exception.Message
    }

    Clear-Pid $WorkerId
    Update-Status
}

function Restart-Worker {
    param([string]$WorkerId)

    if (-not $script:Workers.Contains($WorkerId)) { return }

    Add-Log "[$($script:Workers[$WorkerId].Name)] restarting..."

    Stop-Worker $WorkerId
    Start-Sleep -Milliseconds 700
    Start-Worker $WorkerId
}

function Start-All {
    Add-Log '========================================'
    Add-Log 'STARTING ALL WORKERS'
    Add-Log '========================================'

    foreach ($WorkerId in @($script:Workers.Keys)) {
        Start-Worker $WorkerId
        Start-Sleep -Milliseconds 300
    }
}

function Stop-All {
    Add-Log '========================================'
    Add-Log 'STOPPING ALL WORKERS'
    Add-Log '========================================'

    foreach ($WorkerId in @($script:Workers.Keys)) {
        Stop-Worker $WorkerId
    }
}

function Restart-All {
    Add-Log '========================================'
    Add-Log 'RESTARTING ALL WORKERS'
    Add-Log '========================================'

    foreach ($WorkerId in @($script:Workers.Keys)) {
        Restart-Worker $WorkerId
        Start-Sleep -Milliseconds 300
    }
}

# ============================================================
# LIVE LOG VIEW (reads directly from the in-memory buffer)
# ============================================================

function Update-SelectedLog {

    if ($null -eq $script:LogBox) { return }

    if (-not $script:SelectedWorker -or
        -not $script:Workers.Contains($script:SelectedWorker)) {

        if ($script:ShownWorker) {
            $script:LogBox.Text = ''
            $script:ShownWorker = $null
            $script:ShownPos    = [long]0
        }
        return
    }

    $worker = $script:Workers[$script:SelectedWorker]

    if ($script:LogTitle) {
        $script:LogTitle.Text = "Live log: $($worker.Name)"
    }

    # --------------------------------------------------------
    # Selection changed -> reload from the buffer
    # --------------------------------------------------------
    if ($script:ShownWorker -ne $script:SelectedWorker) {

        $script:ShownWorker = $script:SelectedWorker
        $script:LogBox.Text = ''

        if ($script:Hosts.ContainsKey($script:SelectedWorker)) {

            $workerHost = $script:Hosts[$script:SelectedWorker]

            # Start from the last 500 lines.
            $script:ShownPos = [Math]::Max([long]0, $workerHost.Total - 500)
        }
        else {
            $script:ShownPos = [long]0

            if (Test-WorkerRunning $script:SelectedWorker) {
                $script:LogBox.Text =
                    "This worker was started by an earlier panel session.`r`n" +
                    "Its output cannot be captured. Restart it from this panel to see live output.`r`n"
            }
            else {
                $script:LogBox.Text = "No output yet. Start the worker to see its log.`r`n"
            }
        }
    }

    if (-not $script:Hosts.ContainsKey($script:SelectedWorker)) { return }

    # --------------------------------------------------------
    # Append only the new lines
    # --------------------------------------------------------
    $workerHost = $script:Hosts[$script:SelectedWorker]

    if ($workerHost.Total -le $script:ShownPos) { return }

    $newText = $workerHost.ReadFrom($script:ShownPos)
    $script:ShownPos = $workerHost.ReadNext

    if ($newText.Length -eq 0) { return }

    # Keep the textbox from growing forever.
    if ($script:LogBox.TextLength -gt 400000) {
        $script:LogBox.Text = $script:LogBox.Text.Substring(200000)
    }

    $script:LogBox.AppendText($newText)
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
}

# ============================================================
# UPDATE STATUS LABELS
# ============================================================

function Update-Status {

    foreach ($WorkerId in @($script:Workers.Keys)) {

        if (-not $script:StatusLabels.ContainsKey($WorkerId)) { continue }

        $statusLabel = $script:StatusLabels[$WorkerId]
        $pidLabel    = $script:PidLabels[$WorkerId]

        if (Test-WorkerRunning $WorkerId) {
            $statusLabel.Text      = 'RUNNING'
            $statusLabel.ForeColor = [System.Drawing.Color]::Green
            $pidLabel.Text         = "PID: $(Get-WorkerPid $WorkerId)"
        }
        else {
            $statusLabel.Text      = 'STOPPED'
            $statusLabel.ForeColor = [System.Drawing.Color]::Red
            $pidLabel.Text         = 'PID: -'
        }
    }

    Update-SelectedLog
}

# ============================================================
# WORKER ROW
# ============================================================

function Add-WorkerRow {
    param(
        [string]$WorkerId,
        [hashtable]$Worker,
        [int]$Y
    )

    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text     = "$($Worker.Name)  [$($Worker.FileName)]"
    $group.Location = New-Object System.Drawing.Point(10, $Y)
    $group.Size     = New-Object System.Drawing.Size(950, 70)
    $script:WorkerPanel.Controls.Add($group)

    # STATUS
    $status = New-Object System.Windows.Forms.Label
    $status.Text      = 'STOPPED'
    $status.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $status.ForeColor = [System.Drawing.Color]::Red
    $status.Location  = New-Object System.Drawing.Point(15, 28)
    $status.Size      = New-Object System.Drawing.Size(90, 25)
    $group.Controls.Add($status)
    $script:StatusLabels[$WorkerId] = $status

    # PID
    $pidLabel = New-Object System.Windows.Forms.Label
    $pidLabel.Text     = 'PID: -'
    $pidLabel.Location = New-Object System.Drawing.Point(105, 30)
    $pidLabel.Size     = New-Object System.Drawing.Size(100, 22)
    $group.Controls.Add($pidLabel)
    $script:PidLabels[$WorkerId] = $pidLabel

    # START
    $startButton = New-Object System.Windows.Forms.Button
    $startButton.Text     = 'Start'
    $startButton.Location = New-Object System.Drawing.Point(215, 22)
    $startButton.Size     = New-Object System.Drawing.Size(85, 32)
    $startButton.Tag      = $WorkerId
    $startButton.Add_Click({ Start-Worker $this.Tag })
    $group.Controls.Add($startButton)

    # STOP
    $stopButton = New-Object System.Windows.Forms.Button
    $stopButton.Text     = 'Stop'
    $stopButton.Location = New-Object System.Drawing.Point(310, 22)
    $stopButton.Size     = New-Object System.Drawing.Size(85, 32)
    $stopButton.Tag      = $WorkerId
    $stopButton.Add_Click({ Stop-Worker $this.Tag })
    $group.Controls.Add($stopButton)

    # RESTART
    $restartButton = New-Object System.Windows.Forms.Button
    $restartButton.Text     = 'Restart'
    $restartButton.Location = New-Object System.Drawing.Point(405, 22)
    $restartButton.Size     = New-Object System.Drawing.Size(85, 32)
    $restartButton.Tag      = $WorkerId
    $restartButton.Add_Click({ Restart-Worker $this.Tag })
    $group.Controls.Add($restartButton)

    # VIEW LOG
    $viewButton = New-Object System.Windows.Forms.Button
    $viewButton.Text     = 'View Log'
    $viewButton.Location = New-Object System.Drawing.Point(500, 22)
    $viewButton.Size     = New-Object System.Drawing.Size(90, 32)
    $viewButton.Tag      = $WorkerId
    $viewButton.Add_Click({
        $script:SelectedWorker = $this.Tag
        Update-SelectedLog
    })
    $group.Controls.Add($viewButton)

    # CLEAR LOG (clears the in-memory buffer view)
    $clearButton = New-Object System.Windows.Forms.Button
    $clearButton.Text     = 'Clear'
    $clearButton.Location = New-Object System.Drawing.Point(600, 22)
    $clearButton.Size     = New-Object System.Drawing.Size(70, 32)
    $clearButton.Tag      = $WorkerId
    $clearButton.Add_Click({
        $id = $this.Tag
        if ($script:Hosts.ContainsKey($id)) {
            # Skip everything currently buffered.
            if ($script:SelectedWorker -eq $id) {
                $script:LogBox.Text = ''
                $script:ShownPos    = $script:Hosts[$id].Total
            }
        }
    })
    $group.Controls.Add($clearButton)

    # OPEN FOLDER
    $openButton = New-Object System.Windows.Forms.Button
    $openButton.Text     = 'Open Folder'
    $openButton.Location = New-Object System.Drawing.Point(680, 22)
    $openButton.Size     = New-Object System.Drawing.Size(100, 32)
    $openButton.Tag      = $Worker.Bat
    $openButton.Add_Click({
        $batPath = $this.Tag
        if (Test-Path $batPath) {
            Start-Process 'explorer.exe' -ArgumentList ("/select,`"$batPath`"")
        }
    })
    $group.Controls.Add($openButton)
}

# ============================================================
# REBUILD WORKER UI
# ============================================================

function Rebuild-WorkerUI {

    if ($null -eq $script:WorkerPanel) { return }

    $script:WorkerPanel.Controls.Clear()
    $script:StatusLabels.Clear()
    $script:PidLabels.Clear()

    Load-Workers

    $y = 10

    foreach ($WorkerId in @($script:Workers.Keys)) {
        Add-WorkerRow -WorkerId $WorkerId -Worker $script:Workers[$WorkerId] -Y $y
        $y += 78
    }

    if ($script:Workers.Count -eq 0) {

        $emptyLabel = New-Object System.Windows.Forms.Label
        $emptyLabel.Text      = 'No .bat files found in this folder.'
        $emptyLabel.Location  = New-Object System.Drawing.Point(15, 20)
        $emptyLabel.Size      = New-Object System.Drawing.Size(500, 30)
        $emptyLabel.ForeColor = [System.Drawing.Color]::Gray
        $script:WorkerPanel.Controls.Add($emptyLabel)
    }

    $script:WorkerPanel.AutoScrollMinSize =
        New-Object System.Drawing.Size(0, [Math]::Max($y + 10, 100))

    # Keep or pick a selected worker.
    if ($null -eq $script:SelectedWorker -or
        -not $script:Workers.Contains($script:SelectedWorker)) {

        if ($script:Workers.Count -gt 0) {
            $script:SelectedWorker = @($script:Workers.Keys)[0]
        }
        else {
            $script:SelectedWorker = $null
        }
    }

    Update-Status
}

# ============================================================
# LOAD FOLDER FROM PATH
# ============================================================

function Load-WorkersFromPath {
    param([string]$Path)

    if ($null -eq $Path) { return }

    $Path = $Path.Trim()

    # Strip surrounding quotes if pasted.
    if ($Path.Length -ge 2 -and
        (($Path.StartsWith('"') -and $Path.EndsWith('"')) -or
         ($Path.StartsWith("'") -and $Path.EndsWith("'")))) {

        $Path = $Path.Substring(1, $Path.Length - 2)
    }

    $Path = $Path.Trim()

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-Log 'Folder path is empty.'
        return
    }

    if (-not (Test-Path $Path -PathType Container)) {

        Add-Log '========================================'
        Add-Log 'INVALID WORKER DIRECTORY'
        Add-Log "Path: $Path"
        Add-Log 'The directory does not exist.'
        Add-Log '========================================'

        [System.Windows.Forms.MessageBox]::Show(
            "The directory does not exist:`r`n`r`n$Path",
            'Invalid Folder',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null

        return
    }

    try {
        $resolvedPath = (Resolve-Path $Path -ErrorAction Stop).Path
    }
    catch {
        Add-Log 'Unable to resolve directory path.'
        Add-Log $_.Exception.Message
        return
    }

    $script:WorkersPath = $resolvedPath

    if ($script:PathTextBox) { $script:PathTextBox.Text = $script:WorkersPath }
    if ($script:FolderLabel) { $script:FolderLabel.Text = "Folder: $script:WorkersPath" }

    Add-Log '========================================'
    Add-Log 'WORKER DIRECTORY CHANGED'
    Add-Log "Directory: $script:WorkersPath"
    Add-Log '========================================'

    $script:SelectedWorker = $null

    Rebuild-WorkerUI

    Add-Log "Directory loaded. Workers detected: $($script:Workers.Count)"
}

function Reload-WorkersDirectory {

    Add-Log '========================================'
    Add-Log 'RELOADING WORKER DIRECTORY'
    Add-Log "Directory: $script:WorkersPath"
    Add-Log '========================================'

    $previousWorker = $script:SelectedWorker

    Rebuild-WorkerUI

    if ($previousWorker -and $script:Workers.Contains($previousWorker)) {
        $script:SelectedWorker = $previousWorker
        Update-SelectedLog
    }

    Add-Log "Directory reload completed. Workers detected: $($script:Workers.Count)"
}

function Select-WorkersFolder {

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description  = 'Select the folder containing your BAT worker files'
    $dialog.SelectedPath = $script:WorkersPath

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {

        if ($script:PathTextBox) { $script:PathTextBox.Text = $dialog.SelectedPath }

        Load-WorkersFromPath $dialog.SelectedPath
    }
}

# ============================================================
# MAIN FORM
# ============================================================

$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Symfony Redis Worker Control Panel'
$form.Size          = New-Object System.Drawing.Size(1050, 750)
$form.MinimumSize   = New-Object System.Drawing.Size(900, 650)
$form.StartPosition = 'CenterScreen'
$form.BackColor     = [System.Drawing.Color]::White

# HEADER
$header = New-Object System.Windows.Forms.Label
$header.Text     = 'Symfony Redis Workers'
$header.Font     = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$header.Location = New-Object System.Drawing.Point(20, 15)
$header.Size     = New-Object System.Drawing.Size(500, 40)
$form.Controls.Add($header)

# NOTE
$note = New-Object System.Windows.Forms.Label
$note.Text     = 'Worker output is shown live in memory (no log files). Closing this panel disconnects the output.'
$note.Location = New-Object System.Drawing.Point(22, 55)
$note.Size     = New-Object System.Drawing.Size(950, 25)
$form.Controls.Add($note)

# FOLDER PATH LABEL
$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Text     = 'Worker Folder:'
$pathLabel.Location = New-Object System.Drawing.Point(20, 86)
$pathLabel.Size     = New-Object System.Drawing.Size(90, 25)
$form.Controls.Add($pathLabel)

# FOLDER PATH INPUT
$script:PathTextBox = New-Object System.Windows.Forms.TextBox
$script:PathTextBox.Text     = $script:WorkersPath
$script:PathTextBox.Location = New-Object System.Drawing.Point(110, 82)
$script:PathTextBox.Size     = New-Object System.Drawing.Size(590, 28)
$script:PathTextBox.Anchor   =
    [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right

$script:PathTextBox.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        Load-WorkersFromPath $script:PathTextBox.Text
    }
})

$form.Controls.Add($script:PathTextBox)

# BROWSE
$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text     = 'Browse'
$browseButton.Location = New-Object System.Drawing.Point(710, 80)
$browseButton.Size     = New-Object System.Drawing.Size(90, 32)
$browseButton.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$browseButton.Add_Click({ Select-WorkersFolder })
$form.Controls.Add($browseButton)

# LOAD FOLDER
$loadFolderButton = New-Object System.Windows.Forms.Button
$loadFolderButton.Text     = 'Load Folder'
$loadFolderButton.Location = New-Object System.Drawing.Point(810, 80)
$loadFolderButton.Size     = New-Object System.Drawing.Size(100, 32)
$loadFolderButton.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$loadFolderButton.Add_Click({ Load-WorkersFromPath $script:PathTextBox.Text })
$form.Controls.Add($loadFolderButton)

# CURRENT FOLDER LABEL
$script:FolderLabel = New-Object System.Windows.Forms.Label
$script:FolderLabel.Text         = "Folder: $script:WorkersPath"
$script:FolderLabel.Location     = New-Object System.Drawing.Point(20, 112)
$script:FolderLabel.Size         = New-Object System.Drawing.Size(900, 25)
$script:FolderLabel.AutoEllipsis = $true
$form.Controls.Add($script:FolderLabel)

# WORKER PANEL
$script:WorkerPanel = New-Object System.Windows.Forms.Panel
$script:WorkerPanel.Location    = New-Object System.Drawing.Point(20, 145)
$script:WorkerPanel.Size        = New-Object System.Drawing.Size(995, 220)
$script:WorkerPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:WorkerPanel.AutoScroll  = $true
$script:WorkerPanel.Anchor      =
    [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($script:WorkerPanel)

# START ALL
$startAll = New-Object System.Windows.Forms.Button
$startAll.Text     = 'START ALL'
$startAll.Location = New-Object System.Drawing.Point(20, 375)
$startAll.Size     = New-Object System.Drawing.Size(110, 35)
$startAll.Add_Click({ Start-All })
$form.Controls.Add($startAll)

# STOP ALL
$stopAll = New-Object System.Windows.Forms.Button
$stopAll.Text     = 'STOP ALL'
$stopAll.Location = New-Object System.Drawing.Point(140, 375)
$stopAll.Size     = New-Object System.Drawing.Size(110, 35)
$stopAll.Add_Click({ Stop-All })
$form.Controls.Add($stopAll)

# RESTART ALL
$restartAll = New-Object System.Windows.Forms.Button
$restartAll.Text     = 'RESTART ALL'
$restartAll.Location = New-Object System.Drawing.Point(260, 375)
$restartAll.Size     = New-Object System.Drawing.Size(120, 35)
$restartAll.Add_Click({ Restart-All })
$form.Controls.Add($restartAll)

# RELOAD DIRECTORY
$reloadButton = New-Object System.Windows.Forms.Button
$reloadButton.Text     = 'Reload Directory'
$reloadButton.Location = New-Object System.Drawing.Point(390, 375)
$reloadButton.Size     = New-Object System.Drawing.Size(125, 35)
$reloadButton.Add_Click({ Reload-WorkersDirectory })
$form.Controls.Add($reloadButton)

# LOG TITLE
$script:LogTitle = New-Object System.Windows.Forms.Label
$script:LogTitle.Text     = 'Live log'
$script:LogTitle.Location = New-Object System.Drawing.Point(20, 420)
$script:LogTitle.Size     = New-Object System.Drawing.Size(700, 25)
$script:LogTitle.Font     = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($script:LogTitle)

# LIVE LOG VIEWER
$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline  = $true
$script:LogBox.ReadOnly   = $true
$script:LogBox.ScrollBars = 'Both'
$script:LogBox.WordWrap   = $false
$script:LogBox.Font       = New-Object System.Drawing.Font('Consolas', 9)
$script:LogBox.Location   = New-Object System.Drawing.Point(20, 450)
$script:LogBox.Size       = New-Object System.Drawing.Size(995, 175)
$script:LogBox.Anchor     =
    [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Bottom -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($script:LogBox)

# CONTROL PANEL MESSAGE LOG
$script:OutputBox = New-Object System.Windows.Forms.TextBox
$script:OutputBox.Multiline  = $true
$script:OutputBox.ReadOnly   = $true
$script:OutputBox.ScrollBars = 'Vertical'
$script:OutputBox.Location   = New-Object System.Drawing.Point(20, 635)
$script:OutputBox.Size       = New-Object System.Drawing.Size(995, 45)
$script:OutputBox.Anchor     =
    [System.Windows.Forms.AnchorStyles]::Bottom -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($script:OutputBox)

# ============================================================
# TIMER
# Every 500 ms: pull new lines from memory into the log box.
# Every 4th tick (2 s): refresh RUNNING/STOPPED labels.
# ============================================================

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500

$timer.Add_Tick({

    $script:TickCount++

    Pump-Hosts

    if ($script:TickCount % 4 -eq 0) {
        Update-Status
    }
    else {
        Update-SelectedLog
    }
})

$timer.Start()

# ============================================================
# FORM CLOSING
# Output pipes belong to this panel, so warn before closing.
# ============================================================

$form.Add_FormClosing({

    param($sender, $e)

    $attached = 0

    foreach ($id in @($script:Hosts.Keys)) {
        if ($script:Hosts[$id].IsAlive) { $attached++ }
    }

    if ($attached -gt 0) {

        $answer = [System.Windows.Forms.MessageBox]::Show(
            "$attached worker(s) started from this panel are still running.`r`n`r`n" +
            "Their output goes directly to this window. If you close it, the output " +
            "pipe is cut and a worker may fail the next time it writes output.`r`n`r`n" +
            "Close the panel anyway?",
            'Workers still running',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $e.Cancel = $true
            return
        }
    }

    $timer.Stop()
})

# ============================================================
# INITIALIZATION
# ============================================================

Add-Log '========================================'
Add-Log 'Redis Worker Control Panel started'
Add-Log '========================================'
Add-Log 'Workers run hidden (no CMD window).'
Add-Log 'STDOUT and STDERR are streamed live into the log box (memory only).'
Add-Log "Worker folder: $script:WorkersPath"

Rebuild-WorkerUI

[void]$form.ShowDialog()