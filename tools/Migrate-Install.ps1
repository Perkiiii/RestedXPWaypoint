[CmdletBinding()]
param()

# One-time, resumable migration of the development checkout and WoW junction.
# Run from PowerShell with its current directory outside either repository path.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$oldRepo = 'E:\Dev\RXPWaypointBridge'
$newRepo = 'E:\Dev\RestedXPWaypoint'
$addonsRoot = 'F:\World of Warcraft\_classic_beta_\Interface\AddOns'
$oldAddon = Join-Path $addonsRoot 'RXPWaypointBridge'
$newAddon = Join-Path $addonsRoot 'RestedXPWaypoint'
$tocName = 'RestedXPWaypoint_Camelot.toc'

function Get-Entry {
    param([Parameter(Mandatory)][string]$Path)

    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Parent directory is unavailable: $parent"
    }
    $matches = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop |
        Where-Object { $_.Name -ceq $leaf })
    if ($matches.Count -gt 1) { throw "More than one filesystem entry matched: $Path" }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Normalize-Path {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-JunctionTarget {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Path)

    if (-not ($Entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
        $Entry.LinkType -ne 'Junction') {
        throw "Expected a junction at $Path; found $($Entry.Attributes) / $($Entry.LinkType)."
    }
    $target = @($Entry.Target) | Select-Object -First 1
    if (-not $target) { throw "Could not resolve the junction target for $Path." }
    return Normalize-Path ([string]$target)
}

function Assert-Repository {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        throw "Git metadata is missing from $Path; refusing to move it."
    }
    foreach ($required in @('Core.lua', $tocName, 'Sync.lua', 'Art\Icons')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $required))) {
            throw "Expected project file or directory is missing: $(Join-Path $Path $required)"
        }
    }
    $tocPath = Join-Path $Path $tocName
    $modules = @(Get-Content -LiteralPath $tocPath | Where-Object { $_ -and $_ -notmatch '^\s*#' })
    if ($modules.Count -eq 0) { throw "The renamed TOC contains no modules: $tocPath" }
    foreach ($module in $modules) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $module) -PathType Leaf)) {
            throw "TOC module does not exist: $module"
        }
    }
}

function Assert-AddonAssets {
    param([Parameter(Mandatory)][string]$AddonPath)

    $serviceIcons = @('Bags', 'ClassTrainer', 'FlightMaster', 'FoodAndDrink', 'Grind',
        'Innkeeper', 'ProfessionTrainer', 'Repair', 'StableMaster')
    foreach ($name in $serviceIcons) {
        $asset = Join-Path $AddonPath "Art\Icons\$name.blp"
        if (-not (Test-Path -LiteralPath $asset -PathType Leaf)) {
            throw "RestedXP Waypoint service icon is unavailable through the new path: $asset"
        }
    }

    $waypointIcons = Join-Path $addonsRoot 'WaypointUI\Art\Icons'
    $questStates = @('Available', 'Incomplete', 'Complete')
    $questTypes = @('', 'Important', 'Campaign', 'Legendary', 'Calling', 'Meta', 'Recurring', 'Repeatable')
    foreach ($state in $questStates) {
        foreach ($type in $questTypes) {
            $asset = Join-Path $waypointIcons "${state}${type}Quest.blp"
            if (-not (Test-Path -LiteralPath $asset -PathType Leaf)) {
                throw "Waypoint UI quest marker texture is unavailable: $asset"
            }
        }
    }
}

function Get-GitState {
    param([Parameter(Mandatory)][string]$Path)

    $head = @(& git -C $Path rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1) {
        throw "Could not read Git HEAD at $Path."
    }
    $status = @(& git -C $Path status --porcelain=v1 --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "Could not read Git status at $Path." }
    return [pscustomobject]@{
        Head = [string]$head[0]
        Status = [string]::Join("`n", [string[]]$status)
    }
}

function Remove-VerifiedJunction {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExpectedTarget)

    $entry = Get-Entry $Path
    if (-not $entry) { return }
    $target = Get-JunctionTarget -Entry $entry -Path $Path
    if ($target -ine (Normalize-Path $ExpectedTarget)) {
        throw "Junction target changed at $Path; expected $ExpectedTarget, found $target."
    }
    # Deliberately omit -Recurse: this removes only the verified junction entry.
    Remove-Item -LiteralPath $Path -Force
}

$repoParent = Split-Path -Parent $oldRepo
if (-not (Test-Path -LiteralPath $repoParent -PathType Container) -or
    -not (Test-Path -LiteralPath $addonsRoot -PathType Container)) {
    throw 'The expected development or WoW AddOns parent directory is unavailable.'
}

