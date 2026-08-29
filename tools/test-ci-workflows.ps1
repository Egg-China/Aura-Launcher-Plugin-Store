$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$validatePath = Join-Path $root '.github/workflows/validate.yml'
$publishPath = Join-Path $root '.github/workflows/publish-registry.yml'

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-PinnedActions([string]$Workflow, [string]$Name) {
    $uses = [regex]::Matches($Workflow, '(?m)^\s*-?\s*uses:\s*([^\s#]+)')
    Assert-Condition ($uses.Count -gt 0) "$Name must use at least one action"
    foreach ($match in $uses) {
        Assert-Condition ($match.Groups[1].Value -cmatch '^[^@]+@[0-9a-f]{40}$') `
            "$Name action is not pinned to a full commit SHA: $($match.Groups[1].Value)"
    }
}

Assert-Condition (Test-Path -LiteralPath $validatePath -PathType Leaf) `
    'Store validation workflow is missing.'
Assert-Condition (Test-Path -LiteralPath $publishPath -PathType Leaf) `
    'Official registry publication workflow is missing.'

$validate = Get-Content -LiteralPath $validatePath -Raw
$publish = Get-Content -LiteralPath $publishPath -Raw

Assert-PinnedActions $validate 'Store validation workflow'
Assert-PinnedActions $publish 'Registry publication workflow'

Assert-Condition ($validate.Contains('contents: read')) `
    'PR validation must use read-only repository permissions.'
Assert-Condition ($validate.Contains('pull_request:')) `
    'Store validation must run on pull requests.'
Assert-Condition (-not $validate.Contains('AURA_OFFICIAL_REGISTRY_SIGNING_KEY')) `
    'PR validation must not reference the production signing secret.'
Assert-Condition ($validate.Contains('node-version: 24')) `
    'Store validation must use Node 24.'
Assert-Condition ($validate.Contains('npm ci')) `
    'Store validation must install exactly locked Node dependencies.'
Assert-Condition ($validate.Contains('npm test')) `
    'Store validation must run signer tests.'
Assert-Condition ($validate.Contains('-Registry ./registry.json -UnsignedPayload')) `
    'Store validation must validate the reviewed unsigned source.'
Assert-Condition ($validate.Contains('--envelope ./plugins.json')) `
    'Store validation must verify the checked-in production envelope.'
Assert-Condition ($validate.Contains('--root ./trust/aura-plugin-root.json')) `
    'Store validation must use the checked-in public trust root.'
Assert-Condition ($validate.Contains('-VerifyRemote')) `
    'Store validation must preserve the complete remote artifact gate.'

Assert-Condition ($publish.Contains('contents: write')) `
    'Registry publication requires narrowly scoped contents write.'
Assert-Condition ($publish.Contains('branches: [main]')) `
    'Registry publication must run only for main pushes.'
Assert-Condition (-not $publish.Contains('pull_request:')) `
    'Registry publication must never run for pull requests.'
Assert-Condition ($publish.Contains('concurrency:')) `
    'Registry publication must declare a concurrency policy.'
Assert-Condition ($publish.Contains('group: official-registry-publication')) `
    'Registry publication must use the fixed official publication group.'
Assert-Condition ($publish.Contains('cancel-in-progress: false')) `
    'Registry publication must not cancel an in-flight signing run.'
Assert-Condition ($publish.Contains('!plugins.json')) `
    'Generated-only registry changes must not trigger another publication run.'
Assert-Condition ($publish.Contains('node-version: 24')) `
    'Registry publication must use Node 24.'
Assert-Condition ($publish.Contains('AURA_OFFICIAL_REGISTRY_SIGNING_KEY_PKCS8_BASE64')) `
    'Registry publication must consume the protected production signing secret.'
Assert-Condition ($publish.Contains('node ./tools/registry-envelope.mjs sign')) `
    'Registry publication must use the reviewed signer.'
Assert-Condition ($publish.Contains('node ./tools/registry-envelope.mjs verify')) `
    'Registry publication must verify its generated envelope.'
Assert-Condition ($publish.Contains('git add -- plugins.json')) `
    'Registry publication must stage only the generated envelope.'
Assert-Condition (-not $publish.Contains('git add .')) `
    'Registry publication must never stage the complete worktree.'

Write-Host 'Aura Store workflow policy tests passed.'
