# MT4 / MT5 配置文件读写与 Moneta 服务器注入设计方案

## 一、需求背景与目标
为方便交易用户直接在 MetaTrader 4 (MT4) 与 MetaTrader 5 (MT5) 客户端中登录 MonetaMarkets 交易账户，开发一套跨平台的配置文件读写与自动注入模块。

用户启动程序后，程序会自动探测系统中的 MT4 / MT5 安装目录与数据目录，将 MonetaMarkets 的官方交易服务器（Live / Demo）注入到客户端配置文件中，使客户端在登录时能够直接在服务器下拉列表中选到 Moneta 的服务器。

---

## 二、需求确认清单（基于用户确认）

| 需求维度 | 用户决策与规范 |
| :--- | :--- |
| **开发语言** | **Go 语言**，模块化设计，无缝集成到 `MonetaProxy.exe` 托盘应用中 |
| **服务器数据源** | **内置静态默认配置 + 异步 API 在线拉取覆盖**（无网络时用内置，有网络时拉取最新） |
| **写入模式** | **追加合并（Upsert）**：保留用户已有的其他券商服务器，更新或新增 Moneta 服务器 |
| **流量策略** | **MT4/MT5 交易流量保持原生直连**，不走代理隧道 |
| **目录探测机制** | 1. **标准共享数据目录**：`%APPDATA%\MetaQuotes\Terminal\<Hash>\`<br>2. **便携模式（/portable）目录**：终端安装根目录下的 `config/` 或 `bases/`<br>3. **手动指定路径**：支持自定义选择或输入 MT4 / MT5 路径 |

---

## 三、MT4 / MT5 配置文件底层格式与加密协议

### 1. MetaTrader 4 (MT4)
- **文件路径**：`Terminal/<Hash>/config/<ServerName>.srv` 与 `config/servers.ini`
- **数据结构**：
  - `MainServer` (352 字节)：包含服务器名称、注释、`is_demo` 标志、接入点数量 `count`、默认主机地址等。
  - `Server` 数组 (每项 160 字节)：包含接入点 IP / 域名、端口、描述、ping 值、代理标志等。
- **加密机制 (`MT4Crypt`)**：
  - 采用 16 字节专用异或流循环加密：
    `Key = [65, 182, 127, 88, 56, 12, 240, 45, 123, 57, 8, 254, 33, 187, 65, 88]`
  - 对接入点二进制块进行流式异或加解密：`res[i] = buf[i] ^ (prev_byte + key[i & 0xF])`。

### 2. MetaTrader 5 (MT5)
- **文件路径**：`Terminal/<Hash>/bases/servers.dat` 或 `config/servers.dat`
- **数据结构**：
  - `DatHeader` (428 字节)：魔数 Id (505/506)、版权声明、数据类型 ("Servers")、时间戳等。
  - `Server` 数组：
    - `ServerInfoEx` (1716 字节)：UTF-16LE 编码的服务器名称、公司名称、网址等。
    - `AccessEx` 数组：接入点组。
    - `AddressRecEx` (1284 字节)：具体的接入点 IP / 域名与端口。
- **加密机制 (`Crypt.EasyCrypt`)**：
  - 对 `ServerInfoEx`、`AccessRecEx`、`AddressRecEx` 每个结构体采用 MT5 专用的 EasyCrypt 异或流加密序列化。

---

## 四、Go 模块架构设计

```
MonetaProxy-Windows/
├── mtconfig/
│   ├── mt4.go        # MT4 .srv 与 servers.ini 读写解析器
│   ├── mt5.go        # MT5 servers.dat 读写解析器
│   ├── crypto.go     # MT4Crypt 与 MT5 EasyCrypt 加解密算法
│   ├── scanner.go    # 自动探测 AppData 共享目录 / Portable 目录
│   └── servers.go    # 内置 Moneta 服务器列表定义 + 异步远程拉取更新
```

---

## 五、下一步工作
1. 接收用户提供的 Moneta MT4 / MT5 服务器 IP 与端口列表。
2. 完成 Go 语言版本的加解密与读写单元测试，验证生成文件的二进制兼容性。
3. 集成至 Windows 托盘程序，增加一键注入与目录探测功能。
