param(
    [string]$Registry = (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins.json'),
    [string[]]$Manifests = @(),
    [switch]$VerifyRemote,
    [string]$NplValidator = ''
)

$ErrorActionPreference = 'Stop'
$idPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$'
$shaPattern = '^[0-9a-f]{64}$'
$versionPattern = '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'
$supportedPlatforms = @(
    'windows-x64', 'windows-arm64', 'linux-x64',
    'linux-arm64', 'macos-x64', 'macos-arm64'
)

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Has-Property([object]$Value, [string]$Name) {
    return $null -ne $Value.PSObject.Properties[$Name]
}

function Assert-HttpsUrl([string]$Url, [string]$Field) {
    try { $uri = [System.Uri]$Url } catch { throw "$Field is not a valid URL: $Url" }
    Assert-Condition ($uri.IsAbsoluteUri) "$Field must be absolute: $Url"
    $allowed = $uri.Scheme -ceq 'https' -or ($uri.Scheme -ceq 'http' -and $uri.IsLoopback)
    Assert-Condition $allowed "$Field must use HTTPS (loopback HTTP is allowed): $Url"
}

function Assert-StringArray([object]$Value, [string]$Field, [bool]$AllowEmpty = $true) {
    $values = @($Value)
    if (-not $AllowEmpty) { Assert-Condition ($values.Count -gt 0) "$Field must not be empty" }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $values) {
        Assert-Condition ($item -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$item)) `
            "$Field contains a blank or non-string value"
        Assert-Condition ($seen.Add([string]$item)) "$Field contains duplicate value: $item"
    }
}

function Get-LowerSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Artifact([object]$Artifact, [string]$ManifestId, [string]$Version) {
    Assert-Condition (Has-Property $Artifact 'platform') "$ManifestId $Version artifact has no platform"
    $platform = [string]$Artifact.platform
    Assert-Condition ($platform -cin $supportedPlatforms) `
        "$ManifestId $Version has unsupported artifact platform: $platform"
    Assert-HttpsUrl ([string]$Artifact.packageUrl) "packageUrl for $ManifestId $Version $platform"
    Assert-Condition ([string]$Artifact.sha256 -cmatch $shaPattern) `
        "$ManifestId $Version $platform has invalid SHA-256"
    Assert-Condition ([int64]$Artifact.size -gt 0) "$ManifestId $Version $platform has invalid size"
}

function Assert-RuntimeProviderVersion([object]$Version, [string]$ManifestId) {
    $versionName = [string]$Version.version
    foreach ($field in @('runtime', 'abi', 'platforms', 'pluginKind', 'executionMode',
            'providesRuntimes', 'permissions', 'requiredPermissions', 'dependencies', 'artifacts')) {
        Assert-Condition (Has-Property $Version $field) "$ManifestId $versionName must declare $field"
    }
    Assert-Condition ([string]$Version.runtime -ceq 'java') `
        "$ManifestId $versionName runtime Provider must use java bootstrap runtime"
    Assert-Condition ([int]$Version.abi -eq 2) `
        "$ManifestId $versionName runtime Provider must use Java ABI 2"
    Assert-Condition ([string]$Version.pluginKind -ceq 'runtime-provider') `
        "$ManifestId $versionName has invalid pluginKind"
    Assert-Condition ([string]$Version.executionMode -ceq 'embedded') `
        "$ManifestId $versionName runtime Provider must use embedded bootstrap execution"

    Assert-StringArray $Version.platforms "$ManifestId $versionName platforms" $false
    Assert-Condition ((Compare-Object ($supportedPlatforms | Sort-Object) `
            (@($Version.platforms) | Sort-Object)).Count -eq 0) `
        "$ManifestId $versionName must declare the exact six Aura platforms"
    Assert-StringArray $Version.permissions "$ManifestId $versionName permissions"
    Assert-StringArray $Version.requiredPermissions "$ManifestId $versionName requiredPermissions"
    foreach ($required in @($Version.requiredPermissions)) {
        Assert-Condition ($required -cin @($Version.permissions)) `
            "$ManifestId $versionName requires undeclared permission: $required"
    }
    Assert-Condition ($Version.dependencies -is [array]) `
        "$ManifestId $versionName dependencies must be an array"

    $declarations = @($Version.providesRuntimes)
    Assert-Condition ($declarations.Count -gt 0) "$ManifestId $versionName must provide at least one runtime"
    $runtimeIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($declaration in $declarations) {
        Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$declaration.runtime)) `
            "$ManifestId $versionName has a blank provided runtime"
        Assert-Condition ([string]$declaration.runtime -cne 'java') `
            "$ManifestId $versionName cannot replace the built-in java runtime"
        Assert-Condition ($runtimeIds.Add([string]$declaration.runtime)) `
            "$ManifestId $versionName has duplicate provided runtime: $($declaration.runtime)"
        Assert-Condition (@($declaration.abis).Count -gt 0) `
            "$ManifestId $versionName provided runtime has no ABI"
        Assert-Condition ([int]$declaration.bridgeAbi -eq 1) `
            "$ManifestId $versionName provided runtime must use Bridge ABI 1"
        Assert-StringArray $declaration.executionModes `
            "$ManifestId $versionName provided executionModes" $false
        Assert-StringArray $declaration.features "$ManifestId $versionName provided features" $false
    }

    Assert-Condition (-not (Has-Property $Version 'packageUrl') `
            -and -not (Has-Property $Version 'sha256') `
            -and -not (Has-Property $Version 'size')) `
        "$ManifestId $versionName cannot combine artifacts with packageUrl, sha256, or size"
    $artifacts = @($Version.artifacts)
    Assert-Condition ($artifacts.Count -eq 6) "$ManifestId $versionName must publish exactly six artifacts"
    $artifactPlatforms = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($artifact in $artifacts) {
        Assert-Artifact $artifact $ManifestId $versionName
        Assert-Condition ($artifactPlatforms.Add([string]$artifact.platform)) `
            "Duplicate artifact platform for $ManifestId ${versionName}: $($artifact.platform)"
    }
    Assert-Condition ((Compare-Object ($supportedPlatforms | Sort-Object) `
            (@($artifactPlatforms) | Sort-Object)).Count -eq 0) `
        "$ManifestId $versionName artifact matrix must contain the exact six Aura platforms"
}

function Assert-Manifest([object]$Manifest, [string]$ManifestPath) {
    Assert-Condition ([int]$Manifest.schemaVersion -eq 2) "$ManifestPath schemaVersion must be 2"
    Assert-Condition ([string]$Manifest.id -cmatch $idPattern) "$ManifestPath has invalid id"
    Assert-Condition (@($Manifest.versions).Count -gt 0) "$ManifestPath must publish at least one version"
    $versions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($version in @($Manifest.versions)) {
        $versionName = [string]$version.version
        Assert-Condition ($versionName -cmatch $versionPattern) "$ManifestPath has invalid version: $versionName"
        Assert-Condition ($versions.Add($versionName)) "$ManifestPath has duplicate version $versionName"
        Assert-Condition ([int]$version.pluginApiVersion -ge 1 -and [int]$version.pluginApiVersion -le 5) `
            "$ManifestPath has unsupported pluginApiVersion"
        Assert-Condition ([string]$version.channel -cin @('stable', 'beta', 'nightly')) `
            "$ManifestPath has invalid channel for $versionName"
        Assert-Condition ([string]$version.launcherVersion -cmatch '\S') `
            "$ManifestPath has no launcherVersion for $versionName"
        if ([int]$version.pluginApiVersion -eq 5 -and [string]$version.pluginKind -ceq 'runtime-provider') {
            Assert-RuntimeProviderVersion $version ([string]$Manifest.id)
        } elseif (Has-Property $version 'artifacts') {
            throw "$ManifestPath non-Provider version $versionName cannot declare artifacts"
        } else {
            Assert-HttpsUrl ([string]$version.packageUrl) "packageUrl for $($Manifest.id) $versionName"
            Assert-Condition ([string]$version.sha256 -cmatch $shaPattern) `
                "$ManifestPath has invalid SHA-256 for $versionName"
            Assert-Condition ([int64]$version.size -gt 0) "$ManifestPath has invalid size for $versionName"
        }
    }
}

function Assert-ManifestPin([object]$Entry, [string]$ManifestPath) {
    $actual = Get-LowerSha256 $ManifestPath
    Assert-Condition ($actual -ceq [string]$Entry.manifestSha256) `
        "Manifest SHA-256 mismatch for $($Entry.id): expected $($Entry.manifestSha256), got $actual"
}

