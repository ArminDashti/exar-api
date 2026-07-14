<#
.SYNOPSIS
    Build and run the API stack with Docker Compose locally or over SSH.

.DESCRIPTION
    Uses the project-root Dockerfile and docker-compose.yml. When --ssh-string
    is omitted, runs against the local Docker daemon and builds on this machine.
    When --ssh-string is set, the image is built locally, saved, transferred to
    the remote host, loaded there, and compose is started without a remote build.
    When --delete-volume=yes, existing compose volumes are removed before the
    stack is recreated.

.PARAMETER SshString
    SSH config alias for remote Docker (e.g. example). The script prepends "ssh"
    when connecting; do not include "ssh" in the value. When omitted, localhost Docker is used.

.PARAMETER DeleteVolume
    Whether to remove data volumes before starting. Default: no.

.EXAMPLE
    .\run-on-docker.ps1

.EXAMPLE
    .\run-on-docker.ps1 --delete-volume=yes

.EXAMPLE
    .\run-on-docker.ps1 --ssh-string=example --delete-volume=no
#>
[CmdletBinding()]
param(
    [Alias('ssh-string')]
    [string]$SshString,
    [Alias('delete-volume')]
    [string]$DeleteVolume = 'no',
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-RunOnDockerHelp {
    Write-Host @'
exar API Docker run - build and start the legacy API stack

Usage:
  .\run-on-docker.ps1 [--ssh-string=<connection>] [--delete-volume=<no|yes>] [--help]

Arguments:
  --ssh-string=<connection>   Remote target, e.g. "ssh server-name",
                              host@user@password, or host@port@user@password.
                              Builds the image locally, transfers it to the server,
                              then starts compose remotely. When omitted, localhost Docker is used.
  --delete-volume=<no|yes>    Remove named volumes before starting (default: no)
  --help, -h                  Show this help message and exit

Examples:
  .\run-on-docker.ps1
  .\run-on-docker.ps1 --help
  .\run-on-docker.ps1 --delete-volume=yes
  .\run-on-docker.ps1 --ssh-string="ssh myvps"

Requires docker-compose.yml in this directory.
API: http://localhost:8080
'@ -ForegroundColor Cyan
}

function Remove-SurroundingQuotes {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }

    $Value = $Value.Trim()
    if (($Value.StartsWith('"') -and $Value.EndsWith('"')) -or ($Value.StartsWith("'") -and $Value.EndsWith("'"))) {
        return $Value.Substring(1, $Value.Length - 2).Trim()
    }
    return $Value
}

function Normalize-CliParameterValue {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }

    $Value = Remove-SurroundingQuotes -Value $Value.Trim()
    if ($Value -match '^--?(?<param>[\w-]+)(?:=(?<rest>.*))?$') {
        $paramKey = ($Matches['param'] -replace '-', '_').ToLowerInvariant()
        $nameKey = ($Name -replace '-', '_').ToLowerInvariant()
        if ($paramKey -eq $nameKey) {
            if ($null -ne $Matches['rest'] -and $Matches['rest'] -ne '') {
                return Remove-SurroundingQuotes -Value $Matches['rest']
            }
            return $null
        }
    }
    return $Value
}

function Merge-CliArguments {
    param([hashtable]$BoundParameters, [string[]]$RemainingArguments)

    $RemainingArguments = @($RemainingArguments)
    $merged = @{}
    foreach ($key in $BoundParameters.Keys) {
        $normalizedKey = ([regex]::Replace($key, '([a-z0-9])([A-Z])', '$1_$2')).ToLowerInvariant()
        if ($normalizedKey -in @('remainingarguments', 'help')) { continue }
        if ($null -eq $BoundParameters[$key] -or $BoundParameters[$key] -eq '') { continue }

        $normalizedValue = Normalize-CliParameterValue -Name $normalizedKey -Value ([string]$BoundParameters[$key])
        if ($null -ne $normalizedValue -and $normalizedValue -ne '') {
            $merged[$normalizedKey] = $normalizedValue
        }
    }

    $index = 0
    while ($index -lt $RemainingArguments.Count) {
        $argument = $RemainingArguments[$index]
        if ($argument -match '^--?(?<name>[\w-]+)(?:=(?<value>.*))?$') {
            $normalizedKey = ($Matches['name'] -replace '-', '_').ToLowerInvariant()
            if ($normalizedKey -in @('help', 'h')) {
                $merged['help'] = $true
                $index++
                continue
            }
            if ($null -ne $Matches['value'] -and $Matches['value'] -ne '') {
                $merged[$normalizedKey] = Remove-SurroundingQuotes -Value $Matches['value']
                $index++
            }
            elseif (($index + 1) -lt $RemainingArguments.Count -and $RemainingArguments[$index + 1] -notmatch '^-') {
                $merged[$normalizedKey] = Remove-SurroundingQuotes -Value $RemainingArguments[$index + 1]
                $index += 2
            }
            else {
                $merged[$normalizedKey] = $true
                $index++
            }
        }
        elseif ($argument -match '^(-h|-help|--help|-\?|/\?)$') {
            $merged['help'] = $true
            $index++
        }
        else {
            $index++
        }
    }
    return $merged
}

