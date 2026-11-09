# Optional NVIDIA VRAM telemetry. PowerShell 5.1+, no driver changes or files.
Set-StrictMode -Version Latest

function New-RamAltmanVramUnavailable {
    param([Parameter(Mandatory = $true)][string]$Reason)
    [pscustomobject]@{
        Supported = $false
        Adapters = @()
        Reason = $Reason
    }
}

function Find-RamAltmanNvidiaSmi {
    $candidates = @()
    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
    }
    if ($env:ProgramW6432 -and $env:ProgramW6432 -ne $env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramW6432 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
    }
    if ($env:SystemRoot) { $candidates += Join-Path $env:SystemRoot 'System32\nvidia-smi.exe' }
    foreach ($candidate in $candidates) {
        if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
    }
    # Resolve an executable, never an alias/function/script and never a shell command.
    $command = Get-Command -Name 'nvidia-smi.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and [IO.File]::Exists($command.Source)) { return $command.Source }
    return $null
}

function ConvertFrom-RamAltmanNvidiaSmi {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Csv)
    $adapters = @()
    $unavailableNames = @()
    if ([string]::IsNullOrWhiteSpace($Csv)) {
        return New-RamAltmanVramUnavailable -Reason 'NVIDIA did not return GPU memory telemetry.'
    }
    try {
        $rows = @($Csv | ConvertFrom-Csv -Header 'Name', 'TotalMiB', 'UsedMiB', 'FreeMiB' -ErrorAction Stop)
        foreach ($row in $rows) {
            $name = ([string]$row.Name).Trim()
            if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\r\n\x00-\x1f]') { continue }
            $values = @()
            $valid = $true
            foreach ($field in @('TotalMiB', 'UsedMiB', 'FreeMiB')) {
                [decimal]$number = 0
                $textValue = ([string]$row.$field).Trim()
                if (-not [decimal]::TryParse($textValue, [Globalization.NumberStyles]::AllowDecimalPoint,
                        [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -lt 0) {
                    $valid = $false
                    break
                }
                $values += $number
            }
            if (-not $valid -or $values[0] -le 0 -or $values[1] -gt $values[0] -or
                $values[2] -gt $values[0] -or ($values[1] + $values[2]) -gt ($values[0] + 1) -or
                $values[0] -gt ([decimal][long]::MaxValue / 1MB)) {
                $unavailableNames += $name
                continue
            }
            # NVIDIA's nounits values remain MiB. Reserved driver memory can make
            # total != used + free; use the reported free value, not subtraction.
            $adapters += [pscustomobject]@{
                Name = $name
                TotalBytes = [long]($values[0] * 1MB)
                UsedBytes = [long]($values[1] * 1MB)
                AvailableBytes = [long]($values[2] * 1MB)
                AvailablePercent = [double]($values[2] * 100 / $values[0])
                Source = 'nvidia-smi (NVIDIA driver, MiB)'
            }
        }
    } catch {
        return New-RamAltmanVramUnavailable -Reason 'NVIDIA returned unreadable GPU memory telemetry.'
    }
    if ($adapters.Count -eq 0) {
        return New-RamAltmanVramUnavailable -Reason 'NVIDIA GPU memory telemetry is unavailable or unsupported by this driver.'
    }
    $reason = ''
    if ($unavailableNames.Count -gt 0) {
        $reason = 'Memory telemetry unavailable for: ' + ($unavailableNames -join ', ') + '.'
    }
    [pscustomobject]@{ Supported = $true; Adapters = @($adapters); Reason = $reason }
}

function Get-RamAltmanVram {
    [CmdletBinding()]
    param()
    $process = $null
    try {
        if ($env:OS -ne 'Windows_NT') {
            return New-RamAltmanVramUnavailable -Reason 'Optional VRAM telemetry requires Windows and an NVIDIA driver.'
        }
        $executable = Find-RamAltmanNvidiaSmi
        if (-not $executable) {
            return New-RamAltmanVramUnavailable -Reason 'NVIDIA nvidia-smi was not found; AMD/Intel/shared GPU memory is not measured.'
        }
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $executable
        $start.Arguments = '--query-gpu=name,memory.total,memory.used,memory.free --format=csv,noheader,nounits'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        if (-not $process.Start()) {
            return New-RamAltmanVramUnavailable -Reason 'NVIDIA memory telemetry could not start.'
        }
        # Drain both pipes asynchronously to prevent a full stderr pipe deadlock.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(2500)) {
            try { $process.Kill() } catch { }
            return New-RamAltmanVramUnavailable -Reason 'NVIDIA memory telemetry timed out (2.5 seconds).'
        }
        if ($process.ExitCode -ne 0) {
            return New-RamAltmanVramUnavailable -Reason ('NVIDIA memory telemetry failed (exit ' + $process.ExitCode + ').')
        }
        if (-not $stdout.Wait(100) -or -not $stderr.Wait(100)) {
            return New-RamAltmanVramUnavailable -Reason 'NVIDIA memory telemetry output did not complete.'
        }
        return ConvertFrom-RamAltmanNvidiaSmi -Csv $stdout.Result
    } catch {
        # The optional collector must never prevent the RAM report from running.
        return New-RamAltmanVramUnavailable -Reason 'Optional NVIDIA GPU memory telemetry could not be read.'
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

Export-ModuleMember -Function Get-RamAltmanVram
