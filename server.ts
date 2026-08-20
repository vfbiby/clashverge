import { serve } from "bun";
import path from "path";
import fs from "fs";
import YAML from "yaml";

const PORT = 9099;
const BACKEND = "http://127.0.0.1:9097";
const BACKEND_WS = "ws://127.0.0.1:9097";
const SECRET = "Set-your-secret77777";

const CODE_DIR = "/Users/zhangsike/codes/clashverge";
const CUSTOM_CONFIG_PATH = path.join(CODE_DIR, "custom-config.yaml");
const SCRIPT_PATH = path.join(CODE_DIR, "Script.js");
const MERGE_PATH = path.join(CODE_DIR, "Merge.yaml");
const DIST_DIR = path.join(CODE_DIR, "dist");
const VERGE_CONFIG_PATH = path.join(process.env.HOME || "", "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml");
const METACUBEXD_DIR = path.join(process.env.HOME || "", "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/ui");

// 确保 custom-config.yaml 存在
function loadCustomConfig() {
  if (!fs.existsSync(CUSTOM_CONFIG_PATH)) {
    return { base: {}, proxies: [], groups: [], rules: [] };
  }
  const content = fs.readFileSync(CUSTOM_CONFIG_PATH, "utf-8");
  return YAML.parse(content) || { base: {}, proxies: [], groups: [], rules: [] };
}

function saveAndSyncConfig(configData: { base: any; proxies: any[]; groups: any[]; rules: string[] }) {
  // 1. 保存 custom-config.yaml
  const yamlContent = YAML.stringify(configData);
  fs.writeFileSync(CUSTOM_CONFIG_PATH, yamlContent, "utf-8");

  // 2. 生成 Script.js
  const scriptContent = `function main(config, profileName) {
  if (!Array.isArray(config.proxies)) config.proxies = [];
  if (!Array.isArray(config["proxy-groups"])) config["proxy-groups"] = [];
  if (!Array.isArray(config.rules)) config.rules = [];

  // 1. 注入自建节点
  const myCustomProxies = ${JSON.stringify(configData.proxies || [], null, 2)};
  myCustomProxies.forEach((p) => {
    const idx = config.proxies.findIndex((existing) => existing.name === p.name);
    if (idx >= 0) config.proxies[idx] = p;
    else config.proxies.unshift(p);
  });

  // 2. 注入自定义策略组
  const customGroups = ${JSON.stringify(configData.groups || [], null, 2)};
  const customGroupNames = customGroups.map((g) => g.name);
  config["proxy-groups"] = config["proxy-groups"].filter((g) => !customGroupNames.includes(g.name));
  config["proxy-groups"].unshift(...customGroups);

  // 3. 注入自定义分流规则（置顶优先匹配）
  const priorityRules = ${JSON.stringify(configData.rules || [], null, 2)};
  config.rules = [
    ...priorityRules,
    ...config.rules.filter(
      (rule) => !priorityRules.some((r) => r.trim().toLowerCase() === rule.trim().toLowerCase())
    )
  ];

  return config;
}
`;
  fs.writeFileSync(SCRIPT_PATH, scriptContent, "utf-8");

  // 3. 生成 Merge.yaml
  const mergeContent = `# 你的全局扩展配置（Merge）
external-ui: ui
${YAML.stringify(configData.base || {})}
`;
  fs.writeFileSync(MERGE_PATH, mergeContent, "utf-8");

  // 4. 直接热注入到运行中的 clash-verge.yaml 并触发核心重载
  try {
    if (fs.existsSync(VERGE_CONFIG_PATH)) {
      const vergeRaw = fs.readFileSync(VERGE_CONFIG_PATH, "utf-8");
      const vergeConfig = YAML.parse(vergeRaw) || {};
      
      if (!Array.isArray(vergeConfig.proxies)) vergeConfig.proxies = [];
      if (!Array.isArray(vergeConfig["proxy-groups"])) vergeConfig["proxy-groups"] = [];
      if (!Array.isArray(vergeConfig.rules)) vergeConfig.rules = [];

      // 注入自建节点
      (configData.proxies || []).forEach((p: any) => {
        const idx = vergeConfig.proxies.findIndex((existing: any) => existing.name === p.name);
        if (idx >= 0) vergeConfig.proxies[idx] = p;
        else vergeConfig.proxies.unshift(p);
      });

      // 注入自定义策略组
      const customGroupNames = (configData.groups || []).map((g: any) => g.name);
      vergeConfig["proxy-groups"] = vergeConfig["proxy-groups"].filter((g: any) => !customGroupNames.includes(g.name));
      vergeConfig["proxy-groups"].unshift(...(configData.groups || []));

      // 注入规则
      const priorityRules = configData.rules || [];
      vergeConfig.rules = [
        ...priorityRules,
        ...vergeConfig.rules.filter(
          (rule: string) => !priorityRules.some((r: string) => r.trim().toLowerCase() === rule.trim().toLowerCase())
        )
      ];

      fs.writeFileSync(VERGE_CONFIG_PATH, YAML.stringify(vergeConfig), "utf-8");
    }
  } catch (err) {
    console.error("Direct injection to clash-verge.yaml error:", err);
  }

  return { success: true };
}