function Test-Truthy {
    param([string]$Value)

    switch ($Value.ToLowerInvariant()) {
        { $_ -in @('yes', 'true', '1', 'y', 'on') } { return $true }
        default { return $false }
    }
}

function Resolve-SshTarget {
    param([string]$SshString)

    if ([string]::IsNullOrWhiteSpace($SshString)) {
        return [pscustomobject]@{
            IsLocal  = $true
            SshAlias = $null
        }
    }

    $alias = $SshString.Trim()

    if ($alias -match '^(?i)ssh(\s|$)') {
        throw 'Invalid --ssh-string value. Pass only the SSH config alias (e.g. --ssh-string=example). Do not include "ssh".'
    }

    if ([string]::IsNullOrWhiteSpace($alias)) {
        throw 'Invalid --ssh-string value. Example: --ssh-string=example'
    }

    return [pscustomobject]@{
        IsLocal  = $false
        SshAlias = $alias
    }
}

function Invoke-RemoteShell {
    param(
        [pscustomobject]$Target,
        [string]$Command,
        [string]$WorkingDirectory = $null
    )

    $remoteCommand = if ($WorkingDirectory) { "cd '$WorkingDirectory' && $Command" } else { $Command }

    if ($Target.IsLocal) {
        if ($WorkingDirectory) {
            Push-Location $WorkingDirectory
            try { Invoke-Expression $Command | Out-Null }
            finally { Pop-Location }
        }
        else {
            Invoke-Expression $Command | Out-Null
        }
        if ($LASTEXITCODE -ne 0) { throw "Command failed (exit $LASTEXITCODE): $Command" }
        return
    }

    & ssh $Target.SshAlias $remoteCommand
    if ($LASTEXITCODE -ne 0) { throw "Remote command failed (exit $LASTEXITCODE): $remoteCommand" }
}

function Sync-ProjectToRemote {
    param(
        [pscustomobject]$Target,
        [string]$LocalRoot,
        [string]$RemotePath
    )

    $excluded = @('.git', 'agent-logs', 'data', 'bin', 'obj')
    $items = Get-ChildItem -Path $LocalRoot -Force | Where-Object { $excluded -notcontains $_.Name }

    & ssh $Target.SshAlias "mkdir -p '$RemotePath'"
    if ($LASTEXITCODE -ne 0) { throw "Failed to create remote directory: $RemotePath" }
    foreach ($item in $items) {
        & scp -o StrictHostKeyChecking=accept-new -r $item.FullName "$($Target.SshAlias):$RemotePath/"
        if ($LASTEXITCODE -ne 0) { throw "Failed to copy '$($item.Name)'." }
    }
}

function Get-StackManifest {
    param([string]$ProjectRoot)

    $manifestPath = Join-Path $ProjectRoot '.docker/stack.manifest.json'
    if (-not (Test-Path $manifestPath)) { return $null }
    return Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
}

function Get-RemoteWorkDir {
    param([string]$ProjectRoot)

    $manifest = Get-StackManifest -ProjectRoot $ProjectRoot
    if ($manifest -and $manifest.stackName) {
        return "/opt/docker/$($manifest.stackName)"
    }
    return '/opt/docker/expenses-api'
}

function Get-StackImageTag {
    param([string]$ProjectRoot)

    $manifest = Get-StackManifest -ProjectRoot $ProjectRoot
    if ($manifest -and $manifest.imageTag) {
        return [string]$manifest.imageTag
    }
    return 'expenses-api:latest'
}

function Build-LocalDockerImage {
    param(
        [string]$ProjectRoot,
        [string]$ImageTag
    )

    Write-Host "Building image '$ImageTag' on this machine..." -ForegroundColor Cyan
    Push-Location $ProjectRoot
    try {
        & docker build -t $ImageTag .
        if ($LASTEXITCODE -ne 0) { throw "docker build failed (exit $LASTEXITCODE)" }
    }
    finally {
        Pop-Location
    }
    Write-Host "Image build complete." -ForegroundColor Green
}

