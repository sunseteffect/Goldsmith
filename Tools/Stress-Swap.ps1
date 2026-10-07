# Swaps a big fake account in for a performance test, and back out.
#
#   .\Stress-Swap.ps1 -Use       # back up your data, load fake data
#   .\Stress-Swap.ps1 -Restore   # put your data back
#
# Run with WoW closed: the game reads saved data when you log in and writes
# it when you log out, so a swap while it's running gets overwritten.
# -Use copies your Goldsmith.lua to Goldsmith.real.lua and writes the fake
# one in its place (Make-StressData.lua). -Restore keeps the fake file,
# with the /gsm perf results in it, as Goldsmith.stress-results.lua, and
# puts Goldsmith.real.lua back. Anything you do in game in between is lost.
# The account folder is found by itself (the one with Goldsmith's saved
# data); with several, pass -Account <folder name under WTF\Account>.
param(
    [switch]$Use,
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
        Where-Object { Test-Path (Join-Path $_.FullName 'SavedVariables\Goldsmith.lua') })
    if ($found.Count -ne 1) {
        throw "Found $($found.Count) accounts with Goldsmith data. Pass -Account <folder name under WTF\Account>."
    }
    $Account = $found[0].Name
}
$saved = Join-Path $wow "WTF\Account\$Account\SavedVariables"
$data = Join-Path $saved 'Goldsmith.lua'
$backup = Join-Path $saved 'Goldsmith.real.lua'
$results = Join-Path $saved 'Goldsmith.stress-results.lua'
$lua = 'C:\Program Files (x86)\Lua\5.1\lua.exe'

if (Get-Process -Name 'Wow', 'WowT', 'WowB' -ErrorAction SilentlyContinue) {
    throw 'Close WoW first: it would overwrite the swap when you log out.'
}

if ($Use) {
    if (Test-Path $backup) {
        throw "Goldsmith.real.lua already exists, so fake data may be loaded now. Run -Restore first."
    }
    Copy-Item $data $backup
    & $lua (Join-Path $PSScriptRoot 'Make-StressData.lua') $backup $data $Characters $Days $Entries
    if ($LASTEXITCODE -ne 0) {
        Copy-Item $backup $data -Force
        Remove-Item $backup
        throw 'Making the fake data failed; your data is unchanged.'
    }
    Write-Host 'Fake data loaded. Log in, run /gsm perf, then close WoW and run -Restore.'
}
elseif ($Restore) {
    if (-not (Test-Path $backup)) { throw 'No Goldsmith.real.lua: nothing to restore.' }
    Copy-Item $data $results -Force
    Copy-Item $backup $data -Force
    Remove-Item $backup
    Write-Host "Your data is back. Test results kept in $results."
}
else {
    Write-Host 'Use -Use to load fake data or -Restore to put yours back.'
}
