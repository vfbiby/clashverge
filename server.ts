import { serve } from "bun";
import path from "path";

const UI_DIR = path.join(process.env.HOME || "", "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/ui");
const BACKEND = "http://127.0.0.1:9097";
const BACKEND_WS = "ws://127.0.0.1:9097";

interface WsData {
  url: string;
  token?: string;
  upstream?: WebSocket;
}

const server = serve<WsData>({
  port: 9099,
  hostname: "127.0.0.1",
  async fetch(req, server) {
    const url = new URL(req.url);

    // 1. WebSocket Upgrade
    if (req.headers.get("upgrade")?.toLowerCase() === "websocket") {
      const authHeader = req.headers.get("authorization")?.replace("Bearer ", "");
      const token = url.searchParams.get("token") || authHeader || "Set-your-secret77777";
      
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

    // 3. API Proxy (if request matches backend endpoints or starts with known API paths)
    const backendEndpoints = ["/version", "/configs", "/proxies", "/rules", "/traffic", "/logs", "/connections", "/providers", "/dns", "/group", "/restart", "/memory"];
    const isApi = backendEndpoints.some(ep => url.pathname === ep || url.pathname.startsWith(ep + "/"));

    if (isApi) {
      try {
        const targetUrl = `${BACKEND}${url.pathname}${url.search}`;
        const headers = new Headers(req.headers);
        headers.delete("host");
        
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

    // 4. Static file serving
    let pathname = decodeURIComponent(url.pathname);
    let targetPath = path.join(UI_DIR, pathname === "/" ? "index.html" : pathname);

    let file = Bun.file(targetPath);
    if (await file.exists()) {
      return new Response(file);
    }

    // SPA fallback
    let indexFile = Bun.file(path.join(UI_DIR, "index.html"));
    return new Response(indexFile);
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

console.log(`Metacubexd Web UI with full WebSocket proxy is running at http://127.0.0.1:${server.port}`);
