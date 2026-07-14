# HMCL Nex Plugin Store

HMCL Nex 插件商店远程注册表。

## `plugins.json` 格式

```json
{
  "name": "HMCL Nex Plugin Store Registry",
  "description": "HMCL Nex 插件商店列表",
  "homepageUrl": "https://github.com/PCL-Nex-Developer/HMCL-Nex-Plugin-Store",
  "plugins": [
    {
      "id": "example.plugin",
      "name": "示例插件",
      "author": "Author",
      "description": "插件描述",
      "manifestUrl": "https://raw.githubusercontent.com/owner/plugin-repo/main/manifest.json",
      "repository": "https://github.com/owner/plugin-repo"
    }
  ]
}
```

## 插件仓库 `manifest.json` 格式

```json
{
  "versions": [
    {
      "version": "1.0.0",
      "packageUrl": "https://github.com/owner/plugin-repo/releases/download/v1.0.0/plugin-v1.0.0.npl",
      "sha256": "...",
      "minLauncherVersion": "3.0.0",
      "releaseNotes": "首次发布",
      "releaseDate": "2026-07-14"
    }
  ]
}
```
