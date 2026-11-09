# Focused Windows PowerShell 5.1 tests for optional VRAM telemetry.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repository 'windows\Vram.psm1'
Import-Module $modulePath -Force
$module = Get-Module Vram
$script:checks = 0
function Assert-Vram {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "VRAM assertion failed: $Message" }
    $script:checks++
    Write-Host "ok $Message"
}
function Parse-Vram {
    param([AllowEmptyString()][string]$Csv)
    & $module { param($Text) ConvertFrom-RamAltmanNvidiaSmi -Csv $Text } $Csv
}

$sample = Parse-Vram 'NVIDIA GPU, 16376, 3231, 12818'
Assert-Vram ($sample.Supported -and $sample.Adapters.Count -eq 1) 'valid NVIDIA memory telemetry is supported'
Assert-Vram ($sample.Adapters[0].TotalBytes -eq (16376L * 1MB)) 'MiB converts to bytes without a 4GiB overflow'
Assert-Vram ($sample.Adapters[0].AvailableBytes -eq (12818L * 1MB)) 'free VRAM comes from reported free, preserving driver reserved memory'
Assert-Vram ([math]::Abs($sample.Adapters[0].AvailablePercent - (12818.0 / 16376 * 100)) -lt 0.00001) 'available percentage uses unrounded VRAM values'
$multiple = Parse-Vram "`"NVIDIA GPU, One`", 100, 20, 79`nNVIDIA GPU Two, 200, 0, 200"
Assert-Vram ($multiple.Supported -and $multiple.Adapters.Count -eq 2 -and $multiple.Adapters[0].Name -eq 'NVIDIA GPU, One') 'CSV handles multiple adapters and quoted comma in name'
Assert-Vram (-not (Parse-Vram 'GPU, 16376, N/A, N/A').Supported) 'unsupported WDDM values remain unknown'
Assert-Vram (-not (Parse-Vram 'GPU, 0, 0, 0').Supported) 'zero total VRAM is refused'
Assert-Vram (-not (Parse-Vram 'GPU, 100, 80, 80').Supported) 'contradictory memory telemetry is refused'
Assert-Vram (-not (Parse-Vram 'GPU, -100, 0, 0').Supported) 'negative memory telemetry is refused'
Assert-Vram (-not (Parse-Vram '').Supported) 'empty driver output remains unknown'
$partial = Parse-Vram "Known GPU, 100, 20, 79`nUnknown GPU, 100, N/A, N/A"
Assert-Vram ($partial.Supported -and $partial.Adapters.Count -eq 1 -and $partial.Reason -like '*Unknown GPU*') 'partial telemetry reports missing adapters honestly'

$private = Join-Path $repository 'private'
$work = Join-Path $private ('test-vram-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force
$fixturePath = Join-Path $work 'fake-nvidia-smi.exe'
$originalMode = $env:RAM_ALTMAN_VRAM_TEST_MODE
try {
    # A small local executable tests subprocess failure/timeout without a GPU.
    $fixtureCode = @'
using System;
using System.Threading;
public static class FakeNvidiaSmi {
    public static int Main(string[] args) {
        string mode = Environment.GetEnvironmentVariable("RAM_ALTMAN_VRAM_TEST_MODE");
        if (mode == "timeout") { Thread.Sleep(10000); return 0; }
        if (mode == "failure") { Console.Error.WriteLine("driver unavailable"); return 9; }
        Console.WriteLine("Fixture GPU, 16376, 3231, 12818");
        return 0;
    }
}
'@
    Add-Type -TypeDefinition $fixtureCode -OutputAssembly $fixturePath -OutputType ConsoleApplication
    & $module {
        param($FixturePath)
        $script:FixtureExecutable = $FixturePath
        function script:Find-RamAltmanNvidiaSmi { return $script:FixtureExecutable }
    } $fixturePath
    $env:RAM_ALTMAN_VRAM_TEST_MODE = 'success'
    $collected = Get-RamAltmanVram
    Assert-Vram ($collected.Supported -and $collected.Adapters[0].Name -eq 'Fixture GPU') 'collector reads a real child process through redirected streams'
    $env:RAM_ALTMAN_VRAM_TEST_MODE = 'failure'
    $failed = Get-RamAltmanVram
    Assert-Vram (-not $failed.Supported -and $failed.Reason -like '*exit 9*') 'driver errors degrade to unknown without throwing'
    $env:RAM_ALTMAN_VRAM_TEST_MODE = 'timeout'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = Get-RamAltmanVram
    $timer.Stop()
    Assert-Vram (-not $timedOut.Supported -and $timedOut.Reason -like '*timed out*' -and $timer.ElapsedMilliseconds -lt 3500) 'hung driver is killed after the bounded 2.5 second wait'
    & $module { $script:FixtureExecutable = $null }
    Assert-Vram (-not (Get-RamAltmanVram).Supported) 'missing nvidia-smi degrades to unknown'
} finally {
    $env:RAM_ALTMAN_VRAM_TEST_MODE = $originalMode
    Import-Module $modulePath -Force
    # This exact generated fixture directory is the only removal target.
    $resolvedWork = [IO.Path]::GetFullPath($work)
    $privatePrefix = [IO.Path]::GetFullPath($private).TrimEnd('\') + '\'
    if (-not $resolvedWork.StartsWith($privatePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refused cleanup outside the project private directory.'
    }
    if (Test-Path -LiteralPath $resolvedWork) { Remove-Item -LiteralPath $resolvedWork -Recurse -Force }
}
Write-Host "$script:checks VRAM checks passed."
