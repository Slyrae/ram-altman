# Shared helpers for the Windows Task Scheduler integration (PowerShell 5.1+).
Set-StrictMode -Version Latest

function Get-RamAltmanTaskIdentity {
    param([Parameter(Mandatory = $true)][string]$RepositoryPath)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    [pscustomobject]@{
        Sid = $identity.User.Value
        Name = $identity.Name
        TaskName = 'RamAltman-' + $identity.User.Value
        Description = 'RamAltman Windows monitor | Owner=' + $identity.User.Value + ' | Repository=' + [IO.Path]::GetFullPath($RepositoryPath)
    }
}

function Assert-RamAltmanTaskName {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name.Length -gt 200 -or $Name -match '[\\/:*?"<>|\r\n]' -or [string]::IsNullOrWhiteSpace($Name)) {
        throw 'TaskName must be a nonempty task name, without path separators or special characters.'
    }
}

function Get-RamAltmanTaskArguments {
    param(
        [Parameter(Mandatory = $true)][string]$EntryPath,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )
    foreach ($path in @($EntryPath, $ConfigPath)) {
        if ($path -match '["\r\n]') { throw 'Task paths cannot contain quotes or line breaks.' }
    }
    '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $EntryPath, $ConfigPath
}

function Assert-RamAltmanOwnedTask {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$EntryPath
    )
    $actions = @($Task.Actions)
    $expectedPrefix = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $EntryPath + '" -ConfigPath "'
    if ($Task.Description -cne $Description -or $actions.Count -ne 1 -or
        -not [string]::Equals([string]$actions[0].Execute, $Executable, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$actions[0].Arguments).StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$actions[0].Arguments).EndsWith('"')) {
        throw 'A task with this name already exists and does not belong to this RamAltman checkout. It was left unchanged. Choose another TaskName.'
    }
}

function Enter-RamAltmanConfigControlLock {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    try { return [IO.File]::Open($fullPath + '.control.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another RamAltman control command is running, or the configuration folder is unavailable. Try again after it finishes.' }
}

function Update-RamAltmanConfigEnabled {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [IO.FileStream]$ControlLock
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'Configuration is missing. Run Setup.cmd first.' }
    $ownLock = $null
    if ($null -eq $ControlLock) { $ownLock = Enter-RamAltmanConfigControlLock -Path $fullPath }
    $temporary = $fullPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $raw = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
        if ($null -eq $raw -or $raw -isnot [pscustomobject] -or $raw -is [array]) { throw 'Configuration must be a JSON object.' }
        $previous = $true
        if ($null -ne $raw.PSObject.Properties['Enabled']) {
            if ($raw.Enabled -isnot [bool]) { throw 'Enabled must be true or false.' }
            $previous = $raw.Enabled
        }
        $raw | Add-Member -MemberType NoteProperty -Name Enabled -Value $Enabled -Force
        [IO.File]::WriteAllText($temporary, ($raw | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::Replace($temporary, $fullPath, [Management.Automation.Language.NullString]::Value)
        return [bool]$previous
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if ($null -ne $ownLock) { $ownLock.Dispose() }
    }
}

function Get-RamAltmanLauncherSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$OwnerSid,
        [object[]]$PriorSnapshot = @()
    )
    $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    $selected = New-Object 'System.Collections.Generic.HashSet[uint32]'
    foreach ($candidate in $all) {
        if (-not [string]::Equals([string]$candidate.ExecutablePath, $Executable, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $matches = $false
        foreach ($expected in $Arguments) {
            if ([string]$candidate.CommandLine -and ([string]$candidate.CommandLine).TrimEnd().EndsWith(' ' + $expected, [StringComparison]::OrdinalIgnoreCase)) { $matches = $true; break }
        }
        if (-not $matches) { continue }
        try { $owner = Invoke-CimMethod -InputObject $candidate -MethodName GetOwnerSid -ErrorAction Stop }
        catch {
            $stillPresent = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + [int]$candidate.ProcessId) -ErrorAction SilentlyContinue
            if ($null -eq $stillPresent -or $stillPresent.CreationDate -ne $candidate.CreationDate) { continue }
            throw
        }
        if ($owner.ReturnValue -eq 0 -and $owner.Sid -eq $OwnerSid) { $null = $selected.Add([uint32]$candidate.ProcessId) }
    }
    # Kept-open handles bind parent identities across Stop-ScheduledTask. They
    # prevent PID reuse and let a later scan find children spawned just before
    # shutdown even after the launcher itself has exited.
    foreach ($candidate in $all) {
        foreach ($prior in $PriorSnapshot) {
            if ($candidate.ParentProcessId -ne $prior.ProcessId) { continue }
            $parent = $prior.ProcessObject
            $born = $candidate.CreationDate.ToUniversalTime()
            if ($born.Ticks -lt $prior.StartTimeUtcTicks) { continue }
            if ($parent.HasExited -and $born -gt $parent.ExitTime.ToUniversalTime()) { continue }
            $null = $selected.Add([uint32]$candidate.ProcessId)
            break
        }
    }
    do {
        $added = $false
        foreach ($candidate in $all) {
            if ($selected.Contains([uint32]$candidate.ParentProcessId) -and -not $selected.Contains([uint32]$candidate.ProcessId)) {
                $parent = $all | Where-Object { $_.ProcessId -eq $candidate.ParentProcessId } | Select-Object -First 1
                if ($null -ne $parent -and $candidate.CreationDate -ge $parent.CreationDate) { $null = $selected.Add([uint32]$candidate.ProcessId); $added = $true }
            }
        }
    } while ($added)
    foreach ($candidate in $all) {
        if (-not $selected.Contains([uint32]$candidate.ProcessId)) { continue }
        try {
            $process = Get-Process -Id $candidate.ProcessId -ErrorAction Stop
            $null = $process.Handle
            $started = $process.StartTime.ToUniversalTime().Ticks
            $module = $process.MainModule
            if ($null -eq $module -or $process.HasExited) { continue }
            # CIM timestamps have microsecond precision; reject PID reuse during the snapshot.
            if ([math]::Floor([decimal]$started / 10) -ne [math]::Floor([decimal]$candidate.CreationDate.ToUniversalTime().Ticks / 10)) { continue }
            [pscustomobject]@{ ProcessId = [int]$candidate.ProcessId; StartTimeUtcTicks = $started; ExecutablePath = $module.FileName; ProcessObject = $process }
        } catch [Microsoft.PowerShell.Commands.ProcessCommandException] { continue }
        catch [ArgumentException] { continue }
        catch [InvalidOperationException] { continue }
    }
}

function Get-RamAltmanSnapshotProcess {
    param([Parameter(Mandatory = $true)]$Snapshot)
    try {
        $process = Get-Process -Id $Snapshot.ProcessId -ErrorAction Stop
        $null = $process.Handle
        $module = $process.MainModule
        if ($null -eq $module -or $process.HasExited) { return }
        if ($process.StartTime.ToUniversalTime().Ticks -ne $Snapshot.StartTimeUtcTicks -or
            -not [string]::Equals($module.FileName, $Snapshot.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) { return }
        return $process
    } catch [Microsoft.PowerShell.Commands.ProcessCommandException] { return }
    catch [ArgumentException] { return }
    catch [InvalidOperationException] { return }
}
