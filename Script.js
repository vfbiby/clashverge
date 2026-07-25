function main(config, profileName) {
  if (!Array.isArray(config.proxies)) config.proxies = [];
  if (!Array.isArray(config["proxy-groups"])) config["proxy-groups"] = [];
  if (!Array.isArray(config.rules)) config.rules = [];

  // 1. 定义自建节点
  const myCustomProxies = [
    {
      name: "DG500G",
      type: "vless",
      server: "68.183.18.95",
      port: 12050,
      uuid: "9f6ebdbe-2224-4094-a7c5-edc620a966b4",
      encryption: "",
      tls: true,
      servername: "www.amd.com",
      flow: "xtls-rprx-vision",
      "client-fingerprint": "chrome",
      "reality-opts": {
        "public-key": "ckruM6FelHaT23bL4LnT9-gBANGkrnbCuexpxJlfK1c",
        "short-id": "8e9f0e0d6fccc6"
      },
      network: "tcp"
    },
    {
      name: "GCP200G",
      type: "vless",
      server: "35.209.140.15",
      port: 443,
      uuid: "6f614bf8-6d36-4803-a8f2-3833f87464a1",
      encryption: "",
      tls: true,
      servername: "www.intel.com",
      flow: "xtls-rprx-vision",
      "client-fingerprint": "chrome",
      "reality-opts": {
        "public-key": "tB9a1_1pLvqKF7QxxSUFJAUY6uJUzGXI-EdeBjl0zVg",
        "short-id": "7474eb"
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

  // 4. 新建目标策略组（包含自建节点）
  const myGoogleGroup = {
    name: "MyGoogle",
    type: "select",
    proxies: [...customProxyNames],
    // proxies: [...customProxyNames, ...googleCandidates],
  };

  const claudeGroup = {
    name: "Claude",
    type: "select",
    proxies: [customProxyNames[1]],
  };

  const customGroup = {
    name: "Custom",
    type: "select",
    proxies: [...customProxyNames],
    // proxies: [...customProxyNames, ...customCandidates],
  };

  // 直接将新组插到前面（不清理任何原有的组）
  config["proxy-groups"].unshift(myGoogleGroup, claudeGroup, customGroup);

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

  const customRules = [
    "DOMAIN-SUFFIX,bygcloud.com,Custom",
    "DOMAIN-SUFFIX,lxtrd.cn.com,Custom",
    "DOMAIN-SUFFIX,anzo-asset.com,Custom"
  ];

  const priorityRules = [...customRules, ...claudeRules, ...myGoogleRules];

  // 6. 将自定义规则优先级提升至最顶端，原规则置后
  config.rules = [
    ...priorityRules,
    ...config.rules.filter(
      (rule) => !priorityRules.some((r) => r.trim().toLowerCase() === rule.trim().toLowerCase())
    )
  ];

  return config;
}
