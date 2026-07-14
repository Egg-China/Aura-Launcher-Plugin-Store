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
      "repository": "https://github.com/owner/plugin-repo",
      "homepage": "https://example.com",
      "category": "utility",
      "tags": ["example", "utility"]
    }
  ]
}
```

## 插件仓库 `manifest.json` 格式

```json
{
  "license": "GPL-3.0-or-later",
  "website": "https://example.com",
  "source": "https://github.com/owner/plugin-repo",
  "versions": [
    {
      "version": "1.0.0",
      "packageUrl": "https://github.com/owner/plugin-repo/releases/download/v1.0.0/plugin-v1.0.0.npl",
      "sha256": "...",
      "minLauncherVersion": "3.0.0",
      "requiredJavaVersion": "17",
      "size": 102400,
      "releaseNotes": "首次发布",
      "releaseDate": "2026-07-14"
    }
  ]
}
```

## 推荐分类

- `utility`
- `integration`
- `theme`
- `tool`
- `experimental`

## 发布流程

1. 插件仓库通过 GitHub Releases 上传 `.npl`。
2. 计算 `.npl` 的 SHA-256。
3. 更新插件仓库的 `manifest.json`。
4. 在本仓库 `plugins.json` 添加或更新插件条目。

HMCL Nex 会读取 `plugins.json`，展示分类、标签、详情、已安装状态和可更新状态。
