<#
.SYNOPSIS
  Sets the version, commits, tags vX.Y.Z and pushes. The tag starts the
  release workflow on GitHub (build, sign, publish).

.EXAMPLE
  .\scripts\release.ps1 0.0.2
  .\scripts\release.ps1 0.0.2 -SkipTests -Yes

.DESCRIPTION
  - pubspec.yaml:        version: X.Y.Z+N  (N = previous build number + 1;
                         Android only installs updates with a higher number)
  - snap/snapcraft.yaml: version: 'X.Y.Z'
  Checks first: clean working tree, branch main, tag does not exist yet,
  version higher than the current one, flutter analyze and flutter test.
#>
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Version,
  [switch]$SkipTests,
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

function Fail([string]$msg) { Write-Host "[!] $msg" -ForegroundColor Red; exit 1 }
function Step([string]$msg) { Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Run([string]$exe, [string[]]$arguments) {
  & $exe @arguments
  if ($LASTEXITCODE -ne 0) { Fail "$exe $($arguments -join ' ') failed." }
}
# Files keep UTF-8 without BOM and their line endings.
function Write-Text([string]$path, [string]$text) {
  [IO.File]::WriteAllText((Resolve-Path $path), $text, (New-Object Text.UTF8Encoding $false))
}

$Version = $Version.TrimStart('v')
if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "Version must look like 1.2.3 (got '$Version')." }
$tag = "v$Version"

Step 'Checking the repository'
if (git status --porcelain) { Fail 'The working tree has uncommitted changes. Commit or stash them first.' }
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne 'main') { Fail "Releases are made from main (current branch: $branch)." }
git fetch --tags origin 2>$null
if (git tag --list $tag) { Fail "Tag $tag already exists." }

$pubspec = [IO.File]::ReadAllText((Resolve-Path 'pubspec.yaml'))
$m = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $m.Success) { Fail 'No "version: X.Y.Z+N" line found in pubspec.yaml.' }
$current = [version]$m.Groups[1].Value
$build = [int]$m.Groups[2].Value + 1
if ([version]$Version -le $current) { Fail "Version $Version is not higher than the current $current." }
Write-Host "    $current+$($m.Groups[2].Value)  ->  $Version+$build"

if (-not $SkipTests) {
  Step 'flutter analyze'
  Run 'flutter' @('analyze')
  Step 'flutter test'
  Run 'flutter' @('test')
}

Step 'Setting the version'
Write-Text 'pubspec.yaml' ([regex]::Replace($pubspec, '(?m)^version:\s*\d+\.\d+\.\d+\+\d+', "version: $Version+$build"))
$snap = [IO.File]::ReadAllText((Resolve-Path 'snap/snapcraft.yaml'))
Write-Text 'snap/snapcraft.yaml' ([regex]::Replace($snap, "(?m)^version:\s*'[^']*'", "version: '$Version'"))
git --no-pager diff --stat

if (-not $Yes) {
  $answer = Read-Host "`nCommit, tag $tag and push to origin? This starts the release. [y/N]"
  if ($answer -notin @('y', 'Y', 'j', 'J')) {
    git checkout -- pubspec.yaml snap/snapcraft.yaml
    Fail 'Cancelled; the version change was undone.'
  }
}

Step "Commit and tag $tag"
Run 'git' @('add', 'pubspec.yaml', 'snap/snapcraft.yaml')
Run 'git' @('commit', '-m', "release $tag")
Run 'git' @('tag', '-a', $tag, '-m', "RedCourier $Version")

Step 'Push'
Run 'git' @('push', 'origin', 'main')
Run 'git' @('push', 'origin', $tag)

Write-Host "`nDone. The release workflow for $tag is running:" -ForegroundColor Green
$remote = (git remote get-url origin).Trim() -replace '\.git$', '' -replace '^git@github\.com:', 'https://github.com/'
Write-Host "    $remote/actions"
