function main(config, profileName) {
  if (!Array.isArray(config["proxy-groups"])) config["proxy-groups"] = [];
  if (!Array.isArray(config.rules)) config.rules = [];

  const allProxyNames = Array.isArray(config.proxies)
    ? config.proxies.map((p) => p?.name).filter(Boolean)
    : [];

  const sgOrUsPattern = /(🇸🇬|新加坡|狮城|singapore|\bsg\b|🇺🇸|美国|硅谷|united states|\busa\b|\bus\b)/i;
  const claudePattern = /(🇺🇸|美国|硅谷|united states|\busa\b|\bus\b|🇸🇬|新加坡|狮城|singapore|\bsg\b)/i;
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

  // 关键修改：过滤掉原订阅中的 Google 组，同时对重复组名去重
  const seenGroupNames = new Set();
  config["proxy-groups"] = config["proxy-groups"].filter((g) => {
    if (
      g?.name === "Google" ||        // 过滤掉原订阅的 Google，由我们重新生成
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

  // 直接将策略组命名为 "Google"，统一承接订阅自带规则 + 自定义规则
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
    proxies: ["Google", "DIRECT"],
  };

  const googleStitchGroup = {
    name: "Google-Stitch",
    type: "url-test",
    url: "http://www.gstatic.com/generate_204",
    interval: 300,
    tolerance: 150,
    proxies: googleCandidates.length > 0 ? [...googleCandidates] : ["DIRECT"],
  };

  const claudeGroup = {
    name: "Claude",
    type: "select",
    proxies: claudeCandidates.length > 0
      ? [...claudeCandidates, "Google", "DIRECT"]
      : ["Google", "DIRECT"],
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