$currentDirectory = Normalize-Path $PWD.Path
foreach ($repoPath in @($oldRepo, $newRepo)) {
    $normalizedRepo = Normalize-Path $repoPath
    if ($currentDirectory -ieq $normalizedRepo -or $currentDirectory.StartsWith($normalizedRepo + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Run this script from outside the repository folders. Current directory: $currentDirectory"
    }
}

$oldRepoEntry = Get-Entry $oldRepo
$newRepoEntry = Get-Entry $newRepo
$oldAddonEntry = Get-Entry $oldAddon
$newAddonEntry = Get-Entry $newAddon

if ($oldRepoEntry -and $newRepoEntry) {
    throw "Both repository paths exist. Resolve this manually; nothing was changed: $oldRepo and $newRepo"
}
if (-not $oldRepoEntry -and -not $newRepoEntry) {
    throw "Neither repository path exists. Nothing was changed: $oldRepo / $newRepo"
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is unavailable in PATH; cannot verify repository state.'
}

$repoPathNow = if ($newRepoEntry) { $newRepo } else { $oldRepo }
Assert-Repository $repoPathNow
$initialGitState = Get-GitState $repoPathNow

if ($oldAddonEntry) {
    $oldTarget = Get-JunctionTarget -Entry $oldAddonEntry -Path $oldAddon
    if ($oldTarget -ine (Normalize-Path $oldRepo)) {
        throw "The old addon entry points somewhere unexpected: $oldTarget. Nothing was changed."
    }
}
if ($newAddonEntry) {
    $newTarget = Get-JunctionTarget -Entry $newAddonEntry -Path $newAddon
    if ($newTarget -ine (Normalize-Path $newRepo)) {
        throw "The desired addon path already exists with an unexpected target: $newTarget. Nothing was changed."
    }
}
if (-not $oldRepoEntry -and $newRepoEntry -and -not $oldAddonEntry -and -not $newAddonEntry) {
    throw 'A repository already exists at the destination, but neither addon junction identifies it as a partial migration. Nothing was changed.'
}
if ($oldRepoEntry -and $newAddonEntry) {
    throw 'The old checkout and desired addon junction both exist; this is ambiguous. Nothing was changed.'
}

# A completed run can be checked safely at any time, including with an editor open.
if (-not $oldRepoEntry -and -not $oldAddonEntry -and $newRepoEntry -and $newAddonEntry) {
    Write-Host 'Migration is already complete.'
    Write-Host "Repository: $newRepo"
    Write-Host "WoW addon junction: $newAddon -> $newRepo"
    return
}

$codeProcesses = @(Get-Process -Name Code -ErrorAction SilentlyContinue)
if ($codeProcesses.Count -gt 0) {
    throw 'Close all VS Code windows before migrating; no files or junctions were changed.'
}
$gameTools = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match '^(?i:Wow|WowClassic|WowClassicT|WowT|Wow-64|WorldOfWarcraft|WowUp-CF)$' })
if ($gameTools.Count -gt 0) {
    throw 'Exit WoW and close WoWUp before migrating; no files or junctions were changed.'
}

$oldRepoVolume = Normalize-Path ([System.IO.Path]::GetPathRoot($oldRepo))
$newRepoVolume = Normalize-Path ([System.IO.Path]::GetPathRoot($newRepo))
if ($oldRepoEntry -and $oldRepoVolume -ine $newRepoVolume) {
    throw 'The repository move must stay on one volume to preserve atomic rename behavior.'
}

$movedByThisRun = $false
$verifiedNewInstall = $false
try {
    if ($oldRepoEntry) {
        # Recheck the destination immediately before the same-volume rename.
        if (Get-Entry $newRepo) { throw "Destination appeared during preflight: $newRepo" }
        [System.IO.Directory]::Move($oldRepo, $newRepo)
        $movedByThisRun = $true
    }

    Assert-Repository $newRepo
    $afterMoveGitState = Get-GitState $newRepo
    if ($afterMoveGitState.Head -cne $initialGitState.Head -or
        $afterMoveGitState.Status -cne $initialGitState.Status) {
        throw 'Git HEAD or working-tree status changed during the move; inspect the new repository before continuing.'
    }

    if (-not (Get-Entry $newAddon)) {
        New-Item -ItemType Junction -Path $newAddon -Target $newRepo | Out-Null
    }
    $createdJunction = Get-Entry $newAddon
    $createdTarget = Get-JunctionTarget -Entry $createdJunction -Path $newAddon
    if ($createdTarget -ine (Normalize-Path $newRepo) -or
        -not (Test-Path -LiteralPath (Join-Path $newAddon $tocName)) -or
        -not (Test-Path -LiteralPath (Join-Path $newAddon '.git'))) {
        throw 'The new junction did not resolve to the complete development repository.'
    }
    Assert-Repository $newAddon
    Assert-AddonAssets $newAddon
    $verifiedNewInstall = $true

    # Keep the old junction until the new junction and its contents are verified.
    Remove-VerifiedJunction -Path $oldAddon -ExpectedTarget $oldRepo
    if (Get-Entry $oldAddon) { throw "The old junction remains after cleanup: $oldAddon" }

    $finalGitState = Get-GitState $newRepo
    if ($finalGitState.Head -cne $initialGitState.Head -or
        $finalGitState.Status -cne $initialGitState.Status) {
        throw 'Git HEAD or working-tree status changed during migration; inspect before continuing.'
    }

    Write-Host 'Migration completed and verified.'
    Write-Host "Repository: $newRepo"
    Write-Host "WoW addon junction: $newAddon -> $newRepo"
    Write-Host "Git HEAD: $($finalGitState.Head)"
    Write-Host 'Git working-tree status is unchanged.'
}
catch {
    $failure = $_
    if ($movedByThisRun -and -not $verifiedNewInstall) {
        try {
            $link = Get-Entry $newAddon
            if ($link) {
                # Roll back only a link proven to point at the destination repo.
                $linkTarget = Get-JunctionTarget -Entry $link -Path $newAddon
                if ($linkTarget -ine (Normalize-Path $newRepo)) {
                    throw "Unverified new entry left in place: $newAddon -> $linkTarget"
                }
                Remove-VerifiedJunction -Path $newAddon -ExpectedTarget $newRepo
            }
            if ((Get-Entry $newRepo) -and -not (Get-Entry $oldRepo)) {
                [System.IO.Directory]::Move($newRepo, $oldRepo)
                Write-Warning 'The new junction could not be verified; the repository move was rolled back.'
            }
        }
        catch {
            Write-Warning "Automatic rollback did not finish. Repository data was left in place; rerun after inspecting paths. $($_.Exception.Message)"
        }
    }
    throw $failure
}