function Save-RemoteFile([string]$Url, [string]$Path, [string]$Purpose) {
    Assert-HttpsUrl $Url $Purpose
    Invoke-WebRequest -Uri $Url -OutFile $Path -MaximumRedirection 10 -UseBasicParsing
    Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) "$Purpose was not downloaded"
}

function Assert-RemotePackages([object]$Manifest, [string]$ManifestPath, [string]$DownloadRoot) {
    foreach ($version in @($Manifest.versions)) {
        $downloads = if (Has-Property $version 'artifacts') { @($version.artifacts) } else {
            @([pscustomobject]@{
                platform = 'universal'; packageUrl = $version.packageUrl
                sha256 = $version.sha256; size = $version.size
            })
        }
        foreach ($download in $downloads) {
            $fileName = "{0}-{1}.npl" -f $version.version, $download.platform
            $packagePath = Join-Path $DownloadRoot $fileName
            Save-RemoteFile ([string]$download.packageUrl) $packagePath `
                "package for $($Manifest.id) $($version.version) $($download.platform)"
            $file = Get-Item -LiteralPath $packagePath
            $hash = Get-LowerSha256 $packagePath
            Assert-Condition ($hash -ceq [string]$download.sha256) `
                "Package SHA-256 mismatch for $($Manifest.id) $($version.version) $($download.platform)"
            Assert-Condition ($file.Length -eq [int64]$download.size) `
                "Package size mismatch for $($Manifest.id) $($version.version) $($download.platform)"
            & powershell.exe -NoProfile -File $script:NplValidator `
                -Package $packagePath -StoreManifest $ManifestPath
            Assert-Condition ($LASTEXITCODE -eq 0) `
                "NPL validation failed for $($Manifest.id) $($version.version) $($download.platform)"
        }
    }
}

$registryPath = (Resolve-Path -LiteralPath $Registry).Path
$registryJson = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
Assert-Condition ([int]$registryJson.schemaVersion -eq 1) 'plugins.json schemaVersion must be 1'
Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$registryJson.name)) `
    'plugins.json name is required'
Assert-Condition (Has-Property $registryJson 'plugins') 'plugins.json plugins array is required'
$entriesById = @{}
$ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($plugin in @($registryJson.plugins)) {
    Assert-Condition ([string]$plugin.id -cmatch $idPattern) "Invalid plugin id: $($plugin.id)"
    Assert-Condition ($ids.Add([string]$plugin.id)) "Duplicate plugin id: $($plugin.id)"
    Assert-HttpsUrl ([string]$plugin.manifestUrl) "manifestUrl for $($plugin.id)"
    Assert-Condition (Has-Property $plugin 'manifestSha256' `
            -and [string]$plugin.manifestSha256 -cmatch $shaPattern) `
        "manifestSha256 for $($plugin.id) must be a lowercase SHA-256"
    Assert-StringArray $plugin.tags "tags for $($plugin.id)"
    Assert-StringArray $plugin.capabilities "capabilities for $($plugin.id)"
    $entriesById[[string]$plugin.id] = $plugin
}

foreach ($manifestSource in $Manifests) {
    $manifestPath = (Resolve-Path -LiteralPath $manifestSource).Path
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Condition ($entriesById.ContainsKey([string]$manifest.id)) `
        "$manifestPath is not indexed by plugins.json"
    $entry = $entriesById[[string]$manifest.id]
    Assert-ManifestPin $entry $manifestPath
    Assert-Manifest $manifest $manifestPath
}

if ($VerifyRemote) {
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($NplValidator)) `
        'Remote validation requires -NplValidator'
    $script:NplValidator = (Resolve-Path -LiteralPath $NplValidator).Path
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) `
        ('aura-store-remote-validation-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $temporary)
    try {
        foreach ($plugin in @($registryJson.plugins)) {
            $pluginRoot = Join-Path $temporary ([string]$plugin.id)
            [void](New-Item -ItemType Directory -Path $pluginRoot)
            $manifestPath = Join-Path $pluginRoot 'manifest.json'
            Save-RemoteFile ([string]$plugin.manifestUrl) $manifestPath "manifest for $($plugin.id)"
            Assert-ManifestPin $plugin $manifestPath
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            Assert-Condition ([string]$manifest.id -ceq [string]$plugin.id) `
                "Remote manifest id does not match registry entry $($plugin.id)"
            Assert-Manifest $manifest $manifestPath
            Assert-RemotePackages $manifest $manifestPath $pluginRoot
        }
    } finally {
        $resolvedTemporary = [System.IO.Path]::GetFullPath($temporary)
        $resolvedSystemTemporary = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        Assert-Condition ($resolvedTemporary.StartsWith(
                $resolvedSystemTemporary,
                [System.StringComparison]::OrdinalIgnoreCase
            )) "Refusing to remove non-temporary path: $resolvedTemporary"
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
    }
}

Write-Host "Validated Aura registry with $($ids.Count) plugin(s) and $($Manifests.Count) local manifest(s)."
