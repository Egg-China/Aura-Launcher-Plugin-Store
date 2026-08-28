# Aura Launcher Plugin Store

This repository is the public registry for reviewed Aura Launcher plugins. The registry itself uses schema v1. Each entry pins the exact bytes of a plugin repository's Store schema-v2 `manifest.json`.

## Registry

`plugins.json` contains one entry per plugin ID:

```json
{
  "id": "dev.example.plugin",
  "name": "Example Plugin",
  "manifestUrl": "https://raw.githubusercontent.com/owner/repository/main/manifest.json",
  "manifestSha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "repository": "https://github.com/owner/repository",
  "category": "utility",
  "tags": ["aura-launcher"],
  "capabilities": ["lifecycle"]
}
```

`manifestSha256` is lowercase SHA-256 over the raw manifest bytes returned by `manifestUrl`. Updating a plugin manifest requires updating this pin in the same Store review.

## Runtime Hosts

Schema-v5 Runtime Providers publish a Store schema-v2 manifest. Each version uses `artifacts[]` instead of version-level `packageUrl`, `sha256`, and `size`. Aura's official Runtime Hosts publish exactly these targets:

- `windows-x64`
- `windows-arm64`
- `linux-x64`
- `linux-arm64`
- `macos-x64`
- `macos-arm64`

The Store manifest must match every package's schema-v5 `plugin.json`, including runtime, ABI, platforms, Provider declarations, permissions, launcher constraint, and dependencies.

## Validation

Run the structural regression suite:

```powershell
./tools/test-validate-store.ps1
```

Run the complete public-byte gate with an exact schema-v5 SDK checkout:

```powershell
./tools/validate-store.ps1 `
    -VerifyRemote `
    -NplValidator ../HMCL-CE-Plugin-SDK/tools/validate-npl.ps1
```

The remote gate downloads every root manifest and Release NPL, checks the pinned manifest hash, package SHA-256 and size, and then validates each NPL against its Store version metadata. CI performs both gates on every push and pull request.

Only HTTPS URLs are accepted outside loopback development. Temporary GitHub Actions artifact URLs are not valid Store download locations.
