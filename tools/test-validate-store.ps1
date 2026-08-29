$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $PSScriptRoot 'validate-store.ps1'
$envelopeTool = Join-Path $PSScriptRoot 'registry-envelope.mjs'
$powerShell = (Get-Process -Id $PID).Path
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

function New-SigningFixture([string]$Name) {
    $privatePath = Join-Path $temporary "$Name-private.txt"
    $publicPath = Join-Path $temporary "$Name-public.json"
    $rootPath = Join-Path $temporary "$Name-root.json"
    & node $envelopeTool generate-key --private-output $privatePath --public-output $publicPath
    if ($LASTEXITCODE -ne 0) { throw "Failed to generate $Name test signing key" }

    $public = Get-Content -LiteralPath $publicPath -Raw | ConvertFrom-Json
    $keys = [ordered]@{}
    $keys[[string]$public.keyId] = [ordered]@{
        keyType = 'ed25519'
        scheme = 'ed25519'
        publicKey = [string]$public.publicKey
    }
    $roles = [ordered]@{}
    $roles['official-repository'] = [ordered]@{
        keyIds = @([string]$public.keyId)
        threshold = 1
    }
    Write-JsonFile $rootPath ([ordered]@{
        signed = [ordered]@{
            _type = 'root'
            schemaVersion = 1
            expires = '2036-08-29T00:00:00Z'
            statusUrl = ''
            keys = $keys
            roles = $roles
        }
        signatures = @()
    })
    return [pscustomobject]@{
        PrivatePath = $privatePath
        RootPath = $rootPath
    }
}

function Sign-Registry([string]$Registry, [string]$PrivateKey, [string]$Output) {
    $previousKey = $env:AURA_OFFICIAL_REGISTRY_SIGNING_KEY_PKCS8_BASE64
    $previousFile = $env:AURA_OFFICIAL_REGISTRY_SIGNING_KEY_FILE
    try {
        $env:AURA_OFFICIAL_REGISTRY_SIGNING_KEY_PKCS8_BASE64 = $null
        $env:AURA_OFFICIAL_REGISTRY_SIGNING_KEY_FILE = $PrivateKey
        & node $envelopeTool sign --registry $Registry --output $Output
        if ($LASTEXITCODE -ne 0) { throw 'Failed to sign test registry' }
    } finally {
        $env:AURA_OFFICIAL_REGISTRY_SIGNING_KEY_PKCS8_BASE64 = $previousKey
        $env:AURA_OFFICIAL_REGISTRY_SIGNING_KEY_FILE = $previousFile
    }
}

