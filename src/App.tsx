import { createSignal, createMemo, onMount, For, Show } from 'solid-js';

interface ProxyItem {
  name: string;
  type?: string;
  server?: string;
  port?: number;
  uuid?: string;
  servername?: string;
  flow?: string;
  cipher?: string;
  password?: string;
  tls?: boolean;
  'reality-opts'?: { 'public-key'?: string };
}

interface GroupItem {
  name: string;
  type: string;
  proxies: string[];
}

interface SubscriptionGroup {
  name: string;
  type: string;
  now?: string;
  all?: string[];
}

export default function App() {
  const [activeTab, setActiveTab] = createSignal<'groups' | 'rules' | 'proxies'>('groups');
  const [loading, setLoading] = createSignal(false);
  const [saving, setSaving] = createSignal(false);
  const [isDirty, setIsDirty] = createSignal(false);

  // Core Data
  const [base, setBase] = createSignal<any>({});
  const [proxies, setProxies] = createSignal<ProxyItem[]>([]);
  const [groups, setGroups] = createSignal<GroupItem[]>([]);
  const [rules, setRules] = createSignal<string[]>([]);
  const [subscriptionProxies, setSubscriptionProxies] = createSignal<{ name: string; type?: string; delay?: number }[]>([]);
  const [subscriptionGroups, setSubscriptionGroups] = createSignal<SubscriptionGroup[]>([]);

  // Latency Testing Map: { [proxyName]: delayInMs }
  const [delays, setDelays] = createSignal<Record<string, number>>({});
  const [testingDelay, setTestingDelay] = createSignal<Record<string, boolean>>({});

  // Search & Filters for Rules
  const [searchQuery, setSearchQuery] = createSignal('');
  const [filterType, setFilterType] = createSignal('');
  const [filterGroup, setFilterGroup] = createSignal('');

  // Node Selector Modal State
  const [nodeModalOpen, setNodeModalOpen] = createSignal(false);
  const [currentGroupIndex, setCurrentGroupIndex] = createSignal(-1);
  const [selectedNodes, setSelectedNodes] = createSignal<string[]>([]);
  const [nodeSearchQuery, setNodeSearchQuery] = createSignal('');
  const [nodeRegionFilter, setNodeRegionFilter] = createSignal('ALL');

  // Proxy Edit / Import Modal State
  const [proxyModalOpen, setProxyModalOpen] = createSignal(false);
  const [editingProxyIndex, setEditingProxyIndex] = createSignal(-1);
  const [proxyForm, setProxyForm] = createSignal<any>({ name: '', type: 'vless', server: '', port: 443, uuid: '', servername: '', flow: 'xtls-rprx-vision', publicKey: '', cipher: 'aes-128-gcm', password: '' });
  const [importModalOpen, setImportModalOpen] = createSignal(false);
  const [linkToImport, setLinkToImport] = createSignal('');

  // Group Edit Modal State
  const [groupModalOpen, setGroupModalOpen] = createSignal(false);
  const [editingGroupIndex, setEditingGroupIndex] = createSignal(-1);
  const [groupForm, setGroupForm] = createSignal({ name: '', type: 'select' });

  // Rule Edit Modal State
  const [ruleModalOpen, setRuleModalOpen] = createSignal(false);
  const [editingRuleIndex, setEditingRuleIndex] = createSignal(-1);
  const [ruleForm, setRuleForm] = createSignal({ type: 'DOMAIN-SUFFIX', payload: '', target: 'Custom' });

  // Toast notification
  const [toast, setToast] = createSignal<{ show: boolean; message: string; type: 'success' | 'error' }>({ show: false, message: '', type: 'success' });
  const showToast = (message: string, type: 'success' | 'error' = 'success') => {
    setToast({ show: true, message, type });
    setTimeout(() => setToast({ show: false, message: '', type: 'success' }), 4000);
  };

  // Group options for dropdowns
  const groupOptions = createMemo(() => {
    const customNames = groups().map(g => g.name);
    return [...customNames, 'DIRECT', 'REJECT', 'Proxies'];
  });

  // Current Selecting Group Name
  const currentGroupName = createMemo(() => {
    const idx = currentGroupIndex();
    if (idx >= 0 && groups()[idx]) return groups()[idx].name;
    return '';
  });

  // All known valid node names in current runtime
  const allKnownNodeNames = createMemo(() => {
    const set = new Set<string>();
    set.add('DIRECT');
    set.add('REJECT');
    proxies().forEach(p => set.add(p.name));
    subscriptionGroups().forEach(g => set.add(g.name));
    subscriptionProxies().forEach(p => set.add(p.name));
    return set;
  });

  // Check if a node is orphan / missing in current subscription
  const isNodeMissing = (name: string) => {
    return !allKnownNodeNames().has(name);
  };

  // Orphaned nodes in currently selected modal
  const missingSelectedNodes = createMemo(() => {
    return selectedNodes().filter(name => isNodeMissing(name));
  });

  // Rules Parsing
  const parsedRules = createMemo(() => {
    return rules().map((r, rawIndex) => {
      const parts = r.split(',').map(s => s.trim());
      return {
        rawIndex,
        raw: r,
        type: parts[0] || 'DOMAIN-SUFFIX',
        payload: parts[1] || '',
        target: parts[2] || 'Custom',
      };
    });
  });

  const filteredRules = createMemo(() => {
    const q = searchQuery().toLowerCase().trim();
    const fType = filterType();
    const fGroup = filterGroup();

    return parsedRules().filter(r => {
      const matchQuery = !q || r.payload.toLowerCase().includes(q) || r.type.toLowerCase().includes(q) || r.target.toLowerCase().includes(q);
      const matchType = !fType || r.type === fType;
      const matchGroup = !fGroup || r.target === fGroup;
      return matchQuery && matchType && matchGroup;
    });
  });

  // Load configuration and live subscription data
  const loadData = async () => {
    setLoading(true);
    try {
      const res = await fetch('/api/custom-config');
      const data = await res.json();
      setBase(data.base || {});
      setProxies(data.proxies || []);
      setGroups(data.groups || []);
      setRules(data.rules || []);

      // Load live subscription proxies and groups
      try {
        const liveRes = await fetch('/api/live-proxies');
        const liveData = await liveRes.json();
        setSubscriptionProxies(liveData.subscriptionProxies || []);
        setSubscriptionGroups(liveData.subscriptionGroups || []);

        const delayMap: Record<string, number> = {};
        (liveData.subscriptionProxies || []).forEach((p: any) => {
          if (p.delay) delayMap[p.name] = p.delay;
        });
        setDelays(prev => ({ ...prev, ...delayMap }));
      } catch (_) {}

      setIsDirty(false);
    } catch (err: any) {
      showToast('加载数据失败: ' + err.message, 'error');
    } finally {
      setLoading(false);
    }
  };

  const saveConfig = async () => {
    setSaving(true);
    try {
      const payload = {
        base: base(),
        proxies: proxies(),
        groups: groups(),
        rules: rules(),
      };
      const res = await fetch('/api/custom-config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const result = await res.json();
      if (result.success) {
        setIsDirty(false);
        showToast('🎉 配置已成功保存并实时热生效！');
      } else {
        throw new Error(result.error || '保存失败');
      }
    } catch (err: any) {
      showToast('保存失败: ' + err.message, 'error');
    } finally {
      setSaving(false);
    }
  };

  // Latency Testing - ONLY tests the specified nodes
  const testNodeDelay = async (nodeNames: string[]) => {
    if (!nodeNames || nodeNames.length === 0) return;
    const filterValid = nodeNames.filter(n => n !== 'DIRECT' && n !== 'REJECT');
    if (filterValid.length === 0) return;

    setTestingDelay(prev => {
      const next = { ...prev };
      filterValid.forEach(n => next[n] = true);
      return next;
    });

    try {
      const res = await fetch('/api/test-delay', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ proxies: filterValid }),
      });
      const data = await res.json();
      if (data.results) {
        setDelays(prev => ({ ...prev, ...data.results }));
        showToast(`已完成 ${filterValid.length} 个节点的延迟测试`);
      }
    } catch (err: any) {
      showToast('测速请求失败: ' + err.message, 'error');
    } finally {
      setTestingDelay(prev => {
        const next = { ...prev };
        filterValid.forEach(n => delete next[n]);
        return next;
      });
    }
  };

  const testGroupDelay = (groupIndex: number) => {
    const g = groups()[groupIndex];
    if (g && g.proxies && g.proxies.length > 0) {
      testNodeDelay(g.proxies);
    }
  };

  const renderDelayBadge = (name: string) => {
    const isTesting = testingDelay()[name];
    const delay = delays()[name];

    if (isTesting) {
      return <span class="text-[10px] px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 animate-pulse font-mono flex items-center gap-1"><i class="fa-solid fa-spinner fa-spin"></i> 测速中</span>;
    }
    if (delay === undefined) return null;
    if (delay <= 0) {
      return <span class="text-[10px] px-1.5 py-0.5 rounded bg-rose-500/20 text-rose-400 font-mono">超时</span>;
    }
    if (delay < 200) {
      return <span class="text-[10px] px-1.5 py-0.5 rounded bg-emerald-500/20 text-emerald-400 font-mono">{delay}ms</span>;
    }
    if (delay < 450) {
      return <span class="text-[10px] px-1.5 py-0.5 rounded bg-amber-500/20 text-amber-400 font-mono">{delay}ms</span>;
    }
    return <span class="text-[10px] px-1.5 py-0.5 rounded bg-rose-500/20 text-rose-400 font-mono">{delay}ms</span>;
  };

  // Node Filter in Modal
  const isRegionMatch = (name: string, region: string) => {
    const n = name.toLowerCase();
    switch (region) {
      case 'HK': return n.includes('hk') || n.includes('hong kong') || n.includes('香港');
      case 'JP': return n.includes('jp') || n.includes('japan') || n.includes('日本') || n.includes('东京');
      case 'SG': return n.includes('sg') || n.includes('singapore') || n.includes('狮城') || n.includes('新加坡');
      case 'US': return n.includes('us') || n.includes('united states') || n.includes('美国') || n.includes('洛杉矶') || n.includes('硅谷');
      default: return true;
    }
  };

  const filteredSubscriptionNodes = createMemo(() => {
    const q = nodeSearchQuery().toLowerCase().trim();
    const region = nodeRegionFilter();

    return subscriptionProxies().filter(p => {
      const matchQuery = !q || p.name.toLowerCase().includes(q);
      const matchRegion = region === 'ALL' || isRegionMatch(p.name, region);
      return matchQuery && matchRegion;
    });
  });

  const filteredSubscriptionGroups = createMemo(() => {
    const q = nodeSearchQuery().toLowerCase().trim();
    return subscriptionGroups().filter(g => !q || g.name.toLowerCase().includes(q));
  });

  const filteredCustomProxies = createMemo(() => {
    const q = nodeSearchQuery().toLowerCase().trim();
    return proxies().filter(p => !q || p.name.toLowerCase().includes(q));
  });

  // Modal Handlers for Node Selector
  const openGroupNodeSelector = (index: number) => {
    setCurrentGroupIndex(index);
    setSelectedNodes([...(groups()[index]?.proxies || [])]);
    setNodeSearchQuery('');
    setNodeRegionFilter('ALL');
    setNodeModalOpen(true);
  };

  const toggleNodeSelection = (name: string) => {
    const current = selectedNodes();
    if (current.includes(name)) {
      setSelectedNodes(current.filter(n => n !== name));
    } else {
      setSelectedNodes([...current, name]);
    }
  };

  const removeNodeFromCurrentGroup = (nodeName: string) => {
    setSelectedNodes(selectedNodes().filter(n => n !== nodeName));
  };

  // Clean all missing/orphaned nodes from current modal selection
  const clearMissingNodes = () => {
    const missing = new Set(missingSelectedNodes());
    setSelectedNodes(selectedNodes().filter(n => !missing.has(n)));
    showToast(`已一键清除所有当前不可用的失效节点/组`);
  };

  const saveGroupNodes = () => {
    const idx = currentGroupIndex();
    if (idx >= 0) {
      const next = [...groups()];
      next[idx] = { ...next[idx], proxies: [...selectedNodes()] };
      setGroups(next);
      setIsDirty(true);
    }
    setNodeModalOpen(false);
  };

  const toggleSelectAllFiltered = () => {
    const current = new Set(selectedNodes());
    const visibleNames = [
      ...filteredCustomProxies().map(p => p.name),
      ...filteredSubscriptionGroups().map(g => g.name),
      ...filteredSubscriptionNodes().map(p => p.name),
    ];

    const allSelected = visibleNames.every(name => current.has(name));
    if (allSelected) {
      visibleNames.forEach(name => current.delete(name));
    } else {
      visibleNames.forEach(name => current.add(name));
    }
    setSelectedNodes(Array.from(current));
  };

  // Proxy Handlers
  const openImportModal = () => {
    setLinkToImport('');
    setImportModalOpen(true);
  };

  const parseAndAddLink = async () => {
    try {
      const res = await fetch('/api/parse-link', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ link: linkToImport() }),
      });
      const data = await res.json();
      if (data.success && data.proxy) {
        setProxies([...proxies(), data.proxy]);
        setIsDirty(true);
        setImportModalOpen(false);
        showToast(`已成功导入节点: ${data.proxy.name}`);
      } else {
        throw new Error(data.error || '解析失败');
      }
    } catch (err: any) {
      showToast(err.message, 'error');
    }
  };

  const openAddProxy = () => {
    setEditingProxyIndex(-1);
    setProxyForm({ name: '', type: 'vless', server: '', port: 443, uuid: '', servername: '', flow: 'xtls-rprx-vision', publicKey: '', cipher: 'aes-128-gcm', password: '' });
    setProxyModalOpen(true);
  };

  const editProxy = (index: number) => {
    setEditingProxyIndex(index);
    const p = proxies()[index];
    setProxyForm({
      name: p.name,
      type: p.type || 'vless',
      server: p.server || '',
      port: p.port || 443,
      uuid: p.uuid || '',
      servername: p.servername || '',
      flow: p.flow || '',
      publicKey: p['reality-opts']?.['public-key'] || '',
      cipher: p.cipher || '',
      password: p.password || '',
    });
    setProxyModalOpen(true);
  };

  const saveProxyForm = () => {
    const f = proxyForm();
    if (!f.name || !f.server) {
      showToast('请填写节点名称和服务器地址', 'error');
      return;
    }
    const p: any = {
      name: f.name,
      type: f.type,
      server: f.server,
      port: Number(f.port) || 443,
    };
    if (f.type === 'vless') {
      p.uuid = f.uuid;
      p.encryption = '';
      p.tls = true;
      p.servername = f.servername;
      p.flow = f.flow || undefined;
      p['client-fingerprint'] = 'chrome';
      p.network = 'tcp';
      if (f.publicKey) {
        p['reality-opts'] = { 'public-key': f.publicKey };
      }
    } else if (f.type === 'ss') {
      p.cipher = f.cipher;
      p.password = f.password;
    }
    const idx = editingProxyIndex();
    if (idx === -1) {
      setProxies([...proxies(), p]);
    } else {
      const next = [...proxies()];
      next[idx] = p;
      setProxies(next);
    }
    setIsDirty(true);
    setProxyModalOpen(false);
  };

  const removeProxy = (index: number) => {
    if (confirm(`确定删除自建节点 "${proxies()[index].name}" 吗？`)) {
      setProxies(proxies().filter((_, i) => i !== index));
      setIsDirty(true);
    }
  };

  // Group Handlers
  const openAddGroup = () => {
    setEditingGroupIndex(-1);
    setGroupForm({ name: '', type: 'select' });
    setGroupModalOpen(true);
  };

  const editGroup = (index: number) => {
    setEditingGroupIndex(index);
    setGroupForm({ name: groups()[index].name, type: groups()[index].type || 'select' });
    setGroupModalOpen(true);
  };

  const saveGroupForm = () => {
    const f = groupForm();
    if (!f.name.trim()) return;
    const idx = editingGroupIndex();
    if (idx === -1) {
      setGroups([...groups(), { name: f.name.trim(), type: f.type, proxies: ['DIRECT'] }]);
    } else {
      const next = [...groups()];
      next[idx] = { ...next[idx], name: f.name.trim(), type: f.type };
      setGroups(next);
    }
    setIsDirty(true);
    setGroupModalOpen(false);
  };

  const removeGroup = (index: number) => {
    if (confirm(`确定删除策略组 "${groups()[index].name}" 吗？`)) {
      setGroups(groups().filter((_, i) => i !== index));
      setIsDirty(true);
    }
  };

  // Rule Handlers
  const openAddRule = () => {
    setEditingRuleIndex(-1);
    setRuleForm({ type: 'DOMAIN-SUFFIX', payload: '', target: groups()[0]?.name || 'Custom' });
    setRuleModalOpen(true);
  };

  const editRule = (rawIndex: number) => {
    setEditingRuleIndex(rawIndex);
    const parsed = parsedRules()[rawIndex];
    setRuleForm({ type: parsed.type, payload: parsed.payload, target: parsed.target });
    setRuleModalOpen(true);
  };

  const saveRuleForm = () => {
    const f = ruleForm();
    if (!f.payload.trim()) {
      showToast('请填写匹配目标 (域名/IP)', 'error');
      return;
    }
    const ruleStr = `${f.type},${f.payload.trim()},${f.target}`;
    const idx = editingRuleIndex();
    if (idx === -1) {
      setRules([ruleStr, ...rules()]);
    } else {
      const next = [...rules()];
      next[idx] = ruleStr;
      setRules(next);
    }
    setIsDirty(true);
    setRuleModalOpen(false);
  };

  const updateRuleTarget = (rawIndex: number, newTarget: string) => {
    const parsed = parsedRules()[rawIndex];
    const next = [...rules()];
    next[rawIndex] = `${parsed.type},${parsed.payload},${newTarget}`;
    setRules(next);
    setIsDirty(true);
  };

  const removeRule = (rawIndex: number) => {
    setRules(rules().filter((_, i) => i !== rawIndex));
    setIsDirty(true);
  };

  const moveRule = (rawIndex: number, direction: number) => {
    const targetIndex = rawIndex + direction;
    if (targetIndex < 0 || targetIndex >= rules().length) return;
    const next = [...rules()];
    const temp = next[rawIndex];
    next[rawIndex] = next[targetIndex];
    next[targetIndex] = temp;
    setRules(next);
    setIsDirty(true);
  };

  onMount(() => {
    loadData();
  });

  return (
    <div class="flex flex-col min-h-screen">
      {/* 顶部导航 */}
      <header class="border-b border-slate-800 bg-slate-900/90 sticky top-0 z-40 backdrop-blur-md">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between">
          <div class="flex items-center space-x-3">
            <div class="w-9 h-9 rounded-xl bg-gradient-to-tr from-blue-600 to-indigo-500 flex items-center justify-center shadow-lg shadow-blue-500/20">
              <i class="fa-solid fa-bolt text-white text-lg"></i>
            </div>
            <div>
              <h1 class="font-bold text-base sm:text-lg tracking-tight text-white flex items-center gap-2">
                Clash Verge <span class="text-xs px-2 py-0.5 rounded-full bg-blue-500/20 text-blue-400 font-medium border border-blue-500/30">SolidJS 工作台</span>
              </h1>
            </div>
          </div>

          <div class="flex items-center space-x-3">
            <div class="hidden sm:flex items-center text-xs text-slate-400 bg-slate-800/80 px-3 py-1.5 rounded-lg border border-slate-700">
              <span class="w-2 h-2 rounded-full bg-emerald-500 mr-2 animate-pulse"></span>
              核心: <span class="text-slate-200 font-mono ml-1">127.0.0.1:9097</span>
            </div>

            <a href="/dashboard" target="_blank" class="text-xs sm:text-sm px-3 py-1.5 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-300 transition flex items-center gap-1.5 border border-slate-700">
              <i class="fa-solid fa-chart-line text-blue-400"></i>
              <span>监控仪表盘</span>
            </a>

            <button onClick={loadData} disabled={saving()} class="text-xs sm:text-sm px-3 py-1.5 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-300 transition flex items-center gap-1.5 border border-slate-700">
              <i class={`fa-solid fa-rotate text-slate-400 ${loading() ? 'fa-spin' : ''}`}></i>
              <span>刷新</span>
            </button>

            <button onClick={saveConfig} disabled={saving() || !isDirty()}
              class={`text-xs sm:text-sm font-medium px-4 py-1.5 rounded-lg transition flex items-center gap-2 shadow-lg ${
                isDirty() ? 'bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-500 hover:to-indigo-500 text-white shadow-blue-500/20 ring-2 ring-blue-500/50' : 'bg-slate-800 text-slate-500 cursor-not-allowed border border-slate-700'
              }`}>
              <i class={`fa-solid fa-cloud-arrow-up ${saving() ? 'fa-bounce' : ''}`}></i>
              <span>{saving() ? '保存并应用中...' : (isDirty() ? '🚀 保存并热生效' : '已是最新')}</span>
            </button>
          </div>
        </div>
      </header>

      {/* Tab 切换 */}
      <div class="bg-slate-900/40 border-b border-slate-800">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 flex space-x-6">
          <button onClick={() => setActiveTab('groups')}
            class={`py-3.5 text-sm font-medium border-b-2 transition flex items-center gap-2 ${
              activeTab() === 'groups' ? 'border-blue-500 text-blue-400' : 'border-transparent text-slate-400 hover:text-slate-200'
            }`}>
            <i class="fa-solid fa-layer-group"></i>
            <span>1. 代理策略组</span>
            <span class="px-1.5 py-0.5 text-xs rounded-full bg-slate-800 text-slate-400">{groups().length}</span>
          </button>

          <button onClick={() => setActiveTab('rules')}
            class={`py-3.5 text-sm font-medium border-b-2 transition flex items-center gap-2 ${
              activeTab() === 'rules' ? 'border-blue-500 text-blue-400' : 'border-transparent text-slate-400 hover:text-slate-200'
            }`}>
            <i class="fa-solid fa-route"></i>
            <span>2. 域名分流规则</span>
            <span class="px-1.5 py-0.5 text-xs rounded-full bg-slate-800 text-slate-400">{rules().length}</span>
          </button>

          <button onClick={() => setActiveTab('proxies')}
            class={`py-3.5 text-sm font-medium border-b-2 transition flex items-center gap-2 ${
              activeTab() === 'proxies' ? 'border-blue-500 text-blue-400' : 'border-transparent text-slate-400 hover:text-slate-200'
            }`}>
            <i class="fa-solid fa-server"></i>
            <span>3. 自建节点</span>
            <span class="px-1.5 py-0.5 text-xs rounded-full bg-slate-800 text-slate-400">{proxies().length}</span>
          </button>
        </div>
      </div>

      {/* 主体内容 */}
      <main class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6 flex-1 w-full">
        {/* 提示条 */}
        <Show when={toast().show}>
          <div class={`mb-4 p-3 rounded-lg flex items-center justify-between text-sm transition ${
            toast().type === 'success' ? 'bg-emerald-500/10 border border-emerald-500/20 text-emerald-300' : 'bg-rose-500/10 border border-rose-500/20 text-rose-300'
          }`}>
            <div class="flex items-center gap-2">
              <i class={toast().type === 'success' ? 'fa-solid fa-circle-check text-emerald-400' : 'fa-solid fa-circle-exclamation text-rose-400'}></i>
              <span>{toast().message}</span>
            </div>
            <button onClick={() => setToast(prev => ({ ...prev, show: false }))} class="text-xs opacity-70 hover:opacity-100">&times;</button>
          </div>
        </Show>

        {/* ==================== TAB 1: 代理策略组 ==================== */}
        <Show when={activeTab() === 'groups'}>
          <div class="space-y-4">
            <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 bg-slate-800/40 p-4 rounded-xl border border-slate-800">
              <div>
                <h2 class="text-base font-semibold text-white">代理策略组管理</h2>
                <p class="text-xs text-slate-400 mt-0.5">点击策略组上的「⚡ 测速」可仅测试组内的节点；点击「调整节点」可安全增删节点与订阅原生组。</p>
              </div>
              <button onClick={openAddGroup} class="text-xs sm:text-sm px-3 py-2 bg-blue-600/20 hover:bg-blue-600/30 text-blue-300 border border-blue-500/30 rounded-lg transition flex items-center gap-1.5">
                <i class="fa-solid fa-folder-plus"></i>
                <span>新建策略组</span>
              </button>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <For each={groups()}>
                {(g, groupIdx) => (
                  <div class="glass-card p-4 rounded-xl relative group">
                    <div class="flex items-center justify-between mb-3 border-b border-slate-800 pb-3">
                      <div class="flex items-center gap-2">
                        <div class="w-8 h-8 rounded-lg bg-indigo-500/20 text-indigo-400 flex items-center justify-center border border-indigo-500/30">
                          <i class="fa-solid fa-layer-group text-sm"></i>
                        </div>
                        <div>
                          <h3 class="font-medium text-white text-sm sm:text-base">{g.name}</h3>
                          <span class="text-xs text-slate-400 font-mono">类型: {g.type}</span>
                        </div>
                      </div>

                      <div class="flex items-center space-x-1.5">
                        <button onClick={() => testGroupDelay(groupIdx())} class="text-xs px-2.5 py-1 bg-emerald-600/20 hover:bg-emerald-600/30 text-emerald-400 rounded-lg border border-emerald-500/30 transition flex items-center gap-1" title="仅测试该组内包含的节点">
                          <i class="fa-solid fa-bolt"></i>
                          <span>测速 ({g.proxies ? g.proxies.length : 0})</span>
                        </button>
                        <button onClick={() => openGroupNodeSelector(groupIdx())} class="text-xs px-2.5 py-1 bg-slate-800 hover:bg-slate-700 text-blue-400 rounded-lg border border-slate-700 transition flex items-center gap-1">
                          <i class="fa-solid fa-list-check"></i>
                          <span>调整节点</span>
                        </button>
                        <button onClick={() => editGroup(groupIdx())} class="p-1.5 text-slate-400 hover:text-blue-400 rounded-lg hover:bg-slate-800 transition" title="重命名/类型">
                          <i class="fa-solid fa-pen-to-square"></i>
                        </button>
                        <button onClick={() => removeGroup(groupIdx())} class="p-1.5 text-slate-400 hover:text-rose-400 rounded-lg hover:bg-slate-800 transition" title="删除策略组">
                          <i class="fa-solid fa-trash-can"></i>
                        </button>
                      </div>
                    </div>

                    <div class="space-y-1">
                      <div class="text-xs text-slate-400 mb-1.5 flex items-center justify-between">
                        <span>包含的节点 / 策略组:</span>
                      </div>
                      <div class="flex flex-wrap gap-1.5 max-h-36 overflow-y-auto pr-1">
                        <For each={g.proxies || []}>
                          {(node) => {
                            const isCustom = proxies().some(cp => cp.name === node);
                            const isSubGroup = subscriptionGroups().some(sg => sg.name === node);
                            const isSpec = node === 'DIRECT' || node === 'REJECT';
                            const isMissing = isNodeMissing(node);

                            return (
                              <span class={`text-xs px-2 py-0.5 rounded-md flex items-center gap-1.5 border select-none transition ${
                                isMissing ? 'bg-rose-500/20 text-rose-300 border-rose-500/40' :
                                isCustom ? 'bg-emerald-500/15 text-emerald-300 border-emerald-500/30' :
                                isSubGroup ? 'bg-purple-500/15 text-purple-300 border-purple-500/30' :
                                isSpec ? 'bg-amber-500/15 text-amber-300 border-amber-500/30' :
                                'bg-slate-800 text-slate-300 border-slate-700'
                              }`}>
                                <Show when={isMissing}>
                                  <i class="fa-solid fa-triangle-exclamation text-[10px] text-rose-400" title="该节点在当前订阅中不存在"></i>
                                </Show>
                                <Show when={!isMissing && isCustom}>
                                  <i class="fa-solid fa-crown text-[10px] text-emerald-400"></i>
                                </Show>
                                <Show when={!isMissing && isSubGroup}>
                                  <i class="fa-solid fa-diagram-project text-[10px] text-purple-400"></i>
                                </Show>
                                <span>{node}</span>
                                {renderDelayBadge(node)}
                              </span>
                            );
                          }}
                        </For>
                        <Show when={!g.proxies || g.proxies.length === 0}>
                          <span class="text-xs text-slate-500 italic">暂未选择任何节点</span>
                        </Show>
                      </div>
                    </div>
                  </div>
                )}
              </For>
            </div>
          </div>
        </Show>

        {/* ==================== TAB 2: 域名分流规则 ==================== */}
        <Show when={activeTab() === 'rules'}>
          <div class="space-y-4">
            <div class="flex flex-col md:flex-row md:items-center justify-between gap-3 bg-slate-800/40 p-4 rounded-xl border border-slate-800">
              <div class="flex-1 flex flex-col sm:flex-row items-stretch sm:items-center gap-2">
                <div class="relative flex-1">
                  <i class="fa-solid fa-magnifying-glass absolute left-3 top-1/2 -translate-y-1/2 text-slate-400 text-xs"></i>
                  <input
                    value={searchQuery()}
                    onInput={(e) => setSearchQuery(e.currentTarget.value)}
                    type="text"
                    placeholder="模糊搜索域名、关键词或 IP..."
                    class="w-full pl-9 pr-3 py-1.5 text-xs sm:text-sm rounded-lg glass-input"
                  />
                </div>

                <select value={filterType()} onChange={(e) => setFilterType(e.currentTarget.value)} class="text-xs sm:text-sm py-1.5 px-2.5 rounded-lg glass-input">
                  <option value="">全部规则类型</option>
                  <option value="DOMAIN-SUFFIX">DOMAIN-SUFFIX (后缀)</option>
                  <option value="DOMAIN">DOMAIN (完整匹配)</option>
                  <option value="DOMAIN-KEYWORD">DOMAIN-KEYWORD (关键词)</option>
                  <option value="IP-CIDR">IP-CIDR (IP段)</option>
                  <option value="GEOSITE">GEOSITE (域名集)</option>
                  <option value="GEOIP">GEOIP (国家代码)</option>
                </select>

                <select value={filterGroup()} onChange={(e) => setFilterGroup(e.currentTarget.value)} class="text-xs sm:text-sm py-1.5 px-2.5 rounded-lg glass-input">
                  <option value="">全部目标策略组</option>
                  <For each={groupOptions()}>
                    {(opt) => <option value={opt}>{opt}</option>}
                  </For>
                </select>
              </div>

              <button onClick={openAddRule} class="text-xs sm:text-sm px-3 py-2 bg-blue-600/20 hover:bg-blue-600/30 text-blue-300 border border-blue-500/30 rounded-lg transition flex items-center justify-center gap-1.5 whitespace-nowrap">
                <i class="fa-solid fa-plus"></i>
                <span>添加分流规则</span>
              </button>
            </div>

            {/* 规则表格 */}
            <div class="glass-card rounded-xl border border-slate-800 overflow-hidden">
              <div class="overflow-x-auto">
                <table class="w-full text-left text-xs sm:text-sm">
                  <thead class="bg-slate-900/80 text-slate-400 border-b border-slate-800 text-xs font-medium uppercase">
                    <tr>
                      <th class="py-3 px-3 w-12 text-center">排序</th>
                      <th class="py-3 px-3 w-36">规则类型</th>
                      <th class="py-3 px-3">匹配内容 / 域名</th>
                      <th class="py-3 px-3 w-52">目标策略组</th>
                      <th class="py-3 px-3 w-24 text-right">操作</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-slate-800/60">
                    <For each={filteredRules()}>
                      {(r) => (
                        <tr class="hover:bg-slate-800/30 transition">
                          <td class="py-2.5 px-3 text-center text-slate-500">
                            <div class="flex items-center justify-center space-x-1">
                              <button onClick={() => moveRule(r.rawIndex, -1)} disabled={r.rawIndex === 0} class="p-1 hover:text-blue-400 disabled:opacity-20 transition" title="上移">
                                <i class="fa-solid fa-chevron-up text-[10px]"></i>
                              </button>
                              <button onClick={() => moveRule(r.rawIndex, 1)} disabled={r.rawIndex === rules().length - 1} class="p-1 hover:text-blue-400 disabled:opacity-20 transition" title="下移">
                                <i class="fa-solid fa-chevron-down text-[10px]"></i>
                              </button>
                            </div>
                          </td>

                          <td class="py-2.5 px-3">
                            <span class={`px-2 py-0.5 rounded text-xs font-mono font-medium ${
                              r.type === 'DOMAIN-SUFFIX' ? 'bg-blue-500/15 text-blue-400 border border-blue-500/20' :
                              r.type === 'DOMAIN' ? 'bg-purple-500/15 text-purple-400 border border-purple-500/20' :
                              'bg-emerald-500/15 text-emerald-400 border border-emerald-500/20'
                            }`}>
                              {r.type}
                            </span>
                          </td>

                          <td class="py-2.5 px-3 font-mono text-slate-200 break-all">
                            {{ r: r.payload }.r}
                          </td>

                          <td class="py-2.5 px-3">
                            <select
                              value={r.target}
                              onChange={(e) => updateRuleTarget(r.rawIndex, e.currentTarget.value)}
                              class={`text-xs py-1 px-2 rounded-lg glass-input w-full font-medium ${
                                r.target === 'DIRECT' ? 'text-amber-300' :
                                r.target === 'REJECT' ? 'text-rose-300' :
                                'text-indigo-300'
                              }`}>
                              <For each={groupOptions()}>
                                {(opt) => <option value={opt}>{opt}</option>}
                              </For>
                            </select>
                          </td>

                          <td class="py-2.5 px-3 text-right">
                            <div class="flex items-center justify-end space-x-1">
                              <button onClick={() => editRule(r.rawIndex)} class="p-1.5 text-slate-400 hover:text-blue-400 rounded hover:bg-slate-800 transition" title="编辑">
                                <i class="fa-solid fa-pen-to-square"></i>
                              </button>
                              <button onClick={() => removeRule(r.rawIndex)} class="p-1.5 text-slate-400 hover:text-rose-400 rounded hover:bg-slate-800 transition" title="删除">
                                <i class="fa-solid fa-trash-can"></i>
                              </button>
                            </div>
                          </td>
                        </tr>
                      )}
                    </For>

                    <Show when={filteredRules().length === 0}>
                      <tr>
                        <td colspan="5" class="py-12 text-center text-slate-500">
                          没有找到匹配的分流规则
                        </td>
                      </tr>
                    </Show>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </Show>

        {/* ==================== TAB 3: 自建节点 ==================== */}
        <Show when={activeTab() === 'proxies'}>
          <div class="space-y-4">
            <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 bg-slate-800/40 p-4 rounded-xl border border-slate-800">
              <div>
                <h2 class="text-base font-semibold text-white">自建私有节点管理</h2>
                <p class="text-xs text-slate-400 mt-0.5">自建节点会自动注入到配置顶层，可在上方的策略组中直接勾选使用。</p>
              </div>
              <div class="flex items-center space-x-2">
                <button onClick={() => testNodeDelay(proxies().map(p => p.name))} class="text-xs sm:text-sm px-3 py-2 bg-emerald-600/20 hover:bg-emerald-600/30 text-emerald-300 border border-emerald-500/30 rounded-lg transition flex items-center gap-1.5">
                  <i class="fa-solid fa-bolt"></i>
                  <span>一键测速全部自建节点</span>
                </button>
                <button onClick={openImportModal} class="text-xs sm:text-sm px-3 py-2 bg-blue-600/20 hover:bg-blue-600/30 text-blue-300 border border-blue-500/30 rounded-lg transition flex items-center gap-1.5">
                  <i class="fa-solid fa-link"></i>
                  <span>导入节点链接</span>
                </button>
                <button onClick={openAddProxy} class="text-xs sm:text-sm px-3 py-2 bg-slate-800 hover:bg-slate-700 text-slate-200 border border-slate-700 rounded-lg transition flex items-center gap-1.5">
                  <i class="fa-solid fa-plus"></i>
                  <span>手动添加</span>
                </button>
              </div>
            </div>

            <Show when={proxies().length === 0}>
              <div class="text-center py-16 bg-slate-900/40 rounded-2xl border border-slate-800 border-dashed">
                <i class="fa-solid fa-server text-4xl text-slate-600 mb-3"></i>
                <p class="text-slate-400 text-sm">暂无自建节点，点击上方按钮添加或导入</p>
              </div>
            </Show>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <For each={proxies()}>
                {(p, index) => (
                  <div class="glass-card p-4 rounded-xl relative group hover:border-slate-700 transition">
                    <div class="flex items-start justify-between">
                      <div class="flex-1 pr-3">
                        <div class="flex items-center gap-2 flex-wrap">
                          <span class="font-medium text-slate-100 text-sm sm:text-base">{p.name}</span>
                          <span class="px-2 py-0.5 rounded text-xs font-mono uppercase bg-blue-500/20 text-blue-400 border border-blue-500/30">{p.type}</span>
                          {renderDelayBadge(p.name)}
                        </div>
                        <div class="mt-2 text-xs text-slate-400 space-y-1 font-mono">
                          <div>服务器: <span class="text-slate-300">{p.server}:{p.port}</span></div>
                          <Show when={p.servername}>
                            <div>SNI: <span class="text-slate-300">{p.servername}</span></div>
                          </Show>
                          <Show when={p.uuid}>
                            <div>UUID: <span class="text-slate-400">{p.uuid?.slice(0, 8)}...{p.uuid?.slice(-6)}</span></div>
                          </Show>
                        </div>
                      </div>

                      <div class="flex items-center space-x-1 opacity-80 group-hover:opacity-100 transition">
                        <button onClick={() => testNodeDelay([p.name])} class="p-1.5 text-slate-400 hover:text-emerald-400 rounded-lg hover:bg-slate-800 transition" title="单节点测速">
                          <i class="fa-solid fa-bolt text-xs"></i>
                        </button>
                        <button onClick={() => editProxy(index())} class="p-1.5 text-slate-400 hover:text-blue-400 rounded-lg hover:bg-slate-800 transition" title="编辑">
                          <i class="fa-solid fa-pen-to-square text-xs"></i>
                        </button>
                        <button onClick={() => removeProxy(index())} class="p-1.5 text-slate-400 hover:text-rose-400 rounded-lg hover:bg-slate-800 transition" title="删除">
                          <i class="fa-solid fa-trash-can text-xs"></i>
                        </button>
                      </div>
                    </div>
                  </div>
                )}
              </For>
            </div>
          </div>
        </Show>
      </main>

      {/* ==================== 模态框: 调整策略组节点 (支持模糊搜索 + 原生组 + 批量测速 + 已选标签栏) ==================== */}
      <Show when={nodeModalOpen()}>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/70 backdrop-blur-sm">
          <div class="glass-card max-w-3xl w-full p-6 rounded-2xl border border-slate-700 shadow-2xl space-y-4 max-h-[92vh] flex flex-col">
            <div class="flex items-center justify-between border-b border-slate-800 pb-3">
              <div>
                <h3 class="font-semibold text-white text-base">调整策略组节点: <span class="text-indigo-400">{currentGroupName()}</span></h3>
                <p class="text-xs text-slate-400 mt-0.5">支持在此安全移除节点、勾选自建节点、订阅原生组与单节点</p>
              </div>
              <button onClick={() => setNodeModalOpen(false)} class="text-slate-400 hover:text-white text-lg">&times;</button>
            </div>

            {/* 顶栏：当前已选节点标签（安全在此删除） */}
            <div class="bg-slate-900/60 p-3 rounded-xl border border-slate-800 space-y-2">
              <div class="flex items-center justify-between text-xs">
                <span class="text-slate-400">当前已选节点/组 (<b>{selectedNodes().length}</b>):</span>
                <Show when={missingSelectedNodes().length > 0}>
                  <button onClick={clearMissingNodes} class="text-[11px] px-2 py-0.5 rounded bg-rose-500/20 text-rose-300 border border-rose-500/40 hover:bg-rose-500/30 transition flex items-center gap-1">
                    <i class="fa-solid fa-broom"></i>
                    <span>一键清除 {missingSelectedNodes().length} 个失效节点</span>
                  </button>
                </Show>
              </div>

              <div class="flex flex-wrap gap-1.5 max-h-24 overflow-y-auto pr-1">
                <For each={selectedNodes()}>
                  {(name) => {
                    const isMissing = isNodeMissing(name);
                    return (
                      <span class={`text-xs pl-2 pr-1 py-0.5 rounded flex items-center gap-1.5 border transition ${
                        isMissing ? 'bg-rose-500/20 text-rose-300 border-rose-500/50' : 'bg-blue-500/15 text-blue-300 border-blue-500/30'
                      }`}>
                        <Show when={isMissing}>
                          <i class="fa-solid fa-triangle-exclamation text-[10px] text-rose-400" title="在当前订阅中不存在"></i>
                        </Show>
                        <span>{name}</span>
                        <button
                          onClick={() => removeNodeFromCurrentGroup(name)}
                          class="w-4 h-4 rounded-full flex items-center justify-center text-slate-400 hover:text-white hover:bg-rose-600 transition"
                          title="移除">
                          &times;
                        </button>
                      </span>
                    );
                  }}
                </For>
                <Show when={selectedNodes().length === 0}>
                  <span class="text-xs text-slate-500 italic">暂未选择任何节点</span>
                </Show>
              </div>
            </div>

            {/* 搜索与快捷筛选栏 */}
            <div class="space-y-2">
              <div class="flex gap-2">
                <div class="relative flex-1">
                  <i class="fa-solid fa-magnifying-glass absolute left-3 top-1/2 -translate-y-1/2 text-slate-400 text-xs"></i>
                  <input
                    value={nodeSearchQuery()}
                    onInput={(e) => setNodeSearchQuery(e.currentTarget.value)}
                    type="text"
                    placeholder="模糊搜索节点名称、地区关键词 (如 香港, HK, 新加坡, 0.1x)..."
                    class="w-full pl-9 pr-3 py-2 text-xs sm:text-sm rounded-lg glass-input"
                  />
                </div>
                <button onClick={() => testNodeDelay(selectedNodes())} class="px-3 py-2 text-xs bg-emerald-600/20 hover:bg-emerald-600/30 text-emerald-300 border border-emerald-500/30 rounded-lg transition flex items-center gap-1.5 whitespace-nowrap">
                  <i class="fa-solid fa-bolt"></i>
                  <span>仅测速当前已选 ({selectedNodes().length})</span>
                </button>
              </div>

              {/* 地区快捷标签 */}
              <div class="flex items-center gap-1.5 flex-wrap text-xs">
                <span class="text-slate-400 text-[11px] mr-1">快捷筛选:</span>
                <For each={[
                  { label: '全部', value: 'ALL' },
                  { label: '🇭🇰 香港', value: 'HK' },
                  { label: '🇯🇵 日本', value: 'JP' },
                  { label: '🇸🇬 狮城', value: 'SG' },
                  { label: '🇺🇸 美国', value: 'US' },
                ]}>
                  {(r) => (
                    <button
                      onClick={() => setNodeRegionFilter(r.value)}
                      class={`px-2 py-0.5 rounded-md border text-[11px] transition ${
                        nodeRegionFilter() === r.value ? 'bg-blue-600 text-white border-blue-500' : 'bg-slate-800/80 text-slate-400 border-slate-700 hover:text-slate-200'
                      }`}>
                      {r.label}
                    </button>
                  )}
                </For>
                <div class="ml-auto space-x-2 text-[11px]">
                  <button onClick={toggleSelectAllFiltered} class="text-blue-400 hover:underline">
                    全选/反选当前筛选
                  </button>
                </div>
              </div>
            </div>

            {/* 节点多选滚动区 */}
            <div class="flex-1 overflow-y-auto space-y-4 pr-1 text-xs">
              {/* 分区 1: 系统选项 */}
              <div>
                <div class="text-slate-400 font-semibold mb-2 flex items-center gap-1.5">
                  <i class="fa-solid fa-star text-amber-400"></i>
                  <span>系统选项</span>
                </div>
                <div class="grid grid-cols-2 sm:grid-cols-3 gap-2">
                  <For each={['DIRECT', 'REJECT']}>
                    {(spec) => (
                      <label
                        class={`flex items-center gap-2 p-2 rounded-lg border cursor-pointer transition select-none ${
                          selectedNodes().includes(spec) ? 'bg-amber-500/20 border-amber-500/40 text-amber-300 font-medium' : 'bg-slate-800/60 border-slate-700/60 text-slate-300 hover:bg-slate-800'
                        }`}>
                        <input type="checkbox" checked={selectedNodes().includes(spec)} onChange={() => toggleNodeSelection(spec)} class="rounded text-amber-500" />
                        <span class="truncate">{spec}</span>
                      </label>
                    )}
                  </For>
                </div>
              </div>

              {/* 分区 2: 我的自建节点 */}
              <Show when={filteredCustomProxies().length > 0}>
                <div>
                  <div class="text-slate-400 font-semibold mb-2 flex items-center gap-1.5">
                    <i class="fa-solid fa-crown text-emerald-400"></i>
                    <span>我的自建节点 ({filteredCustomProxies().length})</span>
                  </div>
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                    <For each={filteredCustomProxies()}>
                      {(cp) => (
                        <label
                          class={`flex items-center justify-between p-2 rounded-lg border cursor-pointer transition select-none ${
                            selectedNodes().includes(cp.name) ? 'bg-emerald-500/20 border-emerald-500/40 text-emerald-300 font-medium' : 'bg-slate-800/60 border-slate-700/60 text-slate-300 hover:bg-slate-800'
                          }`}>
                          <div class="flex items-center gap-2 min-w-0 pr-2">
                            <input type="checkbox" checked={selectedNodes().includes(cp.name)} onChange={() => toggleNodeSelection(cp.name)} class="rounded text-emerald-500" />
                            <span class="truncate">{cp.name}</span>
                          </div>
                          {renderDelayBadge(cp.name)}
                        </label>
                      )}
                    </For>
                  </div>
                </div>
              </Show>

              {/* 分区 3: 订阅原生策略组 */}
              <Show when={filteredSubscriptionGroups().length > 0}>
                <div>
                  <div class="text-slate-400 font-semibold mb-2 flex items-center gap-1.5">
                    <i class="fa-solid fa-diagram-project text-purple-400"></i>
                    <span>订阅原生策略组 ({filteredSubscriptionGroups().length})</span>
                    <span class="text-[10px] text-slate-500 font-normal">（可将订阅里的整组直接作为子组选择）</span>
                  </div>
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                    <For each={filteredSubscriptionGroups()}>
                      {(sg) => (
                        <label
                          class={`flex items-center justify-between p-2 rounded-lg border cursor-pointer transition select-none ${
                            selectedNodes().includes(sg.name) ? 'bg-purple-500/20 border-purple-500/40 text-purple-300 font-medium' : 'bg-slate-800/60 border-slate-700/60 text-slate-300 hover:bg-slate-800'
                          }`}>
                          <div class="flex items-center gap-2 min-w-0 pr-2">
                            <input type="checkbox" checked={selectedNodes().includes(sg.name)} onChange={() => toggleNodeSelection(sg.name)} class="rounded text-purple-500" />
                            <span class="truncate">{sg.name}</span>
                          </div>
                          <span class="text-[10px] px-1.5 py-0.5 rounded bg-purple-500/20 text-purple-400 font-mono">{sg.type}</span>
                        </label>
                      )}
                    </For>
                  </div>
                </div>
              </Show>

              {/* 分区 4: 订阅单个节点列表 */}
              <div>
                <div class="text-slate-400 font-semibold mb-2 flex items-center gap-1.5">
                  <i class="fa-solid fa-globe text-blue-400"></i>
                  <span>订阅单节点列表 ({filteredSubscriptionNodes().length})</span>
                </div>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 max-h-72 overflow-y-auto pr-1">
                  <For each={filteredSubscriptionNodes()}>
                    {(sp) => (
                      <label
                        class={`flex items-center justify-between p-2 rounded-lg border cursor-pointer transition select-none ${
                          selectedNodes().includes(sp.name) ? 'bg-blue-500/20 border-blue-500/40 text-blue-300 font-medium' : 'bg-slate-800/60 border-slate-700/60 text-slate-300 hover:bg-slate-800'
                        }`}>
                        <div class="flex items-center gap-2 min-w-0 pr-2">
                          <input type="checkbox" checked={selectedNodes().includes(sp.name)} onChange={() => toggleNodeSelection(sp.name)} class="rounded text-blue-500" />
                          <span class="truncate">{sp.name}</span>
                        </div>
                        {renderDelayBadge(sp.name)}
                      </label>
                    )}
                  </For>
                  <Show when={filteredSubscriptionNodes().length === 0}>
                    <div class="col-span-2 py-8 text-center text-slate-500">未找到匹配的订阅节点</div>
                  </Show>
                </div>
              </div>
            </div>

            {/* 弹窗底部操作 */}
            <div class="flex justify-between items-center pt-3 border-t border-slate-800">
              <span class="text-xs text-slate-400">已选择 <b class="text-white">{selectedNodes().length}</b> 个节点/组</span>
              <div class="flex space-x-2">
                <button onClick={() => setNodeModalOpen(false)} class="px-4 py-1.5 text-xs text-slate-400 hover:text-white rounded-lg">取消</button>
                <button onClick={saveGroupNodes} class="px-4 py-1.5 text-xs bg-blue-600 hover:bg-blue-500 text-white rounded-lg transition">确认保存</button>
              </div>
            </div>
          </div>
        </div>
      </Show>

      {/* ==================== 模态框: 导入节点链接 ==================== */}
      <Show when={importModalOpen()}>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm">
          <div class="glass-card max-w-lg w-full p-6 rounded-2xl border border-slate-700 shadow-2xl space-y-4">
            <div class="flex items-center justify-between border-b border-slate-800 pb-3">
              <h3 class="font-semibold text-white flex items-center gap-2">
                <i class="fa-solid fa-link text-blue-400"></i>
                <span>导入节点分享链接</span>
              </h3>
              <button onClick={() => setImportModalOpen(false)} class="text-slate-400 hover:text-white">&times;</button>
            </div>
            <div class="space-y-3">
              <div>
                <label class="block text-xs font-medium text-slate-400 mb-1">粘贴分享链接 (支持 vless://, ss://, trojan://)</label>
                <textarea
                  value={linkToImport()}
                  onInput={(e) => setLinkToImport(e.currentTarget.value)}
                  rows={4}
                  placeholder="vless://decf85cf-...@154.53.75.226:8881?security=reality..."
                  class="w-full p-2.5 text-xs font-mono rounded-lg glass-input"
                />
              </div>
            </div>
            <div class="flex justify-end space-x-2 pt-2 border-t border-slate-800">
              <button onClick={() => setImportModalOpen(false)} class="px-4 py-1.5 text-xs text-slate-400 hover:text-white rounded-lg">取消</button>
              <button onClick={parseAndAddLink} disabled={!linkToImport().trim()} class="px-4 py-1.5 text-xs bg-blue-600 hover:bg-blue-500 text-white rounded-lg transition disabled:opacity-50">解析并添加</button>
            </div>
          </div>
        </div>
      </Show>

      {/* ==================== 模态框: 手动添加/编辑节点 ==================== */}
      <Show when={proxyModalOpen()}>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm">
          <div class="glass-card max-w-lg w-full p-6 rounded-2xl border border-slate-700 shadow-2xl space-y-4 max-h-[90vh] overflow-y-auto">
            <div class="flex items-center justify-between border-b border-slate-800 pb-3">
              <h3 class="font-semibold text-white">{editingProxyIndex() === -1 ? '添加自建节点' : '编辑节点'}</h3>
              <button onClick={() => setProxyModalOpen(false)} class="text-slate-400 hover:text-white">&times;</button>
            </div>
            <div class="space-y-3 text-xs">
              <div>
                <label class="block text-slate-400 mb-1">节点名称</label>
                <input value={proxyForm().name} onInput={(e) => setProxyForm({ ...proxyForm(), name: e.currentTarget.value })} type="text" placeholder="🇺🇸 USA_Los_Reality" class="w-full p-2 rounded-lg glass-input" />
              </div>
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="block text-slate-400 mb-1">协议类型</label>
                  <select value={proxyForm().type} onChange={(e) => setProxyForm({ ...proxyForm(), type: e.currentTarget.value })} class="w-full p-2 rounded-lg glass-input">
                    <option value="vless">VLESS</option>
                    <option value="ss">Shadowsocks</option>
                    <option value="trojan">Trojan</option>
                  </select>
                </div>
                <div>
                  <label class="block text-slate-400 mb-1">端口</label>
                  <input value={proxyForm().port} onInput={(e) => setProxyForm({ ...proxyForm(), port: e.currentTarget.value })} type="number" placeholder="443" class="w-full p-2 rounded-lg glass-input" />
                </div>
              </div>
              <div>
                <label class="block text-slate-400 mb-1">服务器地址 (IP 或 域名)</label>
                <input value={proxyForm().server} onInput={(e) => setProxyForm({ ...proxyForm(), server: e.currentTarget.value })} type="text" placeholder="154.53.75.226" class="w-full p-2 rounded-lg glass-input" />
              </div>
              <Show when={proxyForm().type === 'vless'}>
                <div>
                  <label class="block text-slate-400 mb-1">UUID</label>
                  <input value={proxyForm().uuid} onInput={(e) => setProxyForm({ ...proxyForm(), uuid: e.currentTarget.value })} type="text" placeholder="decf85cf-..." class="w-full p-2 rounded-lg glass-input" />
                </div>
                <div class="grid grid-cols-2 gap-3">
                  <div>
                    <label class="block text-slate-400 mb-1">SNI (Server Name)</label>
                    <input value={proxyForm().servername} onInput={(e) => setProxyForm({ ...proxyForm(), servername: e.currentTarget.value })} type="text" placeholder="addons.mozilla.org" class="w-full p-2 rounded-lg glass-input" />
                  </div>
                  <div>
                    <label class="block text-slate-400 mb-1">Flow</label>
                    <input value={proxyForm().flow} onInput={(e) => setProxyForm({ ...proxyForm(), flow: e.currentTarget.value })} type="text" placeholder="xtls-rprx-vision" class="w-full p-2 rounded-lg glass-input" />
                  </div>
                </div>
                <div>
                  <label class="block text-slate-400 mb-1">Reality Public Key (公钥)</label>
                  <input value={proxyForm().publicKey} onInput={(e) => setProxyForm({ ...proxyForm(), publicKey: e.currentTarget.value })} type="text" placeholder="XLY4_lSmUI..." class="w-full p-2 rounded-lg glass-input font-mono" />
                </div>
              </Show>
              <Show when={proxyForm().type === 'ss'}>
                <div class="grid grid-cols-2 gap-3">
                  <div>
                    <label class="block text-slate-400 mb-1">加密方式 (Cipher)</label>
                    <input value={proxyForm().cipher} onInput={(e) => setProxyForm({ ...proxyForm(), cipher: e.currentTarget.value })} type="text" placeholder="aes-128-gcm" class="w-full p-2 rounded-lg glass-input" />
                  </div>
                  <div>
                    <label class="block text-slate-400 mb-1">密码</label>
                    <input value={proxyForm().password} onInput={(e) => setProxyForm({ ...proxyForm(), password: e.currentTarget.value })} type="password" class="w-full p-2 rounded-lg glass-input" />
                  </div>
                </div>
              </Show>
            </div>
            <div class="flex justify-end space-x-2 pt-3 border-t border-slate-800">
              <button onClick={() => setProxyModalOpen(false)} class="px-4 py-1.5 text-xs text-slate-400 hover:text-white rounded-lg">取消</button>
              <button onClick={saveProxyForm} class="px-4 py-1.5 text-xs bg-blue-600 hover:bg-blue-500 text-white rounded-lg transition">确定</button>
            </div>
          </div>
        </div>
      </Show>

      {/* ==================== 模态框: 添加/编辑策略组 ==================== */}
      <Show when={groupModalOpen()}>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm">
          <div class="glass-card max-w-md w-full p-6 rounded-2xl border border-slate-700 shadow-2xl space-y-4">
            <div class="flex items-center justify-between border-b border-slate-800 pb-3">
              <h3 class="font-semibold text-white">{editingGroupIndex() === -1 ? '新建代理策略组' : '编辑策略组'}</h3>
              <button onClick={() => setGroupModalOpen(false)} class="text-slate-400 hover:text-white">&times;</button>
            </div>
            <div class="space-y-3 text-xs">
              <div>
                <label class="block text-slate-400 mb-1">策略组名称</label>
                <input value={groupForm().name} onInput={(e) => setGroupForm({ ...groupForm(), name: e.currentTarget.value })} type="text" placeholder="如 Claude, MyGoogle, 交易专属" class="w-full p-2 rounded-lg glass-input" />
              </div>
              <div>
                <label class="block text-slate-400 mb-1">组类型</label>
                <select value={groupForm().type} onChange={(e) => setGroupForm({ ...groupForm(), type: e.currentTarget.value })} class="w-full p-2 rounded-lg glass-input">
                  <option value="select">select (手动选择节点)</option>
                  <option value="url-test">url-test (自动选择最低延迟)</option>
                  <option value="fallback">fallback (故障自动转移)</option>
                </select>
              </div>
            </div>
            <div class="flex justify-end space-x-2 pt-3 border-t border-slate-800">
              <button onClick={() => setGroupModalOpen(false)} class="px-4 py-1.5 text-xs text-slate-400 hover:text-white rounded-lg">取消</button>
              <button onClick={saveGroupForm} class="px-4 py-1.5 text-xs bg-blue-600 hover:bg-blue-500 text-white rounded-lg transition">确定</button>
            </div>
          </div>
        </div>
      </Show>

      {/* ==================== 模态框: 添加/编辑规则 ==================== */}
      <Show when={ruleModalOpen()}>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm">
          <div class="glass-card max-w-md w-full p-6 rounded-2xl border border-slate-700 shadow-2xl space-y-4">
            <div class="flex items-center justify-between border-b border-slate-800 pb-3">
              <h3 class="font-semibold text-white">{editingRuleIndex() === -1 ? '添加分流规则' : '编辑分流规则'}</h3>
              <button onClick={() => setRuleModalOpen(false)} class="text-slate-400 hover:text-white">&times;</button>
            </div>
            <div class="space-y-3 text-xs">
              <div>
                <label class="block text-slate-400 mb-1">规则类型</label>
                <select value={ruleForm().type} onChange={(e) => setRuleForm({ ...ruleForm(), type: e.currentTarget.value })} class="w-full p-2 rounded-lg glass-input">
                  <option value="DOMAIN-SUFFIX">DOMAIN-SUFFIX (域名后缀匹配, 如 claude.ai)</option>
                  <option value="DOMAIN">DOMAIN (域名完全匹配, 如 ai.google.dev)</option>
                  <option value="DOMAIN-KEYWORD">DOMAIN-KEYWORD (关键词匹配, 如 google)</option>
                  <option value="IP-CIDR">IP-CIDR (IP段, 如 1.1.1.1/32)</option>
                  <option value="GEOSITE">GEOSITE (预定义域名集, 如 geosite:cn)</option>
                  <option value="GEOIP">GEOIP (国家代码, 如 CN)</option>
                </select>
              </div>
              <div>
                <label class="block text-slate-400 mb-1">匹配目标 (域名/IP/关键词)</label>
                <input value={ruleForm().payload} onInput={(e) => setRuleForm({ ...ruleForm(), payload: e.currentTarget.value })} type="text" placeholder="例如: claude.ai 或 anthropic.com" class="w-full p-2 rounded-lg glass-input font-mono" />
              </div>
              <div>
                <label class="block text-slate-400 mb-1">目标策略组 / 动作</label>
                <select value={ruleForm().target} onChange={(e) => setRuleForm({ ...ruleForm(), target: e.currentTarget.value })} class="w-full p-2 rounded-lg glass-input font-medium text-indigo-300">
                  <For each={groupOptions()}>
                    {(opt) => <option value={opt}>{opt}</option>}
                  </For>
                </select>
              </div>
            </div>
            <div class="flex justify-end space-x-2 pt-3 border-t border-slate-800">
              <button onClick={() => setRuleModalOpen(false)} class="px-4 py-1.5 text-xs text-slate-400 hover:text-white rounded-lg">取消</button>
              <button onClick={saveRuleForm} class="px-4 py-1.5 text-xs bg-blue-600 hover:bg-blue-500 text-white rounded-lg transition">确定</button>
            </div>
          </div>
        </div>
      </Show>
    </div>
  );
}
