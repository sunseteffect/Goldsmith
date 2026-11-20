# Builds the release zip for CurseForge from a commit.
#
#   .\Package.ps1                 # from HEAD
#   .\Package.ps1 -Ref v2.4       # from a tag or branch
#   .\Package.ps1 -Out C:\tmp     # somewhere other than Downloads
#
# Takes the files from git, not the folder, so only committed files ship and
# nothing local (saved notes, test zips) slips in. Leaves out the dev-only
# Tools/, .github/, .gitignore, CLAUDE.md and Media's icon script. The zip holds one Goldsmith/ folder, as
# CurseForge and a manual install into Interface\AddOns expect, and is named
# from the TOC's Version at that commit: Goldsmith-<version>.zip.
param(
    [string]$Ref = 'HEAD',
    [string]$Out = (Join-Path $env:USERPROFILE 'Downloads')
)
$ErrorActionPreference = 'Stop'

$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { $git = 'C:\Program Files\Git\cmd\git.exe' }
$repo = Split-Path $PSScriptRoot -Parent

$toc = & $git -C $repo show "${Ref}:Goldsmith.toc"
if ($LASTEXITCODE) { throw "No Goldsmith.toc at $Ref" }
$version = ($toc | Select-String '^## Version:\s*(\S+)').Matches.Groups[1].Value
if (-not $version) { throw "No '## Version:' line in Goldsmith.toc at $Ref" }

$dirty = & $git -C $repo status --porcelain --untracked-files=no
if ($Ref -eq 'HEAD' -and $dirty) {
    Write-Warning "Uncommitted changes aren't in the zip (it's built from $Ref)"
}

$zip = Join-Path $Out "Goldsmith-$version.zip"
& $git -C $repo archive --format=zip --prefix=Goldsmith/ -o $zip $Ref -- . `
    ':(exclude)Tools' ':(exclude).github' ':(exclude).gitignore' ':(exclude)Media/*.ps1' ':(exclude)CLAUDE.md'
if ($LASTEXITCODE) { throw "git archive failed" }

# Every file the TOC loads must be in the zip, and nothing dev-only
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try { $names = $archive.Entries | ForEach-Object FullName } finally { $archive.Dispose() }
$missing = $toc | Where-Object { $_ -match '^\s*[^#\s].*\.(lua|xml)\s*$' } |
    ForEach-Object { 'Goldsmith/' + $_.Trim().Replace('\', '/') } | Where-Object { $names -notcontains $_ }
if ($missing) { throw "Files the TOC loads are missing from the zip: $($missing -join ', ')" }
$stray = $names | Where-Object { $_ -match '^Goldsmith/(Tools|\.github)/|\.ps1$|CLAUDE\.md$' }
if ($stray) { throw "Dev-only files in the zip: $($stray -join ', ')" }

Write-Host "Built $zip (version $version from $Ref, $($names.Count) entries)"
