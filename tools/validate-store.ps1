param(
    [string]$Registry = (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins.json'),
    [string[]]$Manifests = @((Join-Path (Split-Path -Parent $PSScriptRoot) 'examples\manifest.json'))
)

$ErrorActionPreference = 'Stop'
$idPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$'
$shaPattern = '^[0-9a-fA-F]{64}$'

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-HttpsUrl([string]$Url, [string]$Field) {
    $uri = [System.Uri]$Url
    $loopback = $uri.IsLoopback
    Assert-Condition ($uri.Scheme -eq 'https' -or ($uri.Scheme -eq 'http' -and $loopback)) "$Field must use HTTPS (loopback HTTP is allowed): $Url"
}

$registryJson = Get-Content -LiteralPath $Registry -Raw | ConvertFrom-Json
Assert-Condition ($registryJson.schemaVersion -eq 1) 'plugins.json schemaVersion must be 1'
Assert-Condition (-not [string]::IsNullOrWhiteSpace($registryJson.name)) 'plugins.json name is required'

$ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($plugin in $registryJson.plugins) {
    Assert-Condition ($plugin.id -match $idPattern) "Invalid plugin id: $($plugin.id)"
    Assert-Condition ($ids.Add([string]$plugin.id)) "Duplicate plugin id: $($plugin.id)"
    Assert-HttpsUrl ([string]$plugin.manifestUrl) "manifestUrl for $($plugin.id)"
    foreach ($capability in @($plugin.capabilities)) {
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($capability)) "Blank capability for $($plugin.id)"
    }
}

foreach ($manifestPath in $Manifests) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Condition ($manifest.schemaVersion -eq 1) "$manifestPath schemaVersion must be 1"
    Assert-Condition ($manifest.id -match $idPattern) "$manifestPath has invalid id"
    Assert-Condition (@($manifest.versions).Count -gt 0) "$manifestPath must publish at least one version"

    $versions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($version in $manifest.versions) {
        Assert-Condition ($versions.Add([string]$version.version)) "$manifestPath has duplicate version $($version.version)"
        Assert-HttpsUrl ([string]$version.packageUrl) "packageUrl for $($manifest.id) $($version.version)"
        Assert-Condition ($version.sha256 -match $shaPattern) "$manifestPath has invalid SHA-256 for $($version.version)"
        Assert-Condition ([int64]$version.size -gt 0) "$manifestPath has invalid size for $($version.version)"
        Assert-Condition ([int]$version.pluginApiVersion -ge 1 -and [int]$version.pluginApiVersion -le 2) "$manifestPath has unsupported pluginApiVersion"
    }
}

Write-Host "Validated registry and $($Manifests.Count) manifest file(s)."
