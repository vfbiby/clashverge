function main(config, profileName) {
  if (!Array.isArray(config.proxies)) config.proxies = [];
  if (!Array.isArray(config["proxy-groups"])) config["proxy-groups"] = [];
  if (!Array.isArray(config.rules)) config.rules = [];

  // 1. 定义自建节点
  const myCustomProxies = [
    {
      name: "🇺🇸 USA_Los_LAX-DC2 xtls-reality",
      type: "vless",
      server: "154.53.75.226",
      port: 8881,
      uuid: "decf85cf-9aca-4328-a071-3837631098eb",
      encryption: "",
      tls: true,
      servername: "addons.mozilla.org",
      flow: "xtls-rprx-vision",
      "client-fingerprint": "chrome",
      "reality-opts": {
        "public-key": "XLY4_lSmUIrs53Ae2LYqpjEWKM7HuAvtOE5t2JNM83c"
      },
      network: "tcp"
    }
  ];

  const customProxyNames = myCustomProxies.map((p) => p.name);

  // 2. 将自建节点注入到 config.proxies
  myCustomProxies.forEach((p) => {
    if (!config.proxies.some((existing) => existing.name === p.name)) {
      config.proxies.unshift(p);
    }
  });

  // 3. 筛选订阅中的节点（排除自建节点名称）
  const allProxyNames = config.proxies
    .map((p) => p?.name)
    .filter((name) => Boolean(name) && !customProxyNames.includes(name));

  const sgOrUsPattern = /(🇸🇬|新加坡|狮城|singapore|\bsg\b|hong kong|🇺🇸|美国|硅谷|united states|\busa\b|\bus\b)/i;
  const hkSgPattern = /(🇭🇰|香港|hong kong|\bhk\b|🇸🇬|新加坡|狮城|singapore|\bsg\b)/i;

  const googleCandidates = [
    ...new Set(allProxyNames.filter((name) => sgOrUsPattern.test(name))),
  ];

  const customCandidates = [
    ...new Set(allProxyNames.filter((name) => hkSgPattern.test(name))),
  ];

  // 查找原配置里的主分组（Proxies / 节点选择 等），兼容 emoji 前缀的模糊匹配
  function findMainGroupName(groups) {
    // 1. 精确匹配 Proxies
    if (groups.some((g) => g?.name === "Proxies")) return "Proxies";
    // 2. 去掉 emoji/符号/空白后按关键字模糊匹配
    const clean = (s) => String(s ?? "").replace(/[^\w一-龥]/g, "").toLowerCase();
    const matched = groups.find((g) => {
      const c = clean(g?.name);
      return /prox/.test(c) || c.includes("节点选择") || c.includes("代理") || c.includes("自动选择") || c.includes("故障转移") || c.includes("xboard") || c.includes("node10");
    });
    return matched ? matched.name : null;
  }

  const targetGroupName = findMainGroupName(config["proxy-groups"]);
  const proxiesGroupInsert = targetGroupName ? [targetGroupName] : [];

  // 4. 新建目标策略组（包含自建节点和 Proxies 分组）
  const myGoogleGroup = {
    name: "MyGoogle",
    type: "select",
    proxies: [...customProxyNames, ...proxiesGroupInsert],
    // proxies: [...customProxyNames, ...googleCandidates],
  };

  const claudeGroup = {
    name: "Claude",
    type: "select",
    // 仅使用自建节点（不加订阅组）
    proxies: ["🇺🇸 USA_Los_LAX-DC2 xtls-reality"],
  };

  // Custom 组（走代理）
  const customGroup = {
    name: "Custom",
    type: "select",
    proxies: [...customProxyNames, ...proxiesGroupInsert],
    // proxies: [...customProxyNames, ...customCandidates],
  };

  // CustomDirect 组（走直连，保留 DIRECT 及 Proxies 选项方便灵活切换）
  const customDirectGroup = {
    name: "CustomDirect",
    type: "select",
    proxies: ["DIRECT", ...proxiesGroupInsert],
  };

  // 直接将新组插到前面（不清理任何原有的组）
  config["proxy-groups"].unshift(myGoogleGroup, claudeGroup, customGroup, customDirectGroup);

  // 5. 专属路由规则（带详细注释）
  const myGoogleRules = [
    // --- Google 账号与认证服务 ---
    "DOMAIN,accounts.google.com,MyGoogle",          // Google 账号登录/认证中心
    "DOMAIN-SUFFIX,recaptcha.net,MyGoogle",         // Google 验证码 (reCAPTCHA) 服务

    // --- Google AI / Gemini / AI Studio 核心接口 ---
    "DOMAIN,ai.google.dev,MyGoogle",                // Google AI 开发者门户 / AI Studio
    "DOMAIN,generativelanguage.googleapis.com,MyGoogle", // Gemini API 语言模型核心请求接口
    "DOMAIN,stitch.withgoogle.com,MyGoogle",        // Google Stitch (AI 实验/设计工具)
    "DOMAIN-SUFFIX,stitch.googleapis.com,MyGoogle", // Google Stitch 后端接口

    // --- Google 基础服务与静态资源 ---
    "DOMAIN-SUFFIX,gstatic.com,MyGoogle",           // Google 静态资源 CDN
    "DOMAIN-SUFFIX,googleusercontent.com,MyGoogle", // 用户生成内容 CDN (头像、Gemini图片等)

    // --- Google API 基础架构与云端服务 ---
    "DOMAIN-SUFFIX,googleapis.com,MyGoogle",        // Google 官方核心 API
    "DOMAIN-SUFFIX,cloudfunctions.net,MyGoogle",    // Google Cloud Functions
    "DOMAIN-SUFFIX,appspot.com,MyGoogle",           // Google App Engine
    "DOMAIN-SUFFIX,run.app,MyGoogle",               // Google Cloud Run
    "DOMAIN-SUFFIX,firebaseio.com,MyGoogle",        // Firebase 实时数据库

    // --- Google 数据统计与分析 ---
    "DOMAIN-SUFFIX,google-analytics.com,MyGoogle",  // Google Analytics
    "DOMAIN-SUFFIX,googletagmanager.com,MyGoogle",  // Google Tag Manager

    // --- 通用 Google 泛域名规则 ---
    "DOMAIN-SUFFIX,google.com,MyGoogle",            // Google 主域名
    "DOMAIN-KEYWORD,google,MyGoogle"                // 包含 google 关键字的所有其他域名
  ];

  const claudeRules = [
    "DOMAIN-SUFFIX,claude.ai,Claude",
    "DOMAIN-SUFFIX,claude.com,Claude",
    "DOMAIN-SUFFIX,clau.de,Claude",
    "DOMAIN-SUFFIX,anthropic.com,Claude",
    "DOMAIN-SUFFIX,claudeusercontent.com,Claude"
  ];

  // 自定义代理规则（走 Custom 组）
  const customRules = [
    "DOMAIN-SUFFIX,bygcloud.com,Custom",
    "DOMAIN-SUFFIX,lxtrd.cn.com,Custom",
    "DOMAIN-SUFFIX,anzo-asset.com,Custom",
    
  ];

  // 自定义直连规则（走 CustomDirect 组，需直连的域名写在这里）
  const customDirectRules = [
    // 示例："DOMAIN-SUFFIX,example.cn,CustomDirect"
    // "DOMAIN-SUFFIX,rtoc.cc,CustomDirect",
    // "DOMAIN-SUFFIX,apple.com,CustomDirect",
    "DOMAIN-SUFFIX,deepseek.com,CustomDirect",
    "DOMAIN-SUFFIX,qianwenai.com,CustomDirect",
    "DOMAIN-SUFFIX,volces.com,CustomDirect",
    // "DOMAIN-SUFFIX,api.rtoc.cc,Custom",
  ];

  // 面板域名走节点（国内直连 CF 的 443 常被重置，必须走代理）
  const panelRules = [
    "DOMAIN-SUFFIX,node10.de5.net,MyGoogle",
  ];

  const priorityRules = [...panelRules, ...customDirectRules, ...customRules, ...claudeRules, ...myGoogleRules];

  // 6. 将自定义规则优先级提升至最顶端，原规则置后
  config.rules = [
    ...priorityRules,
    ...config.rules.filter(
      (rule) => !priorityRules.some((r) => r.trim().toLowerCase() === rule.trim().toLowerCase())
    )
  ];

  return config;
}