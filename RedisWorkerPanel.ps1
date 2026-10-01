# ============================================================
# RedisWorkerPanel.ps1
# Symfony Redis Worker Control Panel
# Folder-Based BAT Manager
#
# Features:
#   - Select a folder containing .bat files
#   - Enter worker folder path manually
#   - Browse for worker folder
#   - Load manually entered folder
#   - Reload currently opened directory
#   - Start / Stop / Restart individual workers
#   - Start / Stop / Restart all workers
#   - Workers run completely in background
#   - No CMD window displayed
#   - STDOUT redirected to worker log
#   - STDERR redirected to worker log
#   - Live log viewer
#   - PID tracking
#   - Process tree termination
#   - Closing panel does NOT stop workers
#   - Log file is named <worker>-<PID>.log (PID of the hidden worker process)
#   - Log file is emptied automatically when it reaches 50 MB
#   - Log files not modified for 1 day are deleted automatically
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
# CONFIGURATION
# ============================================================

$ProjectPath = '\logs\'

$PanelPath = Split-Path -Parent $MyInvocation.MyCommand.Path

$StatePath = Join-Path $PanelPath 'state'

# Logs are saved in a 'logs' folder next to this script.
$LogPath = Join-Path $PanelPath 'logs'

# Default folder containing BAT files.
$DefaultWorkersPath = $PanelPath

# A worker log is emptied when it reaches this size.
$MaxLogBytes = 50MB

# A log file not modified for this long is deleted.
$MaxLogAge = New-TimeSpan -Days 1

# Run the old-log cleanup at most this often.
$CleanupEverySeconds = 60
$script:LastCleanup = [datetime]::MinValue

# ============================================================
# CREATE DIRECTORIES
# ============================================================

New-Item `
    -ItemType Directory `
    -Force `
    -Path $StatePath |
    Out-Null

New-Item `
    -ItemType Directory `
    -Force `
    -Path $LogPath |
    Out-Null

# ============================================================
# GLOBAL VARIABLES
# ============================================================

$script:WorkersPath = $DefaultWorkersPath

$script:Workers = [ordered]@{}

$script:StatusLabels = @{}

$script:PidLabels = @{}

$script:SelectedWorker = $null

$script:OutputBox = $null

$script:LogBox = $null

$script:LogTitle = $null

$script:WorkerPanel = $null

$script:FolderLabel = $null

$script:PathTextBox = $null

# ============================================================
# CREATE SAFE WORKER ID
# ============================================================

function Get-WorkerId {

    param(
        [string]$BatPath
    )

    $sha =
        [System.Security.Cryptography.SHA256]::Create()

    try {

        $bytes =
            [System.Text.Encoding]::UTF8.GetBytes(
                $BatPath.ToLowerInvariant()
            )

        $hash =
            $sha.ComputeHash($bytes)

        return (
            [System.BitConverter]::ToString($hash)
        ).Replace('-', '').Substring(0, 16)
    }
    finally {

        $sha.Dispose()
    }
}

# ============================================================
# GET STATE FILE
# ============================================================

function Get-StateFile {

    param(
        [string]$WorkerId
    )

    return Join-Path `
        $StatePath `
        "$WorkerId.pid"
}

# ============================================================
# GET SAVED WORKER PID
# ============================================================