function Copy-FileToRemote {
    param(
        [pscustomobject]$Target,
        [string]$LocalPath,
        [string]$RemotePath
    )

    & scp -o StrictHostKeyChecking=accept-new $LocalPath "$($Target.SshAlias):$RemotePath"
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy image tarball to remote." }
}

function Transfer-DockerImageToRemote {
    param(
        [pscustomobject]$Target,
        [string]$ProjectRoot,
        [string]$ImageTag
    )

    $stackName = 'exar'
    $manifest = Get-StackManifest -ProjectRoot $ProjectRoot
    if ($manifest -and $manifest.stackName) {
        $stackName = [string]$manifest.stackName
    }

    $localTar = Join-Path $env:TEMP "$stackName-docker-image.tar"
    $remoteTar = "/tmp/$stackName-docker-image.tar"

    try {
        Build-LocalDockerImage -ProjectRoot $ProjectRoot -ImageTag $ImageTag

        Write-Host "Saving image to tarball..." -ForegroundColor Cyan
        if (Test-Path $localTar) { Remove-Item -Path $localTar -Force }
        & docker save -o $localTar $ImageTag
        if ($LASTEXITCODE -ne 0) { throw "docker save failed (exit $LASTEXITCODE)" }

        $tarSizeMb = [math]::Round((Get-Item $localTar).Length / 1MB, 1)
        Write-Host "Transferring image ($tarSizeMb MB) to remote host..." -ForegroundColor Cyan
        Copy-FileToRemote -Target $Target -LocalPath $localTar -RemotePath $remoteTar

        Write-Host "Loading image on remote host..." -ForegroundColor Cyan
        Invoke-RemoteShell -Target $Target -Command "docker load -i '$remoteTar' && rm -f '$remoteTar'"
        Write-Host "Image loaded on remote host." -ForegroundColor Green
    }
    finally {
        if (Test-Path $localTar) { Remove-Item -Path $localTar -Force -ErrorAction SilentlyContinue }
    }
}

if ($Help) {
    Show-RunOnDockerHelp
    Get-Help $PSCommandPath -Full
    exit 0
}

$cliArgs = Merge-CliArguments -BoundParameters $PSBoundParameters -RemainingArguments $RemainingArguments
if ($cliArgs['help']) {
    Show-RunOnDockerHelp
    Get-Help $PSCommandPath -Full
    exit 0
}

$sshStringValue = if ($cliArgs['ssh_string']) { [string]$cliArgs['ssh_string'] } else { [string]$SshString }
$sshStringValue = Normalize-CliParameterValue -Name 'ssh_string' -Value $sshStringValue
$deleteVolumeValue = if ($cliArgs['delete_volume']) { [string]$cliArgs['delete_volume'] } else { [string]$DeleteVolume }
$deleteVolumeValue = Normalize-CliParameterValue -Name 'delete_volume' -Value $deleteVolumeValue
$removeVolumes = Test-Truthy -Value $deleteVolumeValue

$ProjectRoot = $PSScriptRoot
$target = Resolve-SshTarget -SshString $sshStringValue
$workDir = if ($target.IsLocal) { $ProjectRoot } else { Get-RemoteWorkDir -ProjectRoot $ProjectRoot }

$targetLabel = if ($target.IsLocal) { 'localhost' } else { "ssh $($target.SshAlias)" }
$volumeAction = if ($removeVolumes) { 'removing volumes' } else { 'keeping volumes' }

$imageTag = Get-StackImageTag -ProjectRoot $ProjectRoot
Write-Host "Running Docker stack on $targetLabel ($volumeAction, image: $imageTag)..."

if (-not $target.IsLocal) {
    Transfer-DockerImageToRemote -Target $target -ProjectRoot $ProjectRoot -ImageTag $imageTag
    Sync-ProjectToRemote -Target $target -LocalRoot $ProjectRoot -RemotePath $workDir
}

$downFlag = if ($removeVolumes) { ' -v' } else { '' }
try {
    Invoke-RemoteShell -Target $target -Command "docker compose down$downFlag" -WorkingDirectory $workDir
}
catch {
    Write-Host "Compose down skipped: $($_.Exception.Message)"
}

$composeUpCommand = if ($target.IsLocal) { 'docker compose up -d --build' } else { 'docker compose up -d' }
Invoke-RemoteShell -Target $target -Command $composeUpCommand -WorkingDirectory $workDir

if ($target.IsLocal) {
    Write-Host 'Stack is running on http://localhost:8080'
}
else {
    Write-Host "Stack is running on remote host at $workDir"
    Write-Host ("Image was built locally and deployed to {0} without a remote build." -f $target.SshAlias) -ForegroundColor Green
}
