function main(config, profileName) {
  if (!Array.isArray(config.proxies)) config.proxies = [];
  if (!Array.isArray(config["proxy-groups"])) config["proxy-groups"] = [];
  if (!Array.isArray(config.rules)) config.rules = [];
  
  // 1. 定义你的自定义节点对象
  const customProxy = {
    name: "谷歌云-Xray-Reality",
    type: "vless",
    server: "35.209.140.15",
    port: 443,
    uuid: "93b6b57e-3890-4947-804b-1dc09aa5e226",
    udp: true,
    tls: true,
    flow: "xtls-rprx-vision",
    servername: "swdist.apple.com",
    "reality-opts": {
      "public-key": "f4QB7sjLvh62S8nYCMKjk2qZ6aXXp3fWjk52miQO3nI",
      "short-id": "40cc9a03cdda1002"
    },
    "client-fingerprint": "chrome"
  };

  // 2. 将节点塞入配置列表最顶部（内核路由必须注册该节点才能生效）
  if (!config.proxies.some(p => p.name === customProxy.name)) {
    config.proxies.unshift(customProxy);
  }

  // 3. 提取其他所有节点名称（特意过滤掉“谷歌云-Xray-Reality”，防止它进入其他任何策略组）
  const allProxyNames = config.proxies
    .map((p) => p?.name)
    .filter((name) => Boolean(name) && name !== customProxy.name);

  const sgOrUsPattern = /(🇸🇬|新加坡|狮城|singapore|\bsg\b|🇺🇸|美国|硅谷|united states|\busa\b|\bus\b)/i;
  const hkSgPattern = /(🇭🇰|香港|hong kong|\bhk\b|🇸🇬|新加坡|狮城|singapore|\bsg\b)/i;

  const googleCandidates = [
    ...new Set(allProxyNames.filter((name) => sgOrUsPattern.test(name))),
  ];

  const customCandidates = [
    ...new Set(allProxyNames.filter((name) => hkSgPattern.test(name))),
  ];

  // 清理旧有的/冲突的策略组
  const seenGroupNames = new Set();
  config["proxy-groups"] = config["proxy-groups"].filter((g) => {
    if (
      g?.name === "Google" ||
      g?.name === "Google-API" ||
      g?.name === "Google-Stitch" ||
      g?.name === "Google-SG-US" ||
      g?.name === "Claude" ||
      g?.name === "Custom"
    ) {
      return false;
    }
    if (seenGroupNames.has(g?.name)) {
      return false;
    }
    seenGroupNames.add(g?.name);
    return true;
  });

  // 如果原订阅本身自带“节点选择”、“漏网之鱼”或“GLOBAL”等全量策略组，也把自定义节点剔除掉
  config["proxy-groups"].forEach((group) => {
    if (Array.isArray(group.proxies)) {
      group.proxies = group.proxies.filter((p) => p !== customProxy.name);
    }
  });

  const googleGroup = {
    name: "Google",
    type: "url-test",
    url: "http://www.gstatic.com/generate_204",
    interval: 300,
    tolerance: 150,
    proxies: googleCandidates.length > 0 ? [...googleCandidates] : ["DIRECT"],
  };

  const googleApiGroup = {
    name: "Google-API",
    type: "select",
    proxies: googleCandidates.length > 0 ? [...googleCandidates] : ["DIRECT"],
  };

  const googleStitchGroup = {
    name: "Google-Stitch",
    type: "url-test",
    url: "http://www.gstatic.com/generate_204",
    interval: 300,
    tolerance: 150,
    proxies: googleCandidates.length > 0 ? [...googleCandidates] : ["DIRECT"],
  };

  // 4. 专属 Claude 策略组（独占该节点）
  const claudeGroup = {
    name: "Claude",
    type: "select",
    proxies: [customProxy.name],
  };

  const customGroup = {
    name: "Custom",
    type: "url-test",
    url: "http://www.gstatic.com/generate_204",
    interval: 300,
    tolerance: 150,
    proxies: customCandidates.length > 0 ? [...customCandidates] : ["DIRECT"],
  };

  config["proxy-groups"].unshift(
    customGroup,
    claudeGroup,
    googleStitchGroup,
    googleApiGroup,
    googleGroup
  );

  const googleApiRules = [
    "DOMAIN-SUFFIX,googleapis.com,Google-API",
    "DOMAIN-SUFFIX,google-analytics.com,Google-API",
    "DOMAIN-SUFFIX,googletagmanager.com,Google-API",
    "DOMAIN-SUFFIX,firebaseio.com,Google-API",
    "DOMAIN-SUFFIX,recaptcha.net,Google-API",
    "DOMAIN-SUFFIX,gstatic.com,Google-API",
    "DOMAIN-SUFFIX,cloudfunctions.net,Google-API",
    "DOMAIN-SUFFIX,appspot.com,Google-API",
    "DOMAIN-SUFFIX,run.app,Google-API",
    "DOMAIN-SUFFIX,googleusercontent.com,Google-API",
    "DOMAIN,ai.google.dev,Google-API",
    "DOMAIN,generativelanguage.googleapis.com,Google-API",
  ];

  const googleStitchRules = [
    "DOMAIN,stitch.withgoogle.com,Google-Stitch",
    "DOMAIN-SUFFIX,stitch.googleapis.com,Google-Stitch",
    "DOMAIN,accounts.google.com,Google-Stitch",
  ];

  const claudeRules = [
    "DOMAIN-SUFFIX,claude.ai,Claude",
    "DOMAIN-SUFFIX,claude.com,Claude",
    "DOMAIN-SUFFIX,clau.de,Claude",
    "DOMAIN-SUFFIX,anthropic.com,Claude",
    "DOMAIN-SUFFIX,claudeusercontent.com,Claude",
  ];

  const customRules = [
    "DOMAIN-SUFFIX,bygcloud.com,Custom",
  ];

  const allRules = [...customRules, ...claudeRules, ...googleStitchRules, ...googleApiRules];

  config.rules = [...allRules, ...config.rules.filter((rule) => {
    return !allRules.some(r => r.trim().toLowerCase() === rule.trim().toLowerCase());
  })];

  return config;
}
