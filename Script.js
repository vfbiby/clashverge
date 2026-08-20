function main(config, profileName) {
  if (!Array.isArray(config.proxies)) config.proxies = [];
  if (!Array.isArray(config["proxy-groups"])) config["proxy-groups"] = [];
  if (!Array.isArray(config.rules)) config.rules = [];

  // 1. 注入自建节点
  const myCustomProxies = [
  {
    "name": "🇺🇸 USA_Los_LAX-DC2 xtls-reality",
    "type": "vless",
    "server": "154.53.75.226",
    "port": 8881,
    "uuid": "decf85cf-9aca-4328-a071-3837631098eb",
    "encryption": "",
    "tls": true,
    "servername": "addons.mozilla.org",
    "flow": "xtls-rprx-vision",
    "client-fingerprint": "chrome",
    "reality-opts": {
      "public-key": "XLY4_lSmUIrs53Ae2LYqpjEWKM7HuAvtOE5t2JNM83c"
    },
    "network": "tcp"
  },
  {
    "name": "anytls-8443",
    "type": "anytls",
    "server": "154.53.75.226",
    "port": 8443,
    "password": "7c62cf6b-1bb1-48f5-b308-761c09ac072e",
    "sni": "anytls.node10.local",
    "skip-cert-verify": true,
    "udp": true
  }
];
  myCustomProxies.forEach((p) => {
    const idx = config.proxies.findIndex((existing) => existing.name === p.name);
    if (idx >= 0) config.proxies[idx] = p;
    else config.proxies.unshift(p);
  });

  // 2. 注入自定义策略组
  const customGroups = [
  {
    "name": "Claude",
    "type": "select",
    "proxies": [
      "🇺🇸 USA_Los_LAX-DC2 xtls-reality",
      "anytls-8443"
    ]
  },
  {
    "name": "MyGoogle",
    "type": "select",
    "proxies": [
      "🇺🇸 USA_Los_LAX-DC2 xtls-reality",
      "anytls-8443",
      "🚀 节点选择"
    ]
  },
  {
    "name": "Custom",
    "type": "select",
    "proxies": [
      "🇺🇸 USA_Los_LAX-DC2 xtls-reality",
      "anytls-8443"
    ]
  },
  {
    "name": "CustomDirect",
    "type": "select",
    "proxies": [
      "DIRECT"
    ]
  }
];
  const customGroupNames = customGroups.map((g) => g.name);
  config["proxy-groups"] = config["proxy-groups"].filter((g) => !customGroupNames.includes(g.name));
  config["proxy-groups"].unshift(...customGroups);

  // 3. 注入自定义分流规则（置顶优先匹配）
  const priorityRules = [
  "DOMAIN-SUFFIX,node10.de5.net,Custom",
  "DOMAIN-SUFFIX,muskzhang.ccwu.cc,Custom",
  "DOMAIN-SUFFIX,deepseek.com,CustomDirect",
  "DOMAIN-SUFFIX,qianwenai.com,CustomDirect",
  "DOMAIN-SUFFIX,volces.com,CustomDirect",
  "DOMAIN-SUFFIX,bygcloud.com,Custom",
  "DOMAIN-SUFFIX,lxtrd.cn.com,Custom",
  "DOMAIN-SUFFIX,rtoc.cc,Custom",
  "DOMAIN-SUFFIX,mtapi.io,Custom",
  "DOMAIN-SUFFIX,anzo-asset.com,Custom",
  "DOMAIN-SUFFIX,lirunexcn.com,Custom",
  "DOMAIN-SUFFIX,166268.xyz,Custom",
  "DOMAIN-SUFFIX,axelprivatemarket.com,Custom",
  "DOMAIN-SUFFIX,axpmprime.com,Custom",
  "DOMAIN-SUFFIX,claude.ai,Claude",
  "DOMAIN-SUFFIX,claude.com,Claude",
  "DOMAIN-SUFFIX,clau.de,Claude",
  "DOMAIN-SUFFIX,anthropic.com,Claude",
  "DOMAIN-SUFFIX,claudeusercontent.com,Claude",
  "DOMAIN,accounts.google.com,MyGoogle",
  "DOMAIN-SUFFIX,recaptcha.net,MyGoogle",
  "DOMAIN,ai.google.dev,MyGoogle",
  "DOMAIN,generativelanguage.googleapis.com,MyGoogle",
  "DOMAIN,stitch.withgoogle.com,MyGoogle",
  "DOMAIN-SUFFIX,stitch.googleapis.com,MyGoogle",
  "DOMAIN-SUFFIX,gstatic.com,MyGoogle",
  "DOMAIN-SUFFIX,googleusercontent.com,MyGoogle",
  "DOMAIN-SUFFIX,googleapis.com,MyGoogle",
  "DOMAIN-SUFFIX,cloudfunctions.net,MyGoogle",
  "DOMAIN-SUFFIX,appspot.com,MyGoogle",
  "DOMAIN-SUFFIX,run.app,MyGoogle",
  "DOMAIN-SUFFIX,firebaseio.com,MyGoogle",
  "DOMAIN-SUFFIX,google-analytics.com,MyGoogle",
  "DOMAIN-SUFFIX,googletagmanager.com,MyGoogle",
  "DOMAIN-SUFFIX,google.com,MyGoogle",
  "DOMAIN-KEYWORD,google,MyGoogle"
];
  config.rules = [
    ...priorityRules,
    ...config.rules.filter(
      (rule) => !priorityRules.some((r) => r.trim().toLowerCase() === rule.trim().toLowerCase())
    )
  ];

  return config;
}
