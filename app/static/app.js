const state = { snapshot: null, page: 'overview', latency: {}, busy: false, timer: null };

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const escapeHTML = (value = '') => String(value).replace(/[&<>'"]/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[char]));

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    body: options.body && typeof options.body !== 'string' ? JSON.stringify(options.body) : options.body
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.error) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

function toast(message, type = 'success') {
  const item = document.createElement('div');
  item.className = `toast ${type}`;
  item.textContent = message;
  $('#toasts').append(item);
  setTimeout(() => item.remove(), 3600);
}

function formatBytes(bytes, speed = false) {
  const value = Number(bytes || 0);
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  if (value < 1) return `0 B${speed ? '/s' : ''}`;
  const index = Math.min(Math.floor(Math.log(value) / Math.log(1024)), units.length - 1);
  const number = value / Math.pow(1024, index);
  return `${number >= 100 || index === 0 ? number.toFixed(0) : number.toFixed(1)} ${units[index]}${speed ? '/s' : ''}`;
}

function formatDuration(total) {
  const hours = Math.floor(total / 3600).toString().padStart(2, '0');
  const minutes = Math.floor(total % 3600 / 60).toString().padStart(2, '0');
  const seconds = Math.floor(total % 60).toString().padStart(2, '0');
  return `${hours}:${minutes}:${seconds}`;
}

function timeOnly(value) {
  if (!value) return '—';
  return new Date(value).toLocaleTimeString('zh-CN', {hour12:false, hour:'2-digit', minute:'2-digit', second:'2-digit'});
}

function setPage(page) {
  state.page = page;
  $$('.nav-item').forEach(button => button.classList.toggle('active', button.dataset.page === page));
  $$('.page').forEach(section => section.classList.toggle('active', section.id === `page-${page}`));
  const titles = {
    overview: ['NETWORK OVERVIEW', '网络概览'], connections: ['CONNECTIONS', '连接面板'], nodes: ['OUTBOUND NODES', '代理节点'],
    subscriptions: ['REMOTE PROFILES', '订阅管理'], rules: ['SMART ROUTING', '自动分流'], settings: ['PREFERENCES', '设置']
  };
  $('#pageEyebrow').textContent = titles[page][0];
  $('#pageTitle').textContent = titles[page][1];
  render();
}

async function refresh(silent = true) {
  try {
    state.snapshot = await api('/api/snapshot');
    render();
  } catch (error) {
    if (!silent) toast(error.message, 'error');
    $('#coreText').textContent = '核心不可达';
    $('#coreDot').classList.remove('online');
  }
}

function render() {
  if (!state.snapshot) return;
  const { config, stats } = state.snapshot;
  const settings = config.settings;
  $('#coreText').textContent = settings.proxy_running ? '核心运行中' : '核心已停止';
  $('#corePort').textContent = `127.0.0.1:${settings.proxy_port}`;
  $('#coreDot').classList.toggle('online', !!settings.proxy_running);
  $('#statusOrb').classList.toggle('offline', !settings.proxy_running);
  $('#orbStatus').textContent = settings.proxy_running ? '运行中' : '已停止';
  $('#proxyToggle').title = settings.proxy_running ? '停止代理' : '启动代理';
  $$('#modeSwitch button').forEach(button => button.classList.toggle('active', button.dataset.mode === settings.mode));
  const system = settings.system_proxy || {};
  $('#systemBadge').textContent = system.enabled ? `系统代理 · ${system.service}` : '系统代理未启用';
  $('#systemBadge').classList.toggle('muted', !system.enabled);
  $('#systemProxyButton').textContent = system.enabled ? '关闭系统代理' : '启用系统代理';
  $('#proxyAddress').textContent = `127.0.0.1:${settings.proxy_port}`;
  $('#dashboardAddress').textContent = `127.0.0.1:${settings.dashboard_port}`;
  const ipdb = state.snapshot.ip_database || {};
  $('#ipdbStatus').textContent = ipdb.ready ? '已就绪' : '未就绪';
  $('#ipdbStatus').classList.toggle('muted', !ipdb.ready);
  $('#ipdbMeta').textContent = ipdb.ready ? `APNIC ${ipdb.source_date || ''} · IPv4 ${ipdb.ipv4_ranges} 段 · IPv6 ${ipdb.ipv6_ranges} 段` : '没有可用数据库时，未分类流量将按兜底规则代理。';

  renderOverview(config, stats);
  if (state.page === 'connections') renderConnections(stats);
  if (state.page === 'nodes') renderNodes(config);
  if (state.page === 'subscriptions') renderSubscriptions(config);
  if (state.page === 'rules') renderRules(config);
}

function renderOverview(config, stats) {
  const latest = stats.series[stats.series.length - 1] || {up: 0, down: 0};
  $('#downSpeed').textContent = formatBytes(latest.down, true);
  $('#upSpeed').textContent = formatBytes(latest.up, true);
  $('#totalDown').textContent = formatBytes(stats.total_down);
  $('#totalUp').textContent = formatBytes(stats.total_up);
  $('#activeCount').textContent = stats.active.length;
  $('#uptime').textContent = formatDuration(stats.uptime);
  drawChart(stats.series);

  const selected = config.nodes.find(node => node.id === config.settings.selected_node);
  $('#selectedNode').classList.toggle('empty', !selected);
  $('#selectedNode').innerHTML = selected ? `<div class="node-flag">${escapeHTML(selected.type.slice(0,2).toUpperCase())}</div><div><b>${escapeHTML(selected.name)}</b><small>${escapeHTML(selected.type.toUpperCase())} · ${escapeHTML(selected.host)}:${selected.port}</small></div>` : '尚未选择代理节点；DIRECT 规则仍可正常工作';

  const routes = stats.routes || {};
  const routeItems = [['PROXY', routes.PROXY || 0], ['DIRECT', routes.DIRECT || 0], ['REJECT', routes.REJECT || 0]];
  const max = Math.max(1, ...routeItems.map(item => item[1]));
  $('#routeBars').innerHTML = routeItems.map(([name, count]) => `<div class="route-row"><span>${name}</span><div class="bar"><i style="width:${count / max * 100}%;background:${name === 'DIRECT' ? 'var(--cyan)' : name === 'REJECT' ? 'var(--red)' : 'var(--green)'}"></i></div><span>${count}</span></div>`).join('');
  const rows = [...stats.active, ...stats.recent].slice(0, 7);
  $('#recentPreview').innerHTML = rows.length ? rows.map(connectionRowShort).join('') : emptyRow(6, '等待首个代理连接');
}

function drawChart(series) {
  const canvas = $('#trafficChart');
  const ratio = window.devicePixelRatio || 1;
  const width = canvas.clientWidth || 500;
  const height = canvas.clientHeight || 190;
  if (canvas.width !== width * ratio || canvas.height !== height * ratio) { canvas.width = width * ratio; canvas.height = height * ratio; }
  const context = canvas.getContext('2d');
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  context.clearRect(0, 0, width, height);
  context.strokeStyle = 'rgba(255,255,255,.045)'; context.lineWidth = 1;
  for (let i = 1; i < 4; i++) { context.beginPath(); context.moveTo(0, height * i / 4); context.lineTo(width, height * i / 4); context.stroke(); }
  const max = Math.max(1024, ...series.flatMap(point => [point.up, point.down]));
  plot(context, series.map(point => point.down), width, height, max, '#78f5c5', 'rgba(120,245,197,.08)');
  plot(context, series.map(point => point.up), width, height, max, '#5dcfe2', null);
}

function plot(context, values, width, height, max, color, fill) {
  const points = values.map((value, index) => [index / Math.max(1, values.length - 1) * width, height - (value / max * (height - 16)) - 8]);
  context.beginPath(); points.forEach(([x,y], index) => index ? context.lineTo(x,y) : context.moveTo(x,y));
  context.strokeStyle = color; context.lineWidth = 1.7; context.stroke();
  if (fill) { context.lineTo(width, height); context.lineTo(0, height); context.closePath(); const gradient = context.createLinearGradient(0,0,0,height); gradient.addColorStop(0, fill); gradient.addColorStop(1,'rgba(0,0,0,0)'); context.fillStyle = gradient; context.fill(); }
}

function actionTag(action) { return `<span class="action-tag ${String(action).toLowerCase()}">${escapeHTML(action)}</span>`; }
function stateTag(status) { return `<span class="state-tag ${status === 'active' ? 'active' : ''}">${status === 'active' ? '活动' : status === 'error' ? '错误' : status === 'rejected' ? '已拒绝' : '完成'}</span>`; }
function emptyRow(columns, message) { return `<tr><td colspan="${columns}" class="empty-row">${escapeHTML(message)}</td></tr>`; }
function connectionRowShort(item) { return `<tr><td><strong>${escapeHTML(item.host)}:${item.port}</strong></td><td><span class="category-tag">${escapeHTML(item.category)}</span></td><td>${actionTag(item.action)}</td><td>${escapeHTML(item.rule)}<br><span class="subtle">${escapeHTML(item.node || '—')}</span></td><td>↑ ${formatBytes(item.up)} · ↓ ${formatBytes(item.down)}</td><td>${stateTag(item.status)}</td></tr>`; }

function renderConnections(stats) {
  const all = [...stats.active, ...stats.recent];
  const query = $('#connectionSearch').value.trim().toLowerCase();
  const filtered = all.filter(item => !query || `${item.host} ${item.rule} ${item.node} ${item.category}`.toLowerCase().includes(query));
  $('#metricActive').textContent = stats.active.length;
  $('#metricTotal').textContent = all.length;
  $('#metricProxy').textContent = stats.routes.PROXY || 0;
  $('#metricDirect').textContent = stats.routes.DIRECT || 0;
  $('#connectionTable').innerHTML = filtered.length ? filtered.map(item => `<tr><td>${timeOnly(item.started_at)}</td><td><strong>${escapeHTML(item.host)}:${item.port}</strong></td><td><span class="category-tag">${escapeHTML(item.category)}</span></td><td>${actionTag(item.action)}</td><td>${escapeHTML(item.rule)}</td><td>${escapeHTML(item.node || '—')}</td><td>↑ ${formatBytes(item.up)} / ↓ ${formatBytes(item.down)}</td><td>${stateTag(item.status)}</td></tr>`).join('') : emptyRow(8, query ? '没有匹配的连接' : '还没有连接记录');
}

function renderNodes(config) {
  const nodes = config.nodes;
  $('#nodeGrid').innerHTML = nodes.length ? nodes.map(node => {
    const selected = node.id === config.settings.selected_node;
    const latency = state.latency[node.id];
    return `<article class="node-card ${selected ? 'selected' : ''} ${node.supported === false ? 'unsupported' : ''}" data-node="${escapeHTML(node.id)}"><div class="node-top"><span class="node-type">${escapeHTML(node.type.toUpperCase())}</span><span class="latency ${latency && latency < 400 ? 'good' : ''}">${latency ? `${latency} ms` : node.supported === false ? '不支持' : '未测试'}</span></div><h3>${escapeHTML(node.name)}</h3><p>${escapeHTML(node.host || node.disabled_reason || '')}${node.port ? `:${node.port}` : ''}</p><div class="node-actions"><span class="subtle">${selected ? '✓ 当前出口' : escapeHTML(node.source_id === 'manual' ? '手动节点' : '订阅节点')}</span>${node.supported === false ? '' : `<button data-test-node="${escapeHTML(node.id)}">测试延迟</button>`}</div></article>`;
  }).join('') : `<div class="empty-state"><div><b>还没有代理节点</b>添加 SS 订阅，或手动录入 HTTP / SOCKS5 节点</div></div>`;
}

function renderSubscriptions(config) {
  $('#subscriptionList').innerHTML = config.subscriptions.length ? config.subscriptions.map(sub => `<article class="stack-item"><div class="stack-icon">↻</div><div class="stack-body"><b>${escapeHTML(sub.name)}</b><small>${escapeHTML(maskUrl(sub.url))}</small></div><div class="stack-meta">${sub.status === 'error' ? `<span style="color:var(--red)">${escapeHTML(sub.error)}</span>` : `${sub.node_count || 0} 个节点<br>${sub.updated_at ? timeOnly(sub.updated_at) : '尚未更新'}`}</div><div class="stack-actions"><button data-refresh-sub="${escapeHTML(sub.id)}">更新</button><button class="danger" data-delete-sub="${escapeHTML(sub.id)}">删除</button></div></article>`).join('') : `<div class="empty-state"><div><b>没有订阅</b>添加远程配置后，智连会解析并汇总节点</div></div>`;
}

function maskUrl(value) {
  try { const url = new URL(value); if (url.search) url.search = '?••••••'; return url.toString(); } catch { return '已保存的订阅'; }
}

function renderRules(config) {
  $('#ruleList').innerHTML = config.rules.map((rule, index) => `<div class="rule-row"><span class="drag">${String(index + 1).padStart(2,'0')}</span><div class="rule-main"><b>${escapeHTML(rule.name)}</b><small>${escapeHTML(rule.type.toUpperCase())}${rule.builtin ? ' · 内置' : ''}</small></div><span class="rule-value">${escapeHTML(rule.value || '自动识别')}</span>${actionTag(rule.action)}<button class="toggle ${rule.enabled ? 'on' : ''}" data-toggle-rule="${escapeHTML(rule.id)}" data-enabled="${rule.enabled}"></button>${rule.builtin ? '<span></span>' : `<button class="delete-rule" data-delete-rule="${escapeHTML(rule.id)}">×</button>`}</div>`).join('');
}

async function busyAction(button, action, success) {
  if (state.busy) return;
  state.busy = true;
  const original = button && button.textContent;
  if (button) { button.disabled = true; button.textContent = '处理中…'; }
  try { await action(); if (success) toast(success); await refresh(); return true; }
  catch (error) { toast(error.message, 'error'); return false; }
  finally { state.busy = false; if (button) { button.disabled = false; button.textContent = original; } }
}

document.addEventListener('click', event => {
  const nav = event.target.closest('[data-page]'); if (nav) return setPage(nav.dataset.page);
  const goto = event.target.closest('[data-goto]'); if (goto) return setPage(goto.dataset.goto);
  const modal = event.target.closest('[data-modal]'); if (modal) return $(`#${modal.dataset.modal}`).showModal();
  const mode = event.target.closest('[data-mode]'); if (mode) return busyAction(mode, () => api('/api/mode', {method:'POST', body:{mode:mode.dataset.mode}}), `已切换为${mode.textContent}模式`);
  const nodeCard = event.target.closest('[data-node]');
  if (nodeCard && !event.target.closest('[data-test-node]') && !nodeCard.classList.contains('unsupported')) return busyAction(null, () => api('/api/nodes/select', {method:'POST', body:{id:nodeCard.dataset.node}}), '已切换出口节点');
  const test = event.target.closest('[data-test-node]');
  if (test) return busyAction(test, async () => { const result = await api('/api/nodes/test', {method:'POST', body:{id:test.dataset.testNode}}); state.latency[result.id] = result.latency; }, '延迟测试完成');
  const refreshSub = event.target.closest('[data-refresh-sub]'); if (refreshSub) return busyAction(refreshSub, () => api('/api/subscriptions/refresh', {method:'POST', body:{id:refreshSub.dataset.refreshSub}}), '订阅已更新');
  const deleteSub = event.target.closest('[data-delete-sub]'); if (deleteSub && confirm('删除这条订阅及其节点？')) return busyAction(deleteSub, () => api(`/api/subscriptions?id=${encodeURIComponent(deleteSub.dataset.deleteSub)}`, {method:'DELETE'}), '订阅已删除');
  const toggleRule = event.target.closest('[data-toggle-rule]'); if (toggleRule) return busyAction(null, () => api('/api/rules/toggle', {method:'POST', body:{id:toggleRule.dataset.toggleRule, enabled:toggleRule.dataset.enabled !== 'true'}}));
  const deleteRule = event.target.closest('[data-delete-rule]'); if (deleteRule && confirm('删除这条规则？')) return busyAction(null, () => api(`/api/rules?id=${encodeURIComponent(deleteRule.dataset.deleteRule)}`, {method:'DELETE'}), '规则已删除');
});

$('#proxyToggle').addEventListener('click', () => busyAction($('#proxyToggle'), () => api('/api/proxy/toggle', {method:'POST', body:{enabled:!state.snapshot.config.settings.proxy_running}})));
$('#systemProxyButton').addEventListener('click', () => busyAction($('#systemProxyButton'), () => api('/api/system-proxy', {method:'POST', body:{enabled:!state.snapshot.config.settings.system_proxy.enabled}}), '系统代理设置已更新'));
$('#refreshButton').addEventListener('click', async event => { event.currentTarget.classList.add('loading'); await refresh(false); setTimeout(() => event.currentTarget.classList.remove('loading'), 350); });
$('#connectionSearch').addEventListener('input', () => state.snapshot && renderConnections(state.snapshot.stats));
$('#ipdbUpdateButton').addEventListener('click', event => busyAction(event.currentTarget, () => api('/api/ip-database/update', {method:'POST'}), '中国 IP 段库已更新'));
$('#shutdownButton').addEventListener('click', event => {
  if (!confirm('确定退出智连？系统代理将一并关闭。')) return;
  busyAction(event.currentTarget, () => api('/api/shutdown', {method:'POST'}), '智连正在退出');
});

function bindForm(id, handler, success) {
  $(`#${id}`).addEventListener('submit', event => {
    const submitter = event.submitter;
    if (submitter && submitter.value === 'cancel') return;
    event.preventDefault();
    const data = Object.fromEntries(new FormData(event.currentTarget).entries());
    busyAction(submitter, () => handler(data), success).then(ok => { if (ok) { event.currentTarget.closest('dialog').close(); event.currentTarget.reset(); } });
  });
}

bindForm('subscriptionForm', data => api('/api/subscriptions', {method:'POST', body:data}), '订阅添加完成');
bindForm('nodeForm', data => api('/api/nodes', {method:'POST', body:data}), '节点已添加');
bindForm('ruleForm', data => api('/api/rules', {method:'POST', body:data}), '规则已添加');

window.addEventListener('resize', () => state.snapshot && drawChart(state.snapshot.stats.series));
refresh(false);
state.timer = setInterval(() => refresh(true), 1000);
