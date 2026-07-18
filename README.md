# HMCL Nex Plugin Store

HMCL Nex 插件商店远程注册表。

## `plugins.json` 格式

```json
{
  "schemaVersion": 1,
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
      "tags": ["example", "utility"],
      "capabilities": ["lifecycle", "mixin"]
    }
  ]
}
```

## 插件仓库 `manifest.json` 格式

```json
{
  "schemaVersion": 1,
  "id": "example.plugin",
  "license": "GPL-3.0-or-later",
  "website": "https://example.com",
  "source": "https://github.com/owner/plugin-repo",
  "versions": [
    {
      "version": "1.0.0",
      "packageUrl": "https://github.com/owner/plugin-repo/releases/download/v1.0.0/plugin-v1.0.0.npl",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "minLauncherVersion": "3.0.0",
      "requiredJavaVersion": "17",
      "pluginApiVersion": 2,
      "requiresRestart": true,
      "channel": "stable",
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

## 校验与传输要求

- 注册表、仓库清单和插件包的远程 URL 必须使用 HTTPS；本地开发仅允许 `http://localhost` / 回环地址。
- `manifest.json.id` 必须与 `plugins.json` 中的条目 ID 完全一致。
- 每个版本必须提供 64 位十六进制 SHA-256；HMCL 下载到临时文件，校验大小和摘要后再原子替换已安装包。
- `pluginApiVersion` 当前填写 `2`，对应支持 `schemaVersion: 2` 和 `mixins` 的插件清单。
- 含 Mixin 的版本将 `requiresRestart` 设为 `true`，并在注册表 `capabilities` 中加入 `mixin`。

## 发布流程

1. 插件仓库通过 GitHub Releases 上传 `.npl`。
2. 计算 `.npl` 的 SHA-256。
3. 更新插件仓库的 `manifest.json`。
4. 在本仓库 `plugins.json` 添加或更新插件条目。

提交前运行：

```powershell
./tools/validate-store.ps1
```

仓库 CI 会执行同一校验，阻止重复 ID、不安全 URL、无效 SHA-256、零大小包和不支持的 API schema。

HMCL Nex 会读取 `plugins.json`，展示分类、标签、详情、已安装状态和可更新状态。
