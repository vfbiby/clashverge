function main(config, profileName) {
  if (!Array.isArray(config["proxy-groups"])) config["proxy-groups"] = [];
  if (!Array.isArray(config.rules)) config.rules = [];

  const allProxyNames = Array.isArray(config.proxies)
    ? config.proxies.map((p) => p?.name).filter(Boolean)
    : [];

  const sgOrUsPattern =
    /(🇸🇬|新加坡|狮城|singapore|\\bsg\\b|🇺🇸|美国|硅谷|united states|\\busa\\b|\\bus\\b)/i;

  const claudePattern =
    /(🇺🇸|美国|硅谷|united states|\busa\b|\bus\b)/i;

  const hkSgPattern =
    /(🇭🇰|香港|hong kong|\bhk\b|🇸🇬|新加坡|狮城|singapore|\bsg\b)/i;

  const googleCandidates = [
    ...new Set(allProxyNames.filter((name) => sgOrUsPattern.test(name))),
  ];

  const claudeCandidates = [
    ...new Set(allProxyNames.filter((name) => claudePattern.test(name))),
  ];

  const customCandidates = [
    ...new Set(allProxyNames.filter((name) => hkSgPattern.test(name))),
  ];

  // 先彻底清除所有重复的 Google 相关组（包括订阅中的）
  const seenGroupNames = new Set();
  config["proxy-groups"] = config["proxy-groups"].filter((g) => {
    if (
      g?.name === "Google" ||
      g?.name === "Google-API" ||
      g?.name === "Google-Stitch" ||
      g?.name === "Google-SG-US" ||
      g?.name === "Custom"
    ) {
      return false; // 删除所有旧的 Google 相关组
    }
    if (seenGroupNames.has(g?.name)) {
      return false; // 删除其他重复的组
    }
    seenGroupNames.add(g?.name);
    return true;
  });

  // 自动选择 Google 节点组（新加坡/美国节点），url-test 自动测延迟选最快的
  const googleGroup = {
    name: "Google-SG-US",
    type: "url-test",
    url: "http://www.gstatic.com/generate_204",
    interval: 300,
    tolerance: 150,
    proxies: googleCandidates.length > 0 ? [...googleCandidates] : ["DIRECT"],
  };

  // Google-API 走 Google-SG-US 组（保持 select，因为只需要选组不需要测速）
  const googleApiGroup = {
    name: "Google-API",
    type: "select",
    proxies: ["Google-SG-US", "DIRECT"],
  };

  // Google Stitch 自动选择代理组
  const googleStitchGroup = {
    name: "Google-Stitch",
    type: "url-test",
    url: "http://www.gstatic.com/generate_204",
    interval: 300,
    tolerance: 150,
    proxies: googleCandidates.length > 0 ? [...googleCandidates] : ["DIRECT"],
  };

  // Claude 手动选择代理组
  const claudeGroup = {
    name: "Claude",
    type: "select",
    proxies: claudeCandidates.length > 0 ? [...claudeCandidates] : ["DIRECT"],
  };

  // Custom 自动选择代理组（香港/新加坡节点）
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
  const oldRules = config.rules.filter((rule) => !allRules.includes(rule));
  config.rules = [...allRules, ...oldRules];

  return config;
}
