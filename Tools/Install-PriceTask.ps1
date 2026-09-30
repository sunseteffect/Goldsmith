# Registers a Windows scheduled task that runs Fetch-PriceData.ps1 every hour.
# Runs as you, only while you're logged in (no password stored; the saved
# Blizzard credentials can only be read by your Windows user anyway).
#
#   .\Install-PriceTask.ps1            # install or update
#   .\Install-PriceTask.ps1 -Remove    # uninstall

param([switch]$Remove)

$name = 'Goldsmith Price Data'

if ($Remove) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    Write-Host "Removed '$name'"
    return
}

$script = Join-Path $PSScriptRoot 'Fetch-PriceData.ps1'
# Started through a headless console (Windows 11): powershell.exe on its
# own flashes a window every run, even with -WindowStyle Hidden
$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
    -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
# Hourly at :15 past (Blizzard refreshes about hourly), starting now.
$start = (Get-Date).Date.AddHours((Get-Date).Hour).AddMinutes(15)
$trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Hours 1)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Fetches WoW commodity prices from the Blizzard API into the Goldsmith addon folder.' -Force | Out-Null
Write-Host "Installed '$name' (hourly at :15). Log: $env:LOCALAPPDATA\Goldsmith\fetch.log"
