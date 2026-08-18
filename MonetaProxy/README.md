# MonetaProxy — 单站点微型专用代理

只把 **monetamarkets.com** 走你的自建节点，其他网站全部直连（国内网站正常打开，国外打不开的保持打不开）。基于轻量裁剪版 **sing-box** 核心（仅 18MB，内存占用仅 ~10MB）。

## 使用

1. **先退出 Clash Verge**（或至少关掉它的系统代理/TUN），避免两个代理端口打架。
2. 双击 **start.command** → 代理启动，系统代理自动开启（sing-box 监听 7891 端口）。
3. 打开 monetamarket.com 网页版即可。
4. 用完双击 **stop.command** → 停止代理、恢复系统代理。
5. **status.command** → 查看运行状态和最近日志。

## 文件说明

| 文件 | 作用 |
|------|------|
| `config.json` | 核心配置。**要改代理的域名就编辑底部 route.rules** |
| `start.command` / `stop.command` / `status.command` | 启停/状态脚本，双击运行 |
| `sing-box` | sing-box 裁剪核心二进制（仅含 VLESS Reality + AnyTLS，不入 git） |
| `sing-box.log` | 运行日志（节点连不上、域名没匹配上时来这里看） |
| `build-singbox.sh` | 一键重新编译裁剪核心脚本 |

## 常见问题

- **网页版里有部分资源打不开**：券商网页可能引用了 CDN 域名（不在 monetamarket.com 下）。看 `sing-box.log` 里被直连的域名，把需要走节点的域名加进 `config.json` 的 `route.rules`（格式在 `domain_suffix` 数组中追加），重启代理即可。
- **重新编译核心**：双击运行 `build-singbox.sh` 即可重新编译最新轻量核心。
- 注意：`config.json` 里有你的节点密钥（UUID），**别把整个文件夹随便发给别人**。
