function main(config, profileName) {
  if (!Array.isArray(config["proxy-groups"])) config["proxy-groups"] = [];
  if (!Array.isArray(config.rules)) config.rules = [];

  const allProxyNames = Array.isArray(config.proxies)
    ? config.proxies.map((p) => p?.name).filter(Boolean)
    : [];

  // 1. 修正正则表达式：将字符串中的双反斜杠统一，防止正则匹配失效
  const sgOrUsPattern = /(🇸🇬|新加坡|狮城|singapore|\bsg\b|🇺🇸|美国|硅谷|united states|\busa\b|\bus\b)/i;
  const claudePattern = /(🇺🇸|美国|硅谷|united states|\busa\b|\bus\b|🇸🇬|新加坡|狮城|singapore|\bsg\b)/i; // 建议加上新加坡，给 Claude 备选
  const hkSgPattern = /(🇭🇰|香港|hong kong|\bhk\b|🇸🇬|新加坡|狮城|singapore|\bsg\b)/i;

  const googleCandidates = [
    ...new Set(allProxyNames.filter((name) => sgOrUsPattern.test(name))),
  ];


  const claudeCandidates = [
    ...new Set(allProxyNames.filter((name) => claudePattern.test(name))),
  ];

  const customCandidates = [
    ...new Set(allProxyNames.filter((name) => hkSgPattern.test(name))),
  ];

  // 彻底清除所有重复的、旧的相关策略组
  const seenGroupNames = new Set();
  config["proxy-groups"] = config["proxy-groups"].filter((g) => {
    if (
      g?.name === "Google" ||
      g?.name === "Google-API" ||
      g?.name === "Google-Stitch" ||
      g?.name === "Google-SG-US" ||
      g?.name === "Claude" || // 加上这行：防止之前的残留导致 Claude 组过滤失败
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

  // 自动选择 Google 节点组
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
    proxies: ["Google-SG-US", "DIRECT"],
  };

  const googleStitchGroup = {
    name: "Google-Stitch",
    type: "url-test",
    url: "http://www.gstatic.com/generate_204",
    interval: 300,
    tolerance: 150,
    proxies: googleCandidates.length > 0 ? [...googleCandidates] : ["DIRECT"],
  };

  // 2. 优化 Claude 组：类型改为 select，并把其它代理组引入作为备选（防止单节点挂掉）
  const claudeGroup = {
    name: "Claude",
    type: "select",
    proxies: claudeCandidates.length > 0
      ? [...claudeCandidates, "Google-SG-US", "DIRECT"]
      : ["Google-SG-US", "DIRECT"],
  };

  const customGroup = {
    name: "Custom",
    type: "url-test",
    url: "http://www.gstatic.com/generate_204",
    interval: 300,
    tolerance: 150,
    proxies: customCandidates.length > 0 ? [...customCandidates] : ["DIRECT"],
  };

  config["proxy-groups"].unshift(googleStitchGroup);
  config["proxy-groups"].unshift(googleApiGroup);
  config["proxy-groups"].unshift(googleGroup);
  config["proxy-groups"].unshift(claudeGroup);
  config["proxy-groups"].unshift(customGroup);

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

  // 3. 增强 Claude 规则拦截面
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

  // 4. 精准过滤旧规则：防止原配置规则中存在空格或大小写不一致导致未去重
  config.rules = [...allRules, ...config.rules.filter((rule) => {
    return !allRules.some(r => r.trim().toLowerCase() === rule.trim().toLowerCase());
  })];

  return config;
}
