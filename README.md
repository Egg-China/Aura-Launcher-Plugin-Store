# Aura Launcher Plugin Store

This repository publishes the official registry for reviewed Aura Launcher plugins. The registry payload uses Store schema v1. Each entry pins the exact bytes of a plugin repository's Store schema-v2 `manifest.json`.

## Registry Files

`registry.json` is the reviewed source payload. Pull requests edit this file.

`plugins.json` is generated from `registry.json` and contains an Ed25519 signature envelope. Aura Launcher treats registry content as official only after the embedded `official-repository` trust role verifies this envelope. Do not edit `plugins.json` by hand.

Each source entry includes an exact manifest pin:

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

Schema-v5 Runtime Providers publish a Store schema-v2 manifest. Each version uses `artifacts[]` instead of version-level `packageUrl`, `sha256`, and `size`. Official Runtime Hosts publish exactly these targets:

- `windows-x64`
- `windows-arm64`
- `linux-x64`
- `linux-arm64`
- `macos-x64`
- `macos-arm64`

The Store manifest must match every package's schema-v5 `plugin.json`, including runtime, ABI, platforms, Provider declarations, permissions, launcher constraint, and dependencies.

## Local Validation

Install the pinned Node dependency and run the signer and validator regression suites:

```powershell
npm ci
npm test
./tools/test-validate-store.ps1
./tools/validate-store.ps1 -Registry ./registry.json -UnsignedPayload
```

Validate a generated official envelope against a public trust root:

```powershell
node ./tools/registry-envelope.mjs verify `
    --envelope ./plugins.json `
    --root ./trust/aura-plugin-root.json
./tools/validate-store.ps1 `
    -Registry ./plugins.json `
    -TrustRoot ./trust/aura-plugin-root.json
```

The complete public-byte gate additionally uses `-VerifyRemote` and an exact schema-v5 SDK `validate-npl.ps1` path. It downloads every root manifest and Release NPL, checks pinned manifest hashes, package SHA-256 and sizes, and validates every NPL against its Store version metadata.

Only HTTPS URLs are accepted outside loopback development. Temporary workflow artifact URLs are not valid Store download locations.

## Signing Boundary

Production signing reads PKCS#8 Base64 only from the `AURA_OFFICIAL_REGISTRY_SIGNING_KEY_PKCS8_BASE64` repository secret. Local ephemeral signing may instead set `AURA_OFFICIAL_REGISTRY_SIGNING_KEY_FILE` to a protected temporary file. Private key bytes must never be passed as a command argument, committed, logged, stored in a repository variable, or uploaded as an artifact.

The public X.509 SPKI key and its `ed25519:<sha256>` key ID are committed in `trust/aura-plugin-root.json`. This public root is also supplied to Aura Launcher builds through `AURA_PLUGIN_ROOT_JSON`.

Key rotation follows this order:

1. Generate a new Ed25519 key in an operating-system temporary directory.
2. Publish an Aura Launcher trust root that authorizes the new public key.
3. Wait until supported Aura Launcher builds contain that root.
4. Replace the Store signing secret and publish a registry envelope signed by the new key.
5. Remove the retired public key in a later Aura Launcher trust-root update.

At no point should a registry be published with a key that released Aura Launcher builds do not yet authorize.
