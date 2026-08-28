$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $PSScriptRoot 'validate-store.ps1'
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('aura-store-validator-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temporary)

function Write-JsonFile([string]$Path, [object]$Value) {
    $json = $Value | ConvertTo-Json -Depth 16
    [System.IO.File]::WriteAllText($Path, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}

function New-Artifact([string]$Platform) {
    return [pscustomobject][ordered]@{
        platform = $Platform
        packageUrl = "https://example.test/runtime-host-$Platform.npl"
        sha256 = '0' * 64
        size = 1
    }
}

function New-Manifest {
    return [pscustomobject][ordered]@{
        schemaVersion = 2
        id = 'dev.hmclce.runtime.test-host'
        repository = 'github.com/Egg-China/Aura-Test-Runtime-Host'
        license = 'GPL-3.0-or-later'
        website = 'https://github.com/Egg-China/Aura-Test-Runtime-Host'
        source = 'https://github.com/Egg-China/Aura-Test-Runtime-Host'
        versions = @(
            [pscustomobject][ordered]@{
                version = '0.1.0-beta.1'
                launcherVersion = '>=27.1-0-next'
                requiredJavaVersion = '17'
                pluginApiVersion = 5
                runtime = 'java'
                abi = 2
                platforms = @(
                    'windows-x64', 'windows-arm64', 'linux-x64',
                    'linux-arm64', 'macos-x64', 'macos-arm64'
                )
                pluginKind = 'runtime-provider'
                executionMode = 'embedded'
                providesRuntimes = @(
                    [pscustomobject][ordered]@{
                        runtime = 'test-runtime'
                        abis = @(1)
                        bridgeAbi = 1
                        executionModes = @('isolated')
                        features = @('bridge', 'hooks', 'native')
                    }
                )
                permissions = @('native-code')
                requiredPermissions = @('native-code')
                dependencies = @()
                requiresRestart = $false
                channel = 'beta'
                artifacts = @(
                    (New-Artifact 'windows-x64'),
                    (New-Artifact 'windows-arm64'),
                    (New-Artifact 'linux-x64'),
                    (New-Artifact 'linux-arm64'),
                    (New-Artifact 'macos-x64'),
                    (New-Artifact 'macos-arm64')
                )
                releaseDate = '2026-08-28'
            }
        )
    }
}

function Write-Registry([string]$Path, [string]$ManifestPath, [bool]$IncludeHash = $true) {
    $entry = [ordered]@{
        id = 'dev.hmclce.runtime.test-host'
        name = 'Aura Test Runtime Host'
        author = 'Egg-China'
        description = 'Validator fixture'
        manifestUrl = 'https://example.test/manifest.json'
        repository = 'https://github.com/Egg-China/Aura-Test-Runtime-Host'
        homepage = 'https://github.com/Egg-China/Aura-Test-Runtime-Host'
        category = 'runtime'
        tags = @('runtime', 'test-runtime')
        capabilities = @('runtime-provider', 'bridge', 'hooks', 'native')
    }
    if ($IncludeHash) {
        $entry.manifestSha256 = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Write-JsonFile $Path ([pscustomobject][ordered]@{
        schemaVersion = 1
        name = 'Aura Launcher Plugin Store'
        plugins = @([pscustomobject]$entry)
    })
}

function Invoke-Validator([string]$Registry, [string]$Manifest) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe -NoProfile -File $validator `
            -Registry $Registry -Manifests $Manifest 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Assert-Succeeds([object]$Result, [string]$Case) {
    if ($Result.ExitCode -ne 0) {
        throw "$Case should succeed, but failed: $($Result.Output)"
    }
}

function Assert-Fails([object]$Result, [string]$Expected, [string]$Case) {
    if ($Result.ExitCode -eq 0) {
        throw "$Case should fail"
    }
    if (-not $Result.Output.Contains($Expected)) {
        throw "$Case failed without expected diagnostic '$Expected': $($Result.Output)"
    }
}

try {
    $manifestPath = Join-Path $temporary 'manifest.json'
    $registryPath = Join-Path $temporary 'plugins.json'

    Write-JsonFile $manifestPath (New-Manifest)
    Write-Registry $registryPath $manifestPath
    Assert-Succeeds (Invoke-Validator $registryPath $manifestPath) 'valid runtime Provider'

    Write-Registry $registryPath $manifestPath $false
    Assert-Fails (Invoke-Validator $registryPath $manifestPath) `
        'manifestSha256' 'missing manifest digest'

    Write-Registry $registryPath $manifestPath
    Add-Content -LiteralPath $manifestPath -Value ' '
    Assert-Fails (Invoke-Validator $registryPath $manifestPath) `
        'SHA-256 mismatch' 'changed manifest bytes'

    $mixed = New-Manifest
    $mixed.versions[0] | Add-Member -NotePropertyName packageUrl `
        -NotePropertyValue 'https://example.test/legacy.npl'
    Write-JsonFile $manifestPath $mixed
    Write-Registry $registryPath $manifestPath
    Assert-Fails (Invoke-Validator $registryPath $manifestPath) `
        'cannot combine' 'mixed artifact representations'

    $duplicate = New-Manifest
    $duplicate.versions[0].artifacts[1].platform = 'windows-x64'
    Write-JsonFile $manifestPath $duplicate
    Write-Registry $registryPath $manifestPath
    Assert-Fails (Invoke-Validator $registryPath $manifestPath) `
        'Duplicate artifact platform' 'duplicate artifact platform'

    Write-Host 'Aura Store validator tests passed.'
} finally {
    $resolvedTemporary = [System.IO.Path]::GetFullPath($temporary)
    $resolvedSystemTemporary = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $resolvedTemporary.StartsWith($resolvedSystemTemporary, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove non-temporary path: $resolvedTemporary"
    }
    Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
}