function parseProxyLink(link: string) {
  link = link.trim();
  if (link.startsWith("vless://")) {
    const url = new URL(link);
    const uuid = url.username;
    const server = url.hostname;
    const port = parseInt(url.port || "443", 10);
    const params = url.searchParams;
    const name = decodeURIComponent(url.hash.replace("#", "") || `${server}:${port}`);
    const security = params.get("security") || "";
    const sni = params.get("sni") || params.get("peer") || params.get("serverName") || "";
    const flow = params.get("flow") || "";
    const pbk = params.get("pbk") || params.get("public-key") || "";
    const fp = params.get("fp") || params.get("client-fingerprint") || "chrome";
    const type = params.get("type") || "tcp";

    const proxy: any = {
      name,
      type: "vless",
      server,
      port,
      uuid,
      encryption: "",
      tls: security === "tls" || security === "reality",
      servername: sni,
      flow: flow || undefined,
      "client-fingerprint": fp,
      network: type,
    };
    if (security === "reality" || pbk) {
      proxy["reality-opts"] = {
        "public-key": pbk,
      };
    }
    return proxy;
  } else if (link.startsWith("anytls://")) {
    const url = new URL(link);
    const password = url.username;
    const server = url.hostname;
    const port = parseInt(url.port || "443", 10);
    const sni = url.searchParams.get("peer") || url.searchParams.get("sni") || url.searchParams.get("servername") || server;
    const alpnStr = url.searchParams.get("alpn") || "";
    const fp = url.searchParams.get("fp") || url.searchParams.get("client-fingerprint") || "chrome";
    const name = decodeURIComponent(url.hash.replace("#", "") || `${server}:${port}`);
    const insecure = url.searchParams.get("insecure") === "1" || url.searchParams.get("skip-cert-verify") === "true";
    
    const proxy: any = {
      name,
      type: "anytls",
      server,
      port,
      password,
      sni,
      "skip-cert-verify": insecure || true,
      udp: true,
      tfo: false,
    };
    if (alpnStr) {
      proxy.alpn = alpnStr.split(",");
    }
    if (fp) {
      proxy["client-fingerprint"] = fp;
    }
    return proxy;
  } else if (link.startsWith("ss://")) {
    const name = link.includes("#") ? decodeURIComponent(link.split("#")[1]) : "Shadowsocks";
    let mainPart = link.replace("ss://", "").split("#")[0];
    if (mainPart.includes("@")) {
      const [userinfo, serverPart] = mainPart.split("@");
      const [server, port] = serverPart.split(":");
      const decodedUserinfo = atob(userinfo);
      const [cipher, password] = decodedUserinfo.split(":");
      return {
        name,
        type: "ss",
        server,
        port: parseInt(port, 10),
        cipher,
        password,
      };
    } else {
      const decoded = atob(mainPart);
      const [userinfo, serverPart] = decoded.split("@");
      const [cipher, password] = userinfo.split(":");
      const [server, port] = serverPart.split(":");
      return {
        name,
        type: "ss",
        server,
        port: parseInt(port, 10),
        cipher,
        password,
      };
    }
  } else if (link.startsWith("trojan://")) {
    const url = new URL(link);
    const password = url.username;
    const server = url.hostname;
    const port = parseInt(url.port || "443", 10);
    const sni = url.searchParams.get("sni") || url.searchParams.get("peer") || server;
    const name = decodeURIComponent(url.hash.replace("#", "") || `${server}:${port}`);
    return {
      name,
      type: "trojan",
      server,
      port,
      password,
      sni,
      "skip-cert-verify": false,
    };
  }
  throw new Error("不支持的节点链接协议，目前支持 anytls://, vless://, ss://, trojan://");
}