function Invoke-Validator(
    [string]$Registry,
    [string]$Manifest,
    [string]$TrustRoot = '',
    [switch]$UnsignedPayload
) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $arguments = @('-NoProfile', '-File', $validator, '-Registry', $Registry, '-Manifests', $Manifest)
        if (-not [string]::IsNullOrWhiteSpace($TrustRoot)) {
            $arguments += @('-TrustRoot', $TrustRoot)
        }
        if ($UnsignedPayload) { $arguments += '-UnsignedPayload' }
        $output = & $powerShell @arguments 2>&1 | Out-String
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
    $registryPath = Join-Path $temporary 'registry.json'
    $envelopePath = Join-Path $temporary 'plugins.json'

    Write-JsonFile $manifestPath (New-Manifest)
    Write-Registry $registryPath $manifestPath
    $signer = New-SigningFixture 'official'
    $wrongSigner = New-SigningFixture 'wrong'
    Sign-Registry $registryPath $signer.PrivatePath $envelopePath

    Assert-Fails (Invoke-Validator $registryPath $manifestPath $signer.RootPath) `
        'Registry envelope' 'plain official registry'
    Assert-Succeeds (Invoke-Validator $envelopePath $manifestPath $signer.RootPath) `
        'signed official registry'
    Assert-Succeeds (Invoke-Validator $registryPath $manifestPath -UnsignedPayload) `
        'reviewed unsigned payload'
    Assert-Fails (Invoke-Validator $envelopePath $manifestPath $wrongSigner.RootPath) `
        'not authorized' 'wrong trust root'

    $changedEnvelope = Get-Content -LiteralPath $envelopePath -Raw | ConvertFrom-Json
    $changedEnvelope.signed.name = 'Mutated Store'
    Write-JsonFile $envelopePath $changedEnvelope
    Assert-Fails (Invoke-Validator $envelopePath $manifestPath $signer.RootPath) `
        'signature is invalid' 'changed signed payload'

    Sign-Registry $registryPath $signer.PrivatePath $envelopePath
    $changedEnvelope = Get-Content -LiteralPath $envelopePath -Raw | ConvertFrom-Json
    $signature = [string]$changedEnvelope.signatures[0].signature
    $replacement = if ($signature[0] -ceq 'A') { 'B' } else { 'A' }
    $changedEnvelope.signatures[0].signature = $replacement + $signature.Substring(1)
    Write-JsonFile $envelopePath $changedEnvelope
    Assert-Fails (Invoke-Validator $envelopePath $manifestPath $signer.RootPath) `
        'signature is invalid' 'changed registry signature'

    Write-Registry $registryPath $manifestPath
    Assert-Succeeds (Invoke-Validator $registryPath $manifestPath -UnsignedPayload) `
        'valid runtime Provider'

    $withHarmony = New-Manifest
    $withHarmony.versions[0].platforms += 'harmonyos-arm64'
    $withHarmony.versions[0].artifacts += New-Artifact 'harmonyos-arm64'
    Write-JsonFile $manifestPath $withHarmony
    Write-Registry $registryPath $manifestPath
    Assert-Succeeds (Invoke-Validator $registryPath $manifestPath -UnsignedPayload) `
        'runtime Provider with optional HarmonyOS artifact'

    $missingRequired = New-Manifest
    $missingRequired.versions[0].platforms = @($missingRequired.versions[0].platforms |
        Where-Object { $_ -cne 'linux-arm64' })
    $missingRequired.versions[0].artifacts = @($missingRequired.versions[0].artifacts |
        Where-Object { $_.platform -cne 'linux-arm64' })
    Write-JsonFile $manifestPath $missingRequired
    Write-Registry $registryPath $manifestPath
    Assert-Fails (Invoke-Validator $registryPath $manifestPath -UnsignedPayload) `
        'missing required Aura platform: linux-arm64' 'missing required Linux ARM64 artifact'

    $unknownHarmony = New-Manifest
    $unknownHarmony.versions[0].artifacts += New-Artifact 'harmonyos-x64'
    Write-JsonFile $manifestPath $unknownHarmony
    Write-Registry $registryPath $manifestPath
    Assert-Fails (Invoke-Validator $registryPath $manifestPath -UnsignedPayload) `
        'unsupported artifact platform: harmonyos-x64' 'unknown HarmonyOS architecture'

    Write-JsonFile $manifestPath (New-Manifest)
    Write-Registry $registryPath $manifestPath $false
    Assert-Fails (Invoke-Validator $registryPath $manifestPath -UnsignedPayload) `
        'manifestSha256' 'missing manifest digest'

    Write-Registry $registryPath $manifestPath
    Add-Content -LiteralPath $manifestPath -Value ' '
    Assert-Fails (Invoke-Validator $registryPath $manifestPath -UnsignedPayload) `
        'SHA-256 mismatch' 'changed manifest bytes'

    $mixed = New-Manifest
    $mixed.versions[0] | Add-Member -NotePropertyName packageUrl `
        -NotePropertyValue 'https://example.test/legacy.npl'
    Write-JsonFile $manifestPath $mixed
    Write-Registry $registryPath $manifestPath
    Assert-Fails (Invoke-Validator $registryPath $manifestPath -UnsignedPayload) `
        'cannot combine' 'mixed artifact representations'

    $duplicate = New-Manifest
    $duplicate.versions[0].artifacts[1].platform = 'windows-x64'
    Write-JsonFile $manifestPath $duplicate
    Write-Registry $registryPath $manifestPath
    Assert-Fails (Invoke-Validator $registryPath $manifestPath -UnsignedPayload) `
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

$global:LASTEXITCODE = 0