function Get-SavedPid {

    param(
        [string]$WorkerId
    )

    $file =
        Get-StateFile $WorkerId

    if (-not (Test-Path $file)) {

        return $null
    }

    try {

        $raw =
            (
                Get-Content `
                    $file `
                    -Raw `
                    -ErrorAction Stop
            ).Trim()

        if ($raw -match '^\d+$') {

            return [int]$raw
        }
    }
    catch {

        return $null
    }

    return $null
}

# ============================================================
# SAVE WORKER PID
# ============================================================

function Save-Pid {

    param(
        [string]$WorkerId,

        [int]$WorkerProcessId
    )

    $file =
        Get-StateFile $WorkerId

    Set-Content `
        -Path $file `
        -Value $WorkerProcessId `
        -Encoding ascii
}

# ============================================================
# CLEAR WORKER PID
# ============================================================

function Clear-Pid {

    param(
        [string]$WorkerId
    )

    $file =
        Get-StateFile $WorkerId

    if (Test-Path $file) {

        Remove-Item `
            $file `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

# ============================================================
# EMPTY LOG WHEN IT REACHES 50 MB
#
# The file is opened with ReadWrite + Delete sharing, so it can be
# emptied while the hidden CMD process still has it open.
# ============================================================

function Limit-LogSize {

    param(
        [string]$Path,

        [string]$Name
    )

    if (-not (Test-Path $Path)) {

        return
    }

    # Cheap check first - only open the file when it is big enough.
    try {

        if ((New-Object System.IO.FileInfo($Path)).Length -lt $MaxLogBytes) {

            return
        }
    }
    catch {

        return
    }

    $stream = $null

    try {

        $stream =
            New-Object System.IO.FileStream(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Write,
                (
                    [System.IO.FileShare]::ReadWrite -bor
                    [System.IO.FileShare]::Delete
                )
            )

        # Stream length is the real size, even while the file is
        # being written by another process.
        if ($stream.Length -ge $MaxLogBytes) {

            $sizeMb =
                [Math]::Round($stream.Length / 1MB, 1)

            $stream.SetLength(0)

            Add-Log `
                "[$Name] log reached $sizeMb MB - emptied."
        }
    }
    catch {

        Add-Log `
            "[$Name] could not check/empty log: $($_.Exception.Message)"
    }
    finally {

        if ($stream) {

            $stream.Dispose()
        }
    }
}

# ============================================================
# FIND THE LOG FILE OF A WORKER
#
# Running  -> <name>-<PID>.log  (PID from the saved PID file)
# Stopped  -> newest <name>-<number>.log still in the logs folder
# ============================================================

function Get-WorkerLogFile {

    param(
        [string]$WorkerId
    )

    if (-not $script:Workers.Contains($WorkerId)) {

        return $null
    }

    $name = $script:Workers[$WorkerId].Name

    $workerPid = Get-SavedPid $WorkerId

    if ($workerPid) {

        return Join-Path $LogPath "$name-$workerPid.log"
    }

    if (-not (Test-Path $LogPath -PathType Container)) {

        return $null
    }

    $pattern = '^' + [regex]::Escape($name) + '-\d+\.log$'

    $latest =
        Get-ChildItem `
            -Path $LogPath `
            -Filter '*.log' `
            -File `
            -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($latest) {

        return $latest.FullName
    }

    return $null
}

# ============================================================
# DELETE LOG FILES NOT MODIFIED FOR 1 DAY
#
# Logs of workers that are currently running are never deleted.
# ============================================================

function Remove-OldLogs {

    if (-not (Test-Path $LogPath -PathType Container)) {

        return
    }

    # Logs that belong to running workers.
    $activeLogs = @{}

    foreach ($WorkerId in @($script:Workers.Keys)) {

        if (Test-WorkerRunning $WorkerId) {

            $runningLog = Get-WorkerLogFile $WorkerId

            if ($runningLog) {

                $activeLogs[$runningLog.ToLowerInvariant()] = $true
            }
        }
    }

    $limit = (Get-Date) - $MaxLogAge

    try {

        $files = @(
            Get-ChildItem `
                -Path $LogPath `
                -Filter '*.log' `
                -File `
                -ErrorAction Stop
        )
    }
    catch {

        return
    }

    foreach ($file in $files) {

        if ($file.LastWriteTime -ge $limit) { continue }

        if ($activeLogs.ContainsKey($file.FullName.ToLowerInvariant())) {

            continue
        }

        try {

            Remove-Item `
                -LiteralPath $file.FullName `
                -Force `
                -ErrorAction Stop

            Add-Log `
                "Deleted old log (no change for 1 day): $($file.Name)"
        }
        catch {

            Add-Log `
                "Could not delete old log $($file.Name): $($_.Exception.Message)"
        }
    }
}

# ============================================================
# ADD MESSAGE TO CONTROL PANEL LOG
# ============================================================

function Add-Log {

    param(
        [string]$Message
    )

    if ($null -eq $script:OutputBox) {

        return
    }

    $time =
        Get-Date -Format 'HH:mm:ss'

    $script:OutputBox.AppendText(
        "[$time] $Message`r`n"
    )

    $script:OutputBox.SelectionStart =
        $script:OutputBox.Text.Length

    $script:OutputBox.ScrollToCaret()
}

# ============================================================
# LOAD ALL BAT FILES
# ============================================================

function Load-Workers {

    $script:Workers =
        [ordered]@{}

    if (-not (Test-Path $script:WorkersPath -PathType Container)) {

        Add-Log "Worker folder does not exist:"
        Add-Log $script:WorkersPath

        return
    }

    try {

        $batFiles = @(
            Get-ChildItem `
                -Path $script:WorkersPath `
                -Filter '*.bat' `
                -File `
                -ErrorAction Stop |
            Sort-Object Name
        )
    }
    catch {

        Add-Log "Unable to read worker folder."
        Add-Log $_.Exception.Message

        return
    }

    foreach ($batFile in $batFiles) {

        $workerId =
            Get-WorkerId $batFile.FullName

        $workerName =
            $batFile.BaseName

        $script:Workers[$workerId] = @{
            Id       = $workerId
            Name     = $workerName
            Bat      = $batFile.FullName
            FileName = $batFile.Name
        }
    }

    Add-Log `
        "Loaded $($script:Workers.Count) BAT file(s)."
}

# ============================================================
# CHECK IF WORKER IS RUNNING
# ============================================================

function Test-WorkerRunning {

    param(
        [string]$WorkerId
    )

    # IMPORTANT:
    #
    # Never use $pid.
    #
    # PowerShell already owns the read-only $PID variable.

    $workerPid =
        Get-SavedPid $WorkerId

    if (-not $workerPid) {

        return $false
    }

    try {

        Get-Process `
            -Id $workerPid `
            -ErrorAction Stop |
            Out-Null

        return $true
    }
    catch {

        Clear-Pid $WorkerId

        return $false
    }
}

# ============================================================
# START WORKER
# ============================================================

function Start-Worker {

    param(
        [string]$WorkerId
    )

    if (-not $script:Workers.Contains($WorkerId)) {

        Add-Log "Worker no longer exists."

        return
    }

    $worker =
        $script:Workers[$WorkerId]

    # ========================================================
    # ALREADY RUNNING?
    # ========================================================

    if (Test-WorkerRunning $WorkerId) {

        Add-Log `
            "[$($worker.Name)] already running."

        return
    }

    $batFile =
        $worker.Bat

    # ========================================================
    # CHECK BAT
    # ========================================================

    if (-not (Test-Path $batFile)) {

        Add-Log `
            "[$($worker.Name)] BAT file not found:"

        Add-Log $batFile

        return
    }

    # ========================================================
    # CREATE LOG DIRECTORY
    # ========================================================

    if (-not (Test-Path $LogPath)) {

        New-Item `
            -ItemType Directory `
            -Force `
            -Path $LogPath |
            Out-Null
    }

    # ========================================================
    # CONTROL PANEL LOG
    # ========================================================

    Add-Log '========================================'

    Add-Log `
        "[$($worker.Name)] starting..."

    Add-Log `
        "[$($worker.Name)] BAT: $batFile"

    # ========================================================
    # START HIDDEN WORKER
    #
    # The log name contains the PID, and a PID only exists once a
    # process is running. So a hidden PowerShell is started first;
    # it reads its own $PID, builds <name>-<PID>.log, writes a start
    # marker, then runs the BAT with all output redirected into that
    # file.
    #
    # The panel saves that PowerShell PID, so the log file is always
    # <name>-<saved PID>.log, and taskkill /T stops the whole tree.
    # ========================================================

    try {

        $q = { param([string]$v) $v.Replace("'", "''") }

        $template = @'
$log = Join-Path '__LOGDIR__' ('__NAME__-' + $PID + '.log')
$sep = '=================================================='
Add-Content -LiteralPath $log -Encoding UTF8 -Value ($sep + "`r`nWorker starting: __NAME__ (PID $PID)`r`nStarted: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n" + $sep)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'cmd.exe'
$psi.Arguments = '/c call "__BAT__" >> "' + $log + '" 2>&1'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$child = [System.Diagnostics.Process]::Start($psi)
$child.WaitForExit()
'@

        $inner =
            $template.
                Replace('__LOGDIR__', (& $q $LogPath)).
                Replace('__NAME__',   (& $q $worker.Name)).
                Replace('__BAT__',    $batFile)

        $encoded =
            [Convert]::ToBase64String(
                [System.Text.Encoding]::Unicode.GetBytes($inner)
            )

        $process =
            Start-Process `
                -FilePath 'powershell.exe' `
                -ArgumentList @(
                    '-NoProfile',
                    '-ExecutionPolicy', 'Bypass',
                    '-WindowStyle', 'Hidden',
                    '-EncodedCommand', $encoded
                ) `
                -WorkingDirectory $ProjectPath `
                -WindowStyle Hidden `
                -PassThru

        # ====================================================
        # SAVE PID
        # ====================================================

        Save-Pid `
            -WorkerId $WorkerId `
            -WorkerProcessId $process.Id

        $logFile =
            Join-Path $LogPath "$($worker.Name)-$($process.Id).log"

        Add-Log `
            "[$($worker.Name)] STARTED"

        Add-Log `
            "[$($worker.Name)] PID: $($process.Id)"

        Add-Log `
            "[$($worker.Name)] window hidden."

        Add-Log `
            "[$($worker.Name)] LOG: $logFile"
    }
    catch {

        Add-Log `
            "[$($worker.Name)] START ERROR"

        Add-Log `
            $_.Exception.Message
    }

    Update-Status
}

# ============================================================
# STOP WORKER
# ============================================================

function Stop-Worker {

    param(
        [string]$WorkerId
    )

    if (-not $script:Workers.Contains($WorkerId)) {

        Add-Log "Worker no longer exists."

        return
    }

    $worker =
        $script:Workers[$WorkerId]

    $workerPid =
        Get-SavedPid $WorkerId

    if (-not $workerPid) {

        Add-Log `
            "[$($worker.Name)] no saved PID."

        Update-Status

        return
    }

    Add-Log `
        "[$($worker.Name)] stopping PID $workerPid..."

    try {

        # ====================================================
        # TERMINATE COMPLETE PROCESS TREE
        #
        # CMD
        #   └── PHP
        #       └── Worker
        #
        # /T = tree
        # /F = force
        # ====================================================

        $result =
            & taskkill.exe `
                /PID $workerPid `
                /T `
                /F `
                2>&1

        foreach ($line in $result) {

            if ($line) {

                Add-Log `
                    "[$($worker.Name)] $line"
            }
        }

        Add-Log `
            "[$($worker.Name)] STOPPED"
    }
    catch {

        Add-Log `
            "[$($worker.Name)] STOP ERROR"

        Add-Log `
            $_.Exception.Message
    }

    Clear-Pid $WorkerId

    Update-Status
}

# ============================================================
# RESTART WORKER
# ============================================================

function Restart-Worker {

    param(
        [string]$WorkerId
    )

    if (-not $script:Workers.Contains($WorkerId)) {

        return
    }

    $worker =
        $script:Workers[$WorkerId]

    Add-Log `
        "[$($worker.Name)] restarting..."

    Stop-Worker $WorkerId

    Start-Sleep -Milliseconds 700

    Start-Worker $WorkerId
}

# ============================================================
# START ALL
# ============================================================

function Start-All {

    Add-Log '========================================'

    Add-Log 'STARTING ALL WORKERS'

    Add-Log '========================================'

    foreach ($WorkerId in @($script:Workers.Keys)) {

        Start-Worker $WorkerId

        Start-Sleep -Milliseconds 300
    }
}

# ============================================================
# STOP ALL
# ============================================================

function Stop-All {

    Add-Log '========================================'

    Add-Log 'STOPPING ALL WORKERS'

    Add-Log '========================================'

    foreach ($WorkerId in @($script:Workers.Keys)) {

        Stop-Worker $WorkerId
    }
}

# ============================================================
# RESTART ALL
# ============================================================

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
# READ LAST LOG LINES
# ============================================================

function Read-LastLines {

    param(
        [string]$Path,

        [int]$Count = 200
    )

    if (-not $Path -or -not (Test-Path $Path)) {

        return "Log file not created yet.`r`n"
    }

    try {

        $lines =
            Get-Content `
                -Path $Path `
                -Tail $Count `
                -ErrorAction Stop

        return (
            ($lines -join "`r`n") +
            "`r`n"
        )
    }
    catch {

        return (
            "Unable to read log: " +
            $_.Exception.Message +
            "`r`n"
        )
    }
}

# ============================================================
# UPDATE SELECTED LOG
# ============================================================

function Update-SelectedLog {

    if (-not $script:SelectedWorker) {

        if ($script:LogBox) {

            $script:LogBox.Text = ''
        }

        return
    }

    if (-not $script:Workers.Contains($script:SelectedWorker)) {

        $script:SelectedWorker = $null

        return
    }

    $worker =
        $script:Workers[$script:SelectedWorker]

    # ========================================================
    # TITLE
    # ========================================================

    if ($script:LogTitle) {

        $script:LogTitle.Text =
            "Live log: $($worker.Name)"
    }

    # ========================================================
    # READ LOG
    # ========================================================

    if ($script:LogBox) {

        $script:LogBox.Text =
            Read-LastLines `
                -Path (Get-WorkerLogFile $script:SelectedWorker) `
                -Count 200

        $script:LogBox.SelectionStart =
            $script:LogBox.Text.Length

        $script:LogBox.ScrollToCaret()
    }
}

# ============================================================
# UPDATE STATUS
# ============================================================

function Update-Status {

    # Empty any worker log that reached 50 MB.
    foreach ($WorkerId in @($script:Workers.Keys)) {

        $w = $script:Workers[$WorkerId]

        $wLog = Get-WorkerLogFile $WorkerId

        if ($wLog) {

            Limit-LogSize `
                -Path $wLog `
                -Name $w.Name
        }
    }

    # Delete logs not modified for 1 day (throttled).
    if (
        ((Get-Date) - $script:LastCleanup).TotalSeconds -ge
        $CleanupEverySeconds
    ) {

        $script:LastCleanup = Get-Date

        Remove-OldLogs
    }

    foreach ($WorkerId in @($script:Workers.Keys)) {

        if (-not $script:StatusLabels.ContainsKey($WorkerId)) {

            continue
        }

        $statusLabel =
            $script:StatusLabels[$WorkerId]

        $pidLabel =
            $script:PidLabels[$WorkerId]

        if (Test-WorkerRunning $WorkerId) {

            $statusLabel.Text =
                'RUNNING'

            $statusLabel.ForeColor =
                [System.Drawing.Color]::Green

            $workerPid =
                Get-SavedPid $WorkerId

            $pidLabel.Text =
                "PID: $workerPid"
        }
        else {

            $statusLabel.Text =
                'STOPPED'

            $statusLabel.ForeColor =
                [System.Drawing.Color]::Red

            $pidLabel.Text =
                'PID: -'
        }
    }

    Update-SelectedLog
}

# ============================================================
# CREATE WORKER ROW
# ============================================================

function Add-WorkerRow {

    param(
        [string]$WorkerId,

        [hashtable]$Worker,

        [int]$Y
    )

    # ========================================================
    # GROUP
    # ========================================================

    $group =
        New-Object System.Windows.Forms.GroupBox

    $group.Text =
        "$($Worker.Name)  [$($Worker.FileName)]"

    $group.Location =
        New-Object System.Drawing.Point(
            10,
            $Y
        )

    $group.Size =
        New-Object System.Drawing.Size(
            950,
            70
        )

    $script:WorkerPanel.Controls.Add($group)

    # ========================================================
    # STATUS
    # ========================================================

    $status =
        New-Object System.Windows.Forms.Label

    $status.Text =
        'STOPPED'

    $status.Font =
        New-Object System.Drawing.Font(
            'Segoe UI',
            10,
            [System.Drawing.FontStyle]::Bold
        )

    $status.ForeColor =
        [System.Drawing.Color]::Red

    $status.Location =
        New-Object System.Drawing.Point(
            15,
            28
        )

    $status.Size =
        New-Object System.Drawing.Size(
            90,
            25
        )

    $group.Controls.Add($status)

    $script:StatusLabels[$WorkerId] =
        $status

    # ========================================================
    # PID
    # ========================================================

    $pidLabel =
        New-Object System.Windows.Forms.Label

    $pidLabel.Text =
        'PID: -'

    $pidLabel.Location =
        New-Object System.Drawing.Point(
            105,
            30
        )

    $pidLabel.Size =
        New-Object System.Drawing.Size(
            100,
            22
        )

    $group.Controls.Add($pidLabel)

    $script:PidLabels[$WorkerId] =
        $pidLabel

    # ========================================================
    # START
    # ========================================================

    $startButton =
        New-Object System.Windows.Forms.Button

    $startButton.Text =
        'Start'

    $startButton.Location =
        New-Object System.Drawing.Point(
            215,
            22
        )

    $startButton.Size =
        New-Object System.Drawing.Size(
            85,
            32
        )

    $startButton.Tag =
        $WorkerId

    $startButton.Add_Click({

        Start-Worker $this.Tag
    })

    $group.Controls.Add($startButton)

    # ========================================================
    # STOP
    # ========================================================

    $stopButton =
        New-Object System.Windows.Forms.Button

    $stopButton.Text =
        'Stop'

    $stopButton.Location =
        New-Object System.Drawing.Point(
            310,
            22
        )

    $stopButton.Size =
        New-Object System.Drawing.Size(
            85,
            32
        )

    $stopButton.Tag =
        $WorkerId

    $stopButton.Add_Click({

        Stop-Worker $this.Tag
    })

    $group.Controls.Add($stopButton)

    # ========================================================
    # RESTART
    # ========================================================

    $restartButton =
        New-Object System.Windows.Forms.Button

    $restartButton.Text =
        'Restart'

    $restartButton.Location =
        New-Object System.Drawing.Point(
            405,
            22
        )

    $restartButton.Size =
        New-Object System.Drawing.Size(
            85,
            32
        )

    $restartButton.Tag =
        $WorkerId

    $restartButton.Add_Click({

        Restart-Worker $this.Tag
    })

    $group.Controls.Add($restartButton)

    # ========================================================
    # VIEW LOG
    # ========================================================

    $viewButton =
        New-Object System.Windows.Forms.Button

    $viewButton.Text =
        'View Log'

    $viewButton.Location =
        New-Object System.Drawing.Point(
            500,
            22
        )

    $viewButton.Size =
        New-Object System.Drawing.Size(
            90,
            32
        )

    $viewButton.Tag =
        $WorkerId

    $viewButton.Add_Click({

        $script:SelectedWorker =
            $this.Tag

        Update-SelectedLog
    })

    $group.Controls.Add($viewButton)

    # ========================================================
    # OPEN FOLDER
    # ========================================================

    $openButton =
        New-Object System.Windows.Forms.Button

    $openButton.Text =
        'Open Folder'

    $openButton.Location =
        New-Object System.Drawing.Point(
            600,
            22
        )

    $openButton.Size =
        New-Object System.Drawing.Size(
            100,
            32
        )

    $openButton.Tag =
        $Worker.Bat

    $openButton.Add_Click({

        $batPath =
            $this.Tag

        if (Test-Path $batPath) {

            Start-Process `
                'explorer.exe' `
                -ArgumentList (
                    "/select,`"$batPath`""
                )
        }
    })

    $group.Controls.Add($openButton)
}

# ============================================================
# REBUILD WORKER UI
# ============================================================

function Rebuild-WorkerUI {

    if ($null -eq $script:WorkerPanel) {

        return
    }

    # ========================================================
    # CLEAR OLD UI
    # ========================================================

    $script:WorkerPanel.Controls.Clear()

    $script:StatusLabels.Clear()

    $script:PidLabels.Clear()

    # ========================================================
    # LOAD BAT FILES
    # ========================================================

    Load-Workers

    # ========================================================
    # CREATE WORKER ROWS
    # ========================================================

    $y = 10

    foreach ($WorkerId in @($script:Workers.Keys)) {

        $worker =
            $script:Workers[$WorkerId]

        Add-WorkerRow `
            -WorkerId $WorkerId `
            -Worker $worker `
            -Y $y

        $y += 78
    }

    # ========================================================
    # EMPTY FOLDER
    # ========================================================

    if ($script:Workers.Count -eq 0) {

        $emptyLabel =
            New-Object System.Windows.Forms.Label

        $emptyLabel.Text =
            'No .bat files found in this folder.'

        $emptyLabel.Location =
            New-Object System.Drawing.Point(
                15,
                20
            )

        $emptyLabel.Size =
            New-Object System.Drawing.Size(
                500,
                30
            )

        $emptyLabel.ForeColor =
            [System.Drawing.Color]::Gray

        $script:WorkerPanel.Controls.Add(
            $emptyLabel
        )
    }

    # ========================================================
    # SCROLL SIZE
    # ========================================================

    $script:WorkerPanel.AutoScrollMinSize =
        New-Object System.Drawing.Size(
            0,
            [Math]::Max(
                $y + 10,
                100
            )
        )

    # ========================================================
    # SELECT FIRST WORKER
    # ========================================================

    if ($script:SelectedWorker -eq $null) {

        if ($script:Workers.Count -gt 0) {

            $script:SelectedWorker =
                @($script:Workers.Keys)[0]
        }
    }
    else {

        if (-not $script:Workers.Contains(
            $script:SelectedWorker
        )) {

            if ($script:Workers.Count -gt 0) {

                $script:SelectedWorker =
                    @($script:Workers.Keys)[0]
            }
            else {

                $script:SelectedWorker =
                    $null
            }
        }
    }

    Update-Status
}

# ============================================================
# LOAD FOLDER FROM PATH
# ============================================================

function Load-WorkersFromPath {

    param(
        [string]$Path
    )

    # ========================================================
    # CLEAN INPUT
    # ========================================================

    if ($null -eq $Path) {

        return
    }

    $Path =
        $Path.Trim()

    # Remove surrounding quotes if user pasted:
    #
    # "C:\some\folder"
    #
    if (
        $Path.Length -ge 2 -and
        (
            ($Path.StartsWith('"') -and $Path.EndsWith('"')) -or
            ($Path.StartsWith("'") -and $Path.EndsWith("'"))
        )
    ) {

        $Path =
            $Path.Substring(
                1,
                $Path.Length - 2
            )
    }

    $Path =
        $Path.Trim()

    # ========================================================
    # EMPTY PATH
    # ========================================================

    if ([string]::IsNullOrWhiteSpace($Path)) {

        Add-Log 'Folder path is empty.'

        return
    }

    # ========================================================
    # CHECK DIRECTORY
    # ========================================================

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

        $resolvedPath =
            (Resolve-Path $Path -ErrorAction Stop).Path
    }
    catch {

        Add-Log 'Unable to resolve directory path.'

        Add-Log $_.Exception.Message

        return
    }

    # ========================================================
    # SET CURRENT WORKER DIRECTORY
    # ========================================================

    $script:WorkersPath =
        $resolvedPath

    # ========================================================
    # UPDATE PATH INPUT
    # ========================================================

    if ($script:PathTextBox) {

        $script:PathTextBox.Text =
            $script:WorkersPath
    }

    # ========================================================
    # UPDATE FOLDER LABEL
    # ========================================================

    if ($script:FolderLabel) {

        $script:FolderLabel.Text =
            "Folder: $script:WorkersPath"
    }

    # ========================================================
    # LOG
    # ========================================================

    Add-Log '========================================'

    Add-Log 'WORKER DIRECTORY CHANGED'

    Add-Log "Directory: $script:WorkersPath"

    Add-Log 'Loading BAT files...'

    Add-Log '========================================'

    # ========================================================
    # RESET SELECTED WORKER
    # ========================================================

    $script:SelectedWorker =
        $null

    # ========================================================
    # REBUILD
    # ========================================================

    Rebuild-WorkerUI

    Add-Log '========================================'

    Add-Log 'DIRECTORY LOADED'

    Add-Log "Workers detected: $($script:Workers.Count)"

    Add-Log '========================================'
}

# ============================================================
# RELOAD CURRENT DIRECTORY
# ============================================================

function Reload-WorkersDirectory {

    Add-Log '========================================'

    Add-Log 'RELOADING WORKER DIRECTORY'

    Add-Log "Directory: $script:WorkersPath"

    Add-Log 'Scanning for BAT files...'

    Add-Log '========================================'

    # ========================================================
    # Remember currently selected worker
    # ========================================================

    $previousWorker =
        $script:SelectedWorker

    # ========================================================
    # Rebuild worker list
    # ========================================================

    Rebuild-WorkerUI

    # ========================================================
    # Restore selected worker if it still exists
    # ========================================================

    if (
        $previousWorker -and
        $script:Workers.Contains($previousWorker)
    ) {

        $script:SelectedWorker =
            $previousWorker

        Update-SelectedLog
    }

    Add-Log `
        "Directory reload completed."

    Add-Log `
        "Workers detected: $($script:Workers.Count)"
}

# ============================================================
# SELECT WORKER FOLDER
# ============================================================

function Select-WorkersFolder {

    $dialog =
        New-Object System.Windows.Forms.FolderBrowserDialog

    $dialog.Description =
        'Select the folder containing your BAT worker files'

    $dialog.SelectedPath =
        $script:WorkersPath

    $result =
        $dialog.ShowDialog()

    if (
        $result -eq
        [System.Windows.Forms.DialogResult]::OK
    ) {

        # ====================================================
        # Put selected directory into the textbox
        # ====================================================

        if ($script:PathTextBox) {

            $script:PathTextBox.Text =
                $dialog.SelectedPath
        }

        # ====================================================
        # Load it
        # ====================================================

        Load-WorkersFromPath `
            $dialog.SelectedPath
    }
}

# ============================================================
# CREATE MAIN FORM
# ============================================================

$form =
    New-Object System.Windows.Forms.Form

$form.Text =
    'Symfony Redis Worker Control Panel'

$form.Size =
    New-Object System.Drawing.Size(
        1050,
        750
    )

$form.MinimumSize =
    New-Object System.Drawing.Size(
        900,
        650
    )

$form.StartPosition =
    'CenterScreen'

$form.BackColor =
    [System.Drawing.Color]::White

# ============================================================
# HEADER
# ============================================================

$header =
    New-Object System.Windows.Forms.Label

$header.Text =
    'Symfony Redis Workers'

$header.Font =
    New-Object System.Drawing.Font(
        'Segoe UI',
        18,
        [System.Drawing.FontStyle]::Bold
    )

$header.Location =
    New-Object System.Drawing.Point(
        20,
        15
    )

$header.Size =
    New-Object System.Drawing.Size(
        500,
        40
    )

$form.Controls.Add($header)

# ============================================================
# INFORMATION
# ============================================================

$note =
    New-Object System.Windows.Forms.Label

$note.Text =
    'Workers run independently in the background. Closing this panel does NOT stop them.'

$note.Location =
    New-Object System.Drawing.Point(
        22,
        55
    )

$note.Size =
    New-Object System.Drawing.Size(
        850,
        25
    )

$form.Controls.Add($note)

# ============================================================
# FOLDER PATH LABEL
# ============================================================

$pathLabel =
    New-Object System.Windows.Forms.Label

$pathLabel.Text =
    'Worker Folder:'

$pathLabel.Location =
    New-Object System.Drawing.Point(
        20,
        86
    )

$pathLabel.Size =
    New-Object System.Drawing.Size(
        90,
        25
    )

$form.Controls.Add($pathLabel)

# ============================================================
# FOLDER PATH INPUT
# ============================================================

$script:PathTextBox =
    New-Object System.Windows.Forms.TextBox

$script:PathTextBox.Text =
    $script:WorkersPath

$script:PathTextBox.Location =
    New-Object System.Drawing.Point(
        110,
        82
    )

$script:PathTextBox.Size =
    New-Object System.Drawing.Size(
        590,
        28
    )

$script:PathTextBox.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right

# ============================================================
# ENTER KEY
#
# User can type:
#
# C:\Users\dell\Desktop\workers
#
# and press ENTER.
# ============================================================

$script:PathTextBox.Add_KeyDown({

    if (
        $_.KeyCode -eq
        [System.Windows.Forms.Keys]::Enter
    ) {

        $_.SuppressKeyPress = $true

        Load-WorkersFromPath `
            $script:PathTextBox.Text
    }
})

$form.Controls.Add($script:PathTextBox)

# ============================================================
# BROWSE FOLDER
# ============================================================

$browseButton =
    New-Object System.Windows.Forms.Button

$browseButton.Text =
    'Browse'

$browseButton.Location =
    New-Object System.Drawing.Point(
        710,
        80
    )

$browseButton.Size =
    New-Object System.Drawing.Size(
        90,
        32
    )

$browseButton.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Right

$browseButton.Add_Click({

    Select-WorkersFolder
})

$form.Controls.Add($browseButton)

# ============================================================
# LOAD FOLDER
# ============================================================

$loadFolderButton =
    New-Object System.Windows.Forms.Button

$loadFolderButton.Text =
    'Load Folder'

$loadFolderButton.Location =
    New-Object System.Drawing.Point(
        810,
        80
    )

$loadFolderButton.Size =
    New-Object System.Drawing.Size(
        100,
        32
    )

$loadFolderButton.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Right

$loadFolderButton.Add_Click({

    Load-WorkersFromPath `
        $script:PathTextBox.Text
})

$form.Controls.Add($loadFolderButton)

# ============================================================
# CURRENT FOLDER LABEL
# ============================================================

$script:FolderLabel =
    New-Object System.Windows.Forms.Label

$script:FolderLabel.Text =
    "Folder: $script:WorkersPath"

$script:FolderLabel.Location =
    New-Object System.Drawing.Point(
        20,
        112
    )

$script:FolderLabel.Size =
    New-Object System.Drawing.Size(
        900,
        25
    )

$script:FolderLabel.AutoEllipsis =
    $true

$form.Controls.Add($script:FolderLabel)

# ============================================================
# WORKER PANEL
# ============================================================

$script:WorkerPanel =
    New-Object System.Windows.Forms.Panel

$script:WorkerPanel.Location =
    New-Object System.Drawing.Point(
        20,
        145
    )

$script:WorkerPanel.Size =
    New-Object System.Drawing.Size(
        995,
        220
    )

$script:WorkerPanel.BorderStyle =
    [System.Windows.Forms.BorderStyle]::FixedSingle

$script:WorkerPanel.AutoScroll =
    $true

$script:WorkerPanel.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right

$form.Controls.Add($script:WorkerPanel)

# ============================================================
# START ALL
# ============================================================

$startAll =
    New-Object System.Windows.Forms.Button

$startAll.Text =
    'START ALL'

$startAll.Location =
    New-Object System.Drawing.Point(
        20,
        375
    )

$startAll.Size =
    New-Object System.Drawing.Size(
        110,
        35
    )

$startAll.Add_Click({

    Start-All
})

$form.Controls.Add($startAll)

# ============================================================
# STOP ALL
# ============================================================

$stopAll =
    New-Object System.Windows.Forms.Button

$stopAll.Text =
    'STOP ALL'

$stopAll.Location =
    New-Object System.Drawing.Point(
        140,
        375
    )

$stopAll.Size =
    New-Object System.Drawing.Size(
        110,
        35
    )

$stopAll.Add_Click({

    Stop-All
})

$form.Controls.Add($stopAll)

# ============================================================
# RESTART ALL
# ============================================================

$restartAll =
    New-Object System.Windows.Forms.Button

$restartAll.Text =
    'RESTART ALL'

$restartAll.Location =
    New-Object System.Drawing.Point(
        260,
        375
    )

$restartAll.Size =
    New-Object System.Drawing.Size(
        120,
        35
    )

$restartAll.Add_Click({

    Restart-All
})

$form.Controls.Add($restartAll)

# ============================================================
# RELOAD DIRECTORY
# ============================================================

$reloadButton =
    New-Object System.Windows.Forms.Button

$reloadButton.Text =
    'Reload Directory'

$reloadButton.Location =
    New-Object System.Drawing.Point(
        390,
        375
    )

$reloadButton.Size =
    New-Object System.Drawing.Size(
        125,
        35
    )

$reloadButton.Add_Click({

    Reload-WorkersDirectory
})

$form.Controls.Add($reloadButton)

# ============================================================
# LOG TITLE
# ============================================================

$script:LogTitle =
    New-Object System.Windows.Forms.Label

$script:LogTitle.Text =
    'Live log'

$script:LogTitle.Location =
    New-Object System.Drawing.Point(
        20,
        420
    )

$script:LogTitle.Size =
    New-Object System.Drawing.Size(
        700,
        25
    )

$script:LogTitle.Font =
    New-Object System.Drawing.Font(
        'Segoe UI',
        11,
        [System.Drawing.FontStyle]::Bold
    )

$form.Controls.Add($script:LogTitle)

# ============================================================
# LOG VIEWER
# ============================================================

$script:LogBox =
    New-Object System.Windows.Forms.TextBox

$script:LogBox.Multiline =
    $true

$script:LogBox.ReadOnly =
    $true

$script:LogBox.ScrollBars =
    'Both'

$script:LogBox.WordWrap =
    $false

$script:LogBox.Font =
    New-Object System.Drawing.Font(
        'Consolas',
        9
    )

$script:LogBox.Location =
    New-Object System.Drawing.Point(
        20,
        450
    )

$script:LogBox.Size =
    New-Object System.Drawing.Size(
        995,
        175
    )

$script:LogBox.Anchor =
    [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Bottom -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right

$form.Controls.Add($script:LogBox)

# ============================================================
# CONTROL PANEL LOG
# ============================================================

$script:OutputBox =
    New-Object System.Windows.Forms.TextBox

$script:OutputBox.Multiline =
    $true

$script:OutputBox.ReadOnly =
    $true

$script:OutputBox.ScrollBars =
    'Vertical'

$script:OutputBox.Location =
    New-Object System.Drawing.Point(
        20,
        635
    )

$script:OutputBox.Size =
    New-Object System.Drawing.Size(
        995,
        45
    )

$script:OutputBox.Anchor =
    [System.Windows.Forms.AnchorStyles]::Bottom -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right

$form.Controls.Add($script:OutputBox)

# ============================================================
# TIMER
# ============================================================

$timer =
    New-Object System.Windows.Forms.Timer

$timer.Interval =
    2000

$timer.Add_Tick({

    Update-Status
})

$timer.Start()

# ============================================================
# FORM CLOSING
# ============================================================

$form.Add_FormClosing({

    # ========================================================
    # IMPORTANT:
    #
    # DO NOT STOP WORKERS.
    #
    # Workers continue running after the panel closes.
    # ========================================================

    $timer.Stop()
})

# ============================================================
# INITIALIZATION
# ============================================================

Add-Log '========================================'

Add-Log 'Redis Worker Control Panel started'

Add-Log '========================================'

Add-Log 'Workers run in the background.'

Add-Log 'CMD windows are hidden.'

Add-Log 'STDOUT and STDERR are redirected to worker logs.'

Add-Log 'Closing this panel will NOT stop workers.'

Add-Log 'Each worker log is emptied automatically at 50 MB.'

Add-Log 'Logs not modified for 1 day are deleted automatically.'

Add-Log "Worker folder: $script:WorkersPath"

Rebuild-WorkerUI

# ============================================================
# SHOW WINDOW
# ============================================================

[void]$form.ShowDialog()