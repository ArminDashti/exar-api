#Requires -Version 5.1
<#
.SYNOPSIS
  Deploy stack to the local Docker daemon using sibling YAML only.

.DESCRIPTION
  Local deploy script for .armin/docker-scripts/run-on-docker-local.yaml.
  Reads run-on-docker-local.yaml — no CLI -- flags.
  Builds the image locally and runs docker compose up -d.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DeployDir = $PSScriptRoot
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $DeployDir '../..'))
$ConfigPath = Join-Path $DeployDir 'run-on-docker-local.yaml'

function Write-Step([string]$Message) {
    Write-Host ">> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-Fail([string]$Message) {
    Write-Host "ERR $Message" -ForegroundColor Red
}

function Show-Help {
    Write-Host @"
run-on-docker-local.ps1 — local Docker deploy (YAML-only)

USAGE:
  .\.armin\docker-scripts\run-on-docker-local.ps1

CONFIG:
  Sibling file: run-on-docker-local.yaml

  stack_name          Compose project name (-p)
  image_tag           Image tag for build and compose; overrides compose when set
  compose_file        Compose path relative to .armin/docker-scripts
  dockerfile          Dockerfile path relative to .armin/docker-scripts
  docker_network      External Docker network name
  publish_port        Host bind port; overrides compose when set
  internal_port       Container listen port; overrides compose when set
  delete_volume       yes/true/1/y/on → remove volumes before up
  delete_image        yes/true/1/y/on → remove image during teardown

NOTES:
  - No CLI -- flags. Change behavior only via YAML.
  - Sets IMAGE_TAG / DOCKER_NETWORK / INTERNAL_PORT / PUBLISH_PORT for compose when non-empty.
"@ -ForegroundColor Cyan
}

function Test-Truthy([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.Trim().ToLowerInvariant() -in @('yes', 'true', '1', 'y', 'on')
}

function Test-Placeholder([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    return $Value -match '<[^>]+>'
}

function Read-FlatYaml([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing config: $Path"
    }
    $map = @{}
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -match '^\s*-') { continue }
        if ($line -notmatch '^(?<key>[^:#]+):\s*(?<val>.*)$') { continue }
        $key = $Matches['key'].Trim()
        $val = $Matches['val'].Trim()
        if ($val -match '^(?<q>["'']).*?\k<q>(?<rest>\s+#.*)?$') {
            if ($Matches['rest']) {
                $val = $val.Substring(0, $val.Length - $Matches['rest'].Length).Trim()
            }
        }
        elseif ($val -match '^(?<body>.*?)\s+#') {
            $val = $Matches['body'].Trim()
        }
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $map[$key] = $val
    }
    return $map
}

function Require-Key($Map, [string]$Key) {
    if (-not $Map.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace([string]$Map[$Key])) {
        throw "YAML missing required key: $Key"
    }
    return [string]$Map[$Key]
}

function Resolve-DeployPath([string]$RelativePath) {
    $candidate = Join-Path $DeployDir $RelativePath
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "Path not found: $fullPath"
    }
    return $fullPath
}

function Ensure-Docker {
    docker version *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Docker CLI is not available. Start Docker Desktop / daemon.' }
}

function Ensure-Network([string]$NetworkName) {
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & docker network inspect $NetworkName *> $null
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Step "Creating network $NetworkName"
        & docker network create $NetworkName *> $null
        if ($LASTEXITCODE -ne 0) { throw "Failed to create network $NetworkName" }
    }
}

if ($args.Count -gt 0) {
    Write-Fail 'This script accepts no CLI arguments. Edit run-on-docker-local.yaml instead.'
    Show-Help
    exit 1
}