interface WsData {
  url: string;
  token?: string;
  upstream?: WebSocket;
}

const server = serve<WsData>({
  port: PORT,
  hostname: "127.0.0.1",
  async fetch(req, server) {
    const url = new URL(req.url);

    // 0. 注销并清除 Metacubexd 旧 ServiceWorker 缓存
    if (url.pathname === "/sw.js") {
      return new Response(`
        self.addEventListener('install', () => self.skipWaiting());
        self.addEventListener('activate', () => {
          self.registration.unregister();
          self.clients.matchAll({ type: 'window' }).then(clients => {
            for (const client of clients) client.navigate(client.url);
          });
        });
      `, {
        headers: { "Content-Type": "application/javascript", "Cache-Control": "no-cache" }
      });
    }

    // 1. WebSocket Upgrade
    if (req.headers.get("upgrade")?.toLowerCase() === "websocket") {
      const authHeader = req.headers.get("authorization")?.replace("Bearer ", "");
      const token = url.searchParams.get("token") || authHeader || SECRET;
      
      const success = server.upgrade(req, {
        data: {
          url: url.pathname + url.search,
          token: token,
        },
      });
      if (success) return undefined;
    }

    // 2. CORS Preflight
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS, PATCH",
          "Access-Control-Allow-Headers": "*",
          "Access-Control-Max-Age": "86400",
        },
      });
    }

    // 3. Custom Workbench API Endpoints
    if (url.pathname === "/api/custom-config" && req.method === "GET") {
      const data = loadCustomConfig();
      return Response.json(data, {
        headers: { "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache" },
      });
    }

    if (url.pathname === "/api/custom-config" && req.method === "POST") {
      try {
        const body = await req.json();
        saveAndSyncConfig(body);

        // 触发核心热重载
        try {
          await fetch(`${BACKEND}/configs?force=true`, {
            method: "PUT",
            headers: {
              "Authorization": `Bearer ${SECRET}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ path: VERGE_CONFIG_PATH }),
          });
        } catch (_) {}

        return Response.json({ success: true, message: "配置已保存并同步热重载！" }, {
          headers: { "Access-Control-Allow-Origin": "*" },
        });
      } catch (err) {
        return Response.json({ error: String(err) }, { status: 500 });
      }
    }

    if (url.pathname === "/api/live-proxies" && req.method === "GET") {
      try {
        const res = await fetch(`${BACKEND}/proxies`, {
          headers: { "Authorization": `Bearer ${SECRET}` },
        });
        const data: any = await res.json();
        const proxiesMap = data.proxies || {};

        const customData = loadCustomConfig();
        const customProxyNames = (customData.proxies || []).map((p: any) => p.name);
        const customGroupNames = (customData.groups || []).map((g: any) => g.name);

        const allProxyNames = Object.keys(proxiesMap);
        const activeGroupNow: Record<string, string> = {};
        
        // 记录所有组当前激活的节点
        allProxyNames.forEach(name => {
          if (proxiesMap[name]?.now) {
            activeGroupNow[name] = proxiesMap[name].now;
          }
        });

        // 提取订阅里的单节点
        const subscriptionProxies = allProxyNames.filter((name) => {
          const p = proxiesMap[name];
          const isGroupType = ["Selector", "URLTest", "Fallback", "LoadBalance", "Direct", "Reject", "Compatible"].includes(p?.type);
          return p && !isGroupType
            && !customProxyNames.includes(name)
            && !["GLOBAL", "DIRECT", "REJECT", "COMPATIBLE"].includes(name);
        }).map(name => {
          const hist = proxiesMap[name]?.history || [];
          const lastDelay = hist.length > 0 ? hist[hist.length - 1]?.delay : 0;
          return {
            name,
            type: proxiesMap[name]?.type,
            delay: lastDelay,
          };
        });

        // 提取订阅里的原生策略组 (排除自建组和特殊内置组)
        const subscriptionGroups = allProxyNames.filter((name) => {
          const p = proxiesMap[name];
          const isGroupType = ["Selector", "URLTest", "Fallback", "LoadBalance"].includes(p?.type);
          return isGroupType && !customGroupNames.includes(name) && !["GLOBAL"].includes(name);
        }).map(name => ({
          name,
          type: proxiesMap[name]?.type,
          now: proxiesMap[name]?.now,
          all: proxiesMap[name]?.all || [],
        }));

        return Response.json({
          customProxies: customData.proxies || [],
          subscriptionProxies,
          subscriptionGroups,
          customGroups: customData.groups || [],
          activeGroupNow,
        }, { headers: { "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache" } });
      } catch (err) {
        return Response.json({ error: String(err) }, { status: 500 });
      }
    }

    // 批量测速接口
    if (url.pathname === "/api/test-delay" && req.method === "POST") {
      try {
        const { proxies } = await req.json();
        if (!Array.isArray(proxies) || proxies.length === 0) {
          return Response.json({ results: {} }, { headers: { "Access-Control-Allow-Origin": "*" } });
        }

        const results: Record<string, number> = {};
        const testUrl = "http://www.gstatic.com/generate_204";
        const timeout = 5000;

        const testSingle = async (proxyName: string) => {
          try {
            const encoded = encodeURIComponent(proxyName);
            const res = await fetch(`${BACKEND}/proxies/${encoded}/delay?timeout=${timeout}&url=${encodeURIComponent(testUrl)}`, {
              headers: { "Authorization": `Bearer ${SECRET}` },
            });
            if (res.ok) {
              const data: any = await res.json();
              results[proxyName] = data.delay || 0;
            } else {
              results[proxyName] = -1;
            }
          } catch {
            results[proxyName] = -1;
          }
        };

        const batchSize = 20;
        for (let i = 0; i < proxies.length; i += batchSize) {
          const chunk = proxies.slice(i, i + batchSize);
          await Promise.all(chunk.map(testSingle));
        }

        return Response.json({ success: true, results }, {
          headers: { "Access-Control-Allow-Origin": "*" },
        });
      } catch (err: any) {
        return Response.json({ error: String(err) }, { status: 500 });
      }
    }

    if (url.pathname === "/api/parse-link" && req.method === "POST") {
      try {
        const { link } = await req.json();
        const proxy = parseProxyLink(link);
        return Response.json({ success: true, proxy }, {
          headers: { "Access-Control-Allow-Origin": "*" },
        });
      } catch (err: any) {
        return Response.json({ error: err.message || String(err) }, { status: 400 });
      }
    }

    // 4. Mihomo Core API Proxy
    const backendEndpoints = ["/version", "/configs", "/proxies", "/rules", "/traffic", "/logs", "/connections", "/providers", "/dns", "/group", "/restart", "/memory"];
    const isApi = backendEndpoints.some(ep => url.pathname === ep || url.pathname.startsWith(ep + "/"));

    if (isApi) {
      try {
        const targetUrl = `${BACKEND}${url.pathname}${url.search}`;
        const headers = new Headers(req.headers);
        headers.delete("host");
        if (!headers.has("authorization")) {
          headers.set("authorization", `Bearer ${SECRET}`);
        }
        
        const response = await fetch(targetUrl, {
          method: req.method,
          headers: headers,
          body: req.method !== "GET" && req.method !== "HEAD" ? await req.blob() : undefined,
        });

        const newHeaders = new Headers(response.headers);
        newHeaders.set("Access-Control-Allow-Origin", "*");
        newHeaders.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS, PATCH");
        newHeaders.set("Access-Control-Allow-Headers", "*");

        return new Response(response.body, {
          status: response.status,
          statusText: response.statusText,
          headers: newHeaders,
        });
      } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), { status: 502 });
      }
    }

    // 5. Serve Metacubexd on /dashboard/*
    if (url.pathname.startsWith("/dashboard") || url.pathname.startsWith("/_nuxt") || url.pathname.startsWith("/_fonts")) {
      let relativePath = url.pathname.replace("/dashboard", "");
      if (!relativePath || relativePath === "/") relativePath = "/index.html";
      let targetPath = path.join(METACUBEXD_DIR, decodeURIComponent(relativePath));
      let file = Bun.file(targetPath);
      if (await file.exists()) {
        return new Response(file);
      }
      let indexFile = Bun.file(path.join(METACUBEXD_DIR, "index.html"));
      return new Response(indexFile);
    }

    // 6. Serve SolidJS SPA from dist/ or public/
    let pathname = decodeURIComponent(url.pathname);
    if (pathname === "/" || pathname === "/custom") pathname = "/index.html";
    
    let distPath = path.join(DIST_DIR, pathname);
    let distFile = Bun.file(distPath);
    if (await distFile.exists()) {
      return new Response(distFile, { headers: { "Cache-Control": "no-cache" } });
    }

    let distIndex = Bun.file(path.join(DIST_DIR, "index.html"));
    if (await distIndex.exists()) {
      return new Response(distIndex, { headers: { "Cache-Control": "no-cache" } });
    }

    let publicPath = path.join(CODE_DIR, "public", pathname);
    let publicFile = Bun.file(publicPath);
    if (await publicFile.exists()) {
      return new Response(publicFile, { headers: { "Cache-Control": "no-cache" } });
    }

    return new Response(Bun.file(path.join(CODE_DIR, "public", "index.html")), { headers: { "Cache-Control": "no-cache" } });
  },
  websocket: {
    open(ws) {
      let targetPath = ws.data.url;
      if (ws.data.token && !targetPath.includes("token=")) {
        const joinChar = targetPath.includes("?") ? "&" : "?";
        targetPath += `${joinChar}token=${encodeURIComponent(ws.data.token)}`;
      }
      const targetUrl = `${BACKEND_WS}${targetPath}`;
      
      const upstream = new WebSocket(targetUrl);
      ws.data.upstream = upstream;

      upstream.onmessage = (event) => {
        try {
          ws.send(event.data);
        } catch (_) {}
      };

      upstream.onclose = () => {
        try {
          ws.close();
        } catch (_) {}
      };

      upstream.onerror = () => {
        try {
          ws.close();
        } catch (_) {}
      };
    },
    message(ws, message) {
      if (ws.data.upstream && ws.data.upstream.readyState === WebSocket.OPEN) {
        ws.data.upstream.send(message);
      }
    },
    close(ws) {
      if (ws.data.upstream) {
        ws.data.upstream.close();
      }
    },
  },
});

console.log(`Clash Verge Custom Workbench & Dashboard is running at http://127.0.0.1:${PORT}`);
