# MonetaProxy — 单站点专用代理

只把 **monetamarket.com** 走你的自建节点，其他网站全部直连（国内网站正常打开，国外打不开的保持打不开）。基于 mihomo 核心，无需安装任何东西。

## 使用

1. **先退出 Clash Verge**（或至少关掉它的系统代理/TUN），避免两个代理打架。
2. 双击 **start.command** → 代理启动，系统代理自动开启（mihomo 监听 7891 端口）。
3. 打开 monetamarket.com 网页版即可。
4. 用完双击 **stop.command** → 停止代理、恢复系统代理。
5. **status.command** → 查看运行状态和最近日志。

## 文件说明

| 文件 | 作用 |
|------|------|
| `config.yaml` | 核心配置。**要改代理的域名就编辑底部 rules** |
| `start.command` / `stop.command` / `status.command` | 启停/状态脚本，双击运行 |
| `mihomo` | mihomo 核心二进制（不入 git，用 download-mihomo.sh 重新拉取） |
| `mihomo.log` | 运行日志（节点连不上、域名没匹配上时来这里看） |

## 常见问题

- **网页版里有部分资源打不开**：券商网页可能引用了 CDN 域名（不在 monetamarket.com 下）。看 `mihomo.log` 里被直连的域名，把需要走节点的域名加进 `config.yaml` 的 rules（格式 `- DOMAIN-SUFFIX,域名,PROXY`），重启代理即可。
- **MT5 终端连不上**：终端连的是券商交易服务器，通常是 IP 不是域名，且不读系统代理。需要的话把交易服务器 IP 加规则（`- IP-CIDR,1.2.3.4/32,PROXY,no-resolve`），或改用 TUN 模式。
- **第一次启动被防火墙拦**：允许 mihomo 接受传入连接即可（它监听 7891 是给自己用的）。
- **mihomo 被删/想更新**：双击运行 `download-mihomo.sh`。
- 注意：`config.yaml` 里有你的节点密钥（UUID），**别把整个文件夹随便发给别人**。