try {
    $cfg = Read-FlatYaml $ConfigPath
    $stackName = Require-Key $cfg 'stack_name'
    $imageTag = Require-Key $cfg 'image_tag'
    $composeFileRel = Require-Key $cfg 'compose_file'
    $dockerfileRel = Require-Key $cfg 'dockerfile'
    $network = Require-Key $cfg 'docker_network'
    $publishPort = if ($cfg.ContainsKey('publish_port')) { [string]$cfg['publish_port'] } else { '' }
    $internalPort = if ($cfg.ContainsKey('internal_port')) { [string]$cfg['internal_port'] } else { '' }
    $deleteVolume = Test-Truthy ($(if ($cfg.ContainsKey('delete_volume')) { [string]$cfg['delete_volume'] } else { 'no' }))
    $deleteImage = Test-Truthy ($(if ($cfg.ContainsKey('delete_image')) { [string]$cfg['delete_image'] } else { 'no' }))

    if (Test-Placeholder $composeFileRel) { throw 'compose_file is still a placeholder.' }
    if (Test-Placeholder $dockerfileRel) { throw 'dockerfile is still a placeholder.' }
    if (Test-Placeholder $stackName) { throw 'stack_name is still a placeholder.' }
    if (Test-Placeholder $imageTag) { throw 'image_tag is still a placeholder.' }

    $composePath = Resolve-DeployPath $composeFileRel
    $dockerfile = Resolve-DeployPath $dockerfileRel

    Write-Step "Stack=$stackName image=$imageTag network=$network publish_port='$publishPort' internal_port='$internalPort' delete_volume=$deleteVolume delete_image=$deleteImage"

    Ensure-Docker
    Ensure-Network $network

    $downFileArgs = @('-f', $composePath)
    $publishCompose = Join-Path $RepoRoot 'docker-compose.publish.yml'
    if ((-not [string]::IsNullOrWhiteSpace($publishPort)) -and (Test-Path -LiteralPath $publishCompose)) {
        $downFileArgs += @('-f', $publishCompose)
    }

    if ($deleteVolume -or $deleteImage) {
        Write-Step 'Stopping existing stack'
        $oldPublishPortDown = $env:PUBLISH_PORT
        if (-not [string]::IsNullOrWhiteSpace($publishPort)) { $env:PUBLISH_PORT = $publishPort }
        try {
            if ($deleteVolume) {
                docker compose -p $stackName @downFileArgs --project-directory $RepoRoot down -v
            }
            else {
                docker compose -p $stackName @downFileArgs --project-directory $RepoRoot down
            }
        }
        finally {
            if ($null -ne $oldPublishPortDown) { $env:PUBLISH_PORT = $oldPublishPortDown } else { Remove-Item Env:PUBLISH_PORT -ErrorAction SilentlyContinue }
        }
    }

    if ($deleteImage) {
        Write-Step "Removing local image $imageTag"
        $oldEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'SilentlyContinue'
            docker image rm -f $imageTag *> $null
        }
        finally {
            $ErrorActionPreference = $oldEap
        }
    }

    Write-Step "Building image $imageTag"
    docker build -f $dockerfile -t $imageTag $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw 'docker build failed' }

    Write-Step 'Starting stack'
    $composeFileArgs = @('-f', $composePath)
    if (-not [string]::IsNullOrWhiteSpace($publishPort)) {
        $publishCompose = Join-Path $RepoRoot 'docker-compose.publish.yml'
        if (-not (Test-Path -LiteralPath $publishCompose)) {
            throw "publish_port is set but overlay missing: $publishCompose"
        }
        $composeFileArgs += @('-f', $publishCompose)
    }

    $oldImageTag = $env:IMAGE_TAG
    $oldDockerNetwork = $env:DOCKER_NETWORK
    $oldInternalPort = $env:INTERNAL_PORT
    $oldPublishPort = $env:PUBLISH_PORT
    $env:IMAGE_TAG = $imageTag
    $env:DOCKER_NETWORK = $network
    if (-not [string]::IsNullOrWhiteSpace($internalPort)) { $env:INTERNAL_PORT = $internalPort }
    if (-not [string]::IsNullOrWhiteSpace($publishPort)) { $env:PUBLISH_PORT = $publishPort }
    try {
        docker compose -p $stackName @composeFileArgs --project-directory $RepoRoot up -d
        if ($LASTEXITCODE -ne 0) { throw 'docker compose up failed' }
    }
    finally {
        if ($null -ne $oldImageTag) { $env:IMAGE_TAG = $oldImageTag } else { Remove-Item Env:IMAGE_TAG -ErrorAction SilentlyContinue }
        if ($null -ne $oldDockerNetwork) { $env:DOCKER_NETWORK = $oldDockerNetwork } else { Remove-Item Env:DOCKER_NETWORK -ErrorAction SilentlyContinue }
        if ($null -ne $oldInternalPort) { $env:INTERNAL_PORT = $oldInternalPort } else { Remove-Item Env:INTERNAL_PORT -ErrorAction SilentlyContinue }
        if ($null -ne $oldPublishPort) { $env:PUBLISH_PORT = $oldPublishPort } else { Remove-Item Env:PUBLISH_PORT -ErrorAction SilentlyContinue }
    }

    Write-Ok 'Deploy complete'
    if ([string]::IsNullOrWhiteSpace($publishPort)) {
        Write-Host "API on Docker network $network (container listen :$($internalPort -replace '^$','8080'))." -ForegroundColor Green
    }
    else {
        Write-Host "API published at http://localhost:$publishPort" -ForegroundColor Green
    }
}
catch {
    Write-Fail $_.Exception.Message
    Show-Help
    exit 1
}
