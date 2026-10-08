# Swaps other saved data in for a test, and back out.
#
#   .\Stress-Swap.ps1 -Use       # back up your data, load a big fake account
#   .\Stress-Swap.ps1 -Fresh     # back up your data, start with none
#   .\Stress-Swap.ps1 -Restore   # put your data back
#
# Run with WoW closed: the game reads saved data when you log in and writes
# it when you log out, so a swap while it's running gets overwritten.
# -Use copies your Goldsmith.lua to Goldsmith.real.lua and writes the fake
# one in its place (Make-StressData.lua). -Fresh moves it (and the game's
# Goldsmith.lua.bak) aside, so Goldsmith starts as on a new install: the
# welcome message and getting started checklist. -Restore keeps the test
# file, with whatever the test recorded (/gsm perf results), as
# Goldsmith.stress-results.lua or Goldsmith.fresh-results.lua, and puts
# Goldsmith.real.lua back. Anything you do in game in between is lost:
# sales, purchases and crafts made during the test aren't in your data.
# The account folder is found by itself (the one with Goldsmith's saved
# data); with several, pass -Account <folder name under WTF\Account>.
param(
    [switch]$Use,
    [switch]$Fresh,
    [switch]$Restore,
    [int]$Characters = 24,
    [int]$Days = 365,
    [int]$Entries = 20000,
    [string]$Account
)
$ErrorActionPreference = 'Stop'

$wow = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')
if (-not $Account) {
    $found = @(Get-ChildItem (Join-Path $wow 'WTF\Account') -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'SavedVariables\Goldsmith.real.lua') })
    if ($found.Count -eq 0) {
        $found = @(Get-ChildItem (Join-Path $wow 'WTF\Account') -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName 'SavedVariables\Goldsmith.lua') })
    }
    if ($found.Count -ne 1) {
        throw "Found $($found.Count) accounts with Goldsmith data. Pass -Account <folder name under WTF\Account>."
    }
    $Account = $found[0].Name
}
$saved = Join-Path $wow "WTF\Account\$Account\SavedVariables"
$data = Join-Path $saved 'Goldsmith.lua'
$gameBackup = Join-Path $saved 'Goldsmith.lua.bak'
$backup = Join-Path $saved 'Goldsmith.real.lua'
$backupBak = Join-Path $saved 'Goldsmith.real.lua.bak'
$freshMark = Join-Path $saved 'Goldsmith.fresh-test'
$lua = 'C:\Program Files (x86)\Lua\5.1\lua.exe'

if (Get-Process -Name 'Wow', 'WowT', 'WowB' -ErrorAction SilentlyContinue) {
    throw 'Close WoW first: it would overwrite the swap when you log out.'
}

if (($Use -or $Fresh) -and (Test-Path $backup)) {
    throw "Goldsmith.real.lua already exists, so test data may be loaded now. Run -Restore first."
}

if ($Use) {
    Copy-Item $data $backup
    & $lua (Join-Path $PSScriptRoot 'Make-StressData.lua') $backup $data $Characters $Days $Entries
    if ($LASTEXITCODE -ne 0) {
        Copy-Item $backup $data -Force
        Remove-Item $backup
        throw 'Making the fake data failed; your data is unchanged.'
    }
    Write-Host 'Fake data loaded. Log in, run /gsm perf, then close WoW and run -Restore.'
}
elseif ($Fresh) {
    Move-Item $data $backup
    if (Test-Path $gameBackup) { Move-Item $gameBackup $backupBak -Force }
    New-Item -ItemType File $freshMark -Force | Out-Null
    Write-Host 'Goldsmith will start empty, like a new install. Close WoW and run -Restore when done.'
}
elseif ($Restore) {
    if (-not (Test-Path $backup)) { throw 'No Goldsmith.real.lua: nothing to restore.' }
    $name = if (Test-Path $freshMark) { 'Goldsmith.fresh-results.lua' } else { 'Goldsmith.stress-results.lua' }
    $results = Join-Path $saved $name
    if (Test-Path $data) { Copy-Item $data $results -Force }
    Copy-Item $backup $data -Force
    Remove-Item $backup
    if (Test-Path $backupBak) { Move-Item $backupBak $gameBackup -Force }
    if (Test-Path $freshMark) { Remove-Item $freshMark }
    Write-Host "Your data is back. Test data kept in $results."
}
else {
    Write-Host 'Use -Use to load fake data, -Fresh to start empty, or -Restore to put yours back.'
}
