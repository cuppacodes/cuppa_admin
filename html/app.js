// ── State ──
let isOpen = false;
let selectedPlayer = null;
let viewingPlayer = null;
let commandHistory = [];
let historyIndex = -1;
let players = [];
let suggestionIndex = -1;
let refreshInterval = null;
let cachedItems = null;
let cachedJobs = null;
let cachedGangs = null;

const COMMANDS = [
    'stats', 'announce', 'kick', 'ban', 'unban', 'baninfo', 'undo',
    'heal', 'kill', 'revive', 'freeze', 'goto', 'bring', 'car', 'fix', 'dv',
    'giveitem', 'setjob', 'setgang', 'givecash', 'givebank', 'armor', 'setmodel',
    'noclip', 'tp', 'godmode', 'visible', 'hide', 'show', 'bucket', 'terminal', 'inventory',
    'vec2', 'vec3', 'vec4', 'heading', 'names', 'blips',
    'help'
];

const NEEDS_TARGET = [
    'kick', 'ban', 'heal', 'kill', 'revive', 'freeze', 'goto', 'bring',
    'car', 'fix', 'giveitem', 'setjob', 'setgang', 'givecash', 'givebank',
    'armor', 'setmodel', 'noclip', 'tp', 'godmode', 'visible', 'hide', 'show',
    'undo', 'dv', 'unban', 'baninfo', 'inventory'
];

const NO_ARGS = ['stats', 'help', 'terminal', 'vec2', 'vec3', 'vec4', 'heading', 'names', 'blips'];
const CUSTOM_ARGS = ['announce', 'bucket', 'setmodel'];
const AUTO_EXEC = ['heal', 'kill', 'revive', 'freeze', 'godmode', 'noclip', 'visible', 'goto', 'bring', 'fix', 'armor', 'undo', 'dv', 'vec2', 'vec3', 'vec4', 'heading', 'names', 'blips', 'tp'];

const TOOLBAR_AUTO_EXEC = ['stats', 'vec2', 'vec3', 'vec4', 'heading', 'names', 'blips'];

// Commands that open a modal for args (mapped to modal type)
const MODAL_CMDS = {
    giveitem:  'giveitem',
    givecash:  'amount',
    givebank:  'amount',
    setjob:    'job',
    setgang:   'gang',
    setmodel:  'text',
    kick:      'text',
    ban:       'ban',
    car:       'text',
    armor:     'armor',
};

// ── DOM refs ──
const terminal = document.getElementById('terminal');
const output = document.getElementById('output');
const input = document.getElementById('input');
const suggestionsEl = document.getElementById('suggestions');
const playerListEl = document.getElementById('player-list');
const panelPlayers = document.getElementById('panel-players');
const panelDetail = document.getElementById('panel-detail');
const panelInventory = document.getElementById('panel-inventory');
const detailTitle = document.getElementById('detail-title');
const detailInfo = document.getElementById('detail-info');
const detailCommands = document.getElementById('detail-commands');
const invTitle = document.getElementById('inv-title');
const invWeight = document.getElementById('inv-weight');
const invList = document.getElementById('inv-list');
const closeBtn = document.getElementById('close-btn');
const header = document.getElementById('header');
const toolbar = document.getElementById('toolbar');
const divider = document.getElementById('divider');
const right = document.getElementById('right');
const settingsOverlay = document.getElementById('settings-overlay');
const settingsBtn = document.getElementById('settings-btn');
const settingsClose = document.getElementById('settings-close');
const settingAccent = document.getElementById('setting-accent');
const settingOpacity = document.getElementById('setting-opacity');
const settingBlur = document.getElementById('setting-blur');
const opacityVal = document.getElementById('opacity-val');
const blurVal = document.getElementById('blur-val');
const settingsReset = document.getElementById('settings-reset');
const modalOverlay = document.getElementById('modal-overlay');
const modalTitle = document.getElementById('modal-title');
const modalBody = document.getElementById('modal-body');
const modalClose = document.getElementById('modal-close');
const modalCancel = document.getElementById('modal-cancel');
const modalConfirm = document.getElementById('modal-confirm');

// ── Settings & Position persistence ──
const SETTINGS_KEY = 'cuppa_settings';
const POSITION_KEY = 'cuppa_position';
const DIVIDER_KEY = 'cuppa_divider';
const DEFAULTS = { accent: '#82c8ff', opacity: 55, blur: 16 };

function loadSettings() {
    try { return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(SETTINGS_KEY)) }; }
    catch { return { ...DEFAULTS }; }
}

function saveSettings(s) {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(s));
}

function hexToRgb(hex) {
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    return r + ', ' + g + ', ' + b;
}

function applySettings(s) {
    const root = document.documentElement;
    root.style.setProperty('--accent', s.accent);
    root.style.setProperty('--accent-rgb', hexToRgb(s.accent));
    root.style.setProperty('--bg-opacity', s.opacity / 100);
    root.style.setProperty('--blur', s.blur + 'px');
}

function loadPosition() {
    try { return JSON.parse(localStorage.getItem(POSITION_KEY)); }
    catch { return null; }
}

function savePosition() {
    const rect = terminal.getBoundingClientRect();
    localStorage.setItem(POSITION_KEY, JSON.stringify({
        x: Math.round(rect.left),
        y: Math.round(rect.top),
        w: Math.round(rect.width),
        h: Math.round(rect.height)
    }));
}

function loadDivider() {
    try { return parseInt(localStorage.getItem(DIVIDER_KEY)); }
    catch { return null; }
}

function saveDivider() {
    localStorage.setItem(DIVIDER_KEY, right.offsetWidth);
}

// ── Init settings ──
const settings = loadSettings();
applySettings(settings);
settingAccent.value = settings.accent;
settingOpacity.value = settings.opacity;
settingBlur.value = settings.blur;
opacityVal.textContent = settings.opacity + '%';
blurVal.textContent = settings.blur + 'px';

// ── Modal system ──
let modalCallback = null;

function showModal(title, bodyHtml, opts) {
    opts = opts || {};
    modalTitle.textContent = title;
    modalBody.innerHTML = bodyHtml;
    modalConfirm.textContent = opts.confirmText || 'Confirm';
    modalConfirm.disabled = opts.disableConfirm || false;
    modalConfirm.style.display = '';
    modalOverlay.style.display = 'flex';
    modalCallback = opts.onConfirm || null;

    const firstInput = modalBody.querySelector('input, select');
    if (firstInput) setTimeout(() => firstInput.focus(), 50);
}

function hideModal() {
    modalOverlay.style.display = 'none';
    modalBody.innerHTML = '';
    modalCallback = null;
}

modalClose.addEventListener('click', hideModal);
modalCancel.addEventListener('click', hideModal);
modalOverlay.addEventListener('click', (e) => {
    if (e.target === modalOverlay) hideModal();
});
modalConfirm.addEventListener('click', () => {
    if (modalCallback) modalCallback();
});

// ── Refund Builder ──
let refundBuilderItems = [];

function openRefundBuilder() {
    refundBuilderItems = [];
    renderRefundBuilder();
}

function renderRefundBuilder() {
    let itemsHtml = '';
    if (refundBuilderItems.length === 0) {
        itemsHtml = '<div class="refund-empty">No items added yet</div>';
    } else {
        itemsHtml = '<div class="refund-items">';
        refundBuilderItems.forEach((item, i) => {
            let meta = '';
            if (item.metadata && item.metadata.serial) meta = ' #' + item.metadata.serial;
            itemsHtml += '<div class="refund-item-row"><div class="refund-item-info"><span class="refund-item-name">' + (item.label || item.name) + '</span><span class="refund-item-count">x' + item.count + '</span>' + (meta ? '<span class="refund-item-meta">' + meta + '</span>' : '') + '</div><button class="refund-item-remove" data-idx="' + i + '">✕</button></div>';
        });
        itemsHtml += '</div>';
    }

    showModal('Create Refund', itemsHtml + '<button class="refund-add-btn" id="refund-add-item">+ Add Item</button>', {
        confirmText: 'Create Refund',
        disableConfirm: refundBuilderItems.length === 0,
        onConfirm: () => {
            if (refundBuilderItems.length === 0) return;
            fetch('https://cuppa_admin/createRefund', {
                method: 'POST',
                body: JSON.stringify({ items: refundBuilderItems })
            });
        }
    });

    document.getElementById('refund-add-item').addEventListener('click', () => {
        showRefundItemPicker();
    });

    modalBody.querySelectorAll('.refund-item-remove').forEach(btn => {
        btn.addEventListener('click', (e) => {
            const idx = parseInt(e.target.dataset.idx);
            refundBuilderItems.splice(idx, 1);
            renderRefundBuilder();
        });
    });
}

function showRefundItemPicker() {
    showItemListModal('Add Item to Refund', fetchItems, (item, qty, meta) => {
        const entry = { name: item.name, label: item.label, count: qty };
        if (meta) entry.metadata = meta;
        refundBuilderItems.push(entry);
        renderRefundBuilder();
    }, { quantity: true, metadata: true, confirmLabel: 'Add' });
}

function showRefundCode(code) {
    showModal('Refund Created!', '<div class="refund-code-box"><div class="refund-code-label">Refund Code</div><div class="refund-code">' + code + '</div><button class="refund-code-copy" id="refund-copy-btn">Copy to Clipboard</button><div class="refund-code-hint">Share this code with the player. They can claim it with /refund ' + code + '</div></div>', {
        confirmText: 'Done',
        disableConfirm: true,
    });
    document.getElementById('refund-copy-btn').addEventListener('click', () => {
        if (typeof lib !== 'undefined' && lib.setClipboard) lib.setClipboard(code);
        else { navigator.clipboard.writeText(code).catch(() => {}); }
        document.getElementById('refund-copy-btn').textContent = 'Copied!';
    });
}

function showRefundClaimPicker(code, refundId, items) {
    let claimItems = items.map(it => ({ ...it, selected: true, wantCount: it.count || 1 }));
    function render() {
        let html = '<div class="refund-items">';
        claimItems.forEach((item, i) => {
            const maxCount = item.count || 1;
            const meta = item.metadata && item.metadata.serial ? ' #' + item.metadata.serial : '';
            html += '<div class="refund-item-row">' +
                '<label class="refund-claim-check"><input type="checkbox" data-idx="' + i + '"' + (item.selected ? ' checked' : '') + '></label>' +
                '<div class="refund-item-info"><span class="refund-item-name">' + (item.label || item.name) + '</span>' +
                '<span class="refund-item-count">x' + maxCount + '</span>' +
                (meta ? '<span class="refund-item-meta">' + meta + '</span>' : '') +
                '</div></div>';
        });
        html += '</div>';

        showModal('Claim Refund (' + code + ')', html, {
            confirmText: 'Claim Selected',
            onConfirm: () => {
                const toClaim = claimItems.filter(it => it.selected).map(it => ({
                    name: it.name,
                    count: it.wantCount,
                    metadata: it.metadata,
                }));
                if (toClaim.length === 0) return;
                fetch('https://cuppa_admin/confirmClaimRefund', {
                    method: 'POST',
                    body: JSON.stringify({ code: code, refundId: refundId, items: toClaim })
                });
            }
        });

        modalBody.querySelectorAll('.refund-claim-check input').forEach(cb => {
            cb.addEventListener('change', (e) => {
                const idx = parseInt(e.target.dataset.idx);
                claimItems[idx].selected = e.target.checked;
            });
        });
    }
    render();
}

function openViewRefunds() {
    showModal('Active Refunds', '<div class="refund-empty" id="refund-loading">Loading...</div>', { disableConfirm: true });
    fetch('https://cuppa_admin/getRefunds', { method: 'POST', body: '{}' });
}

function renderRefundsList(list) {
    if (!list || list.length === 0) {
        modalBody.innerHTML = '<div class="refund-empty">No active refunds</div>';
        modalConfirm.style.display = 'none';
        return;
    }
    let html = '<div class="refund-view-list">';
    list.forEach(r => {
        const hrs = Math.floor(r.remaining / 3600);
        const mins = Math.floor((r.remaining % 3600) / 60);
        const timeStr = hrs > 0 ? hrs + 'h ' + mins + 'm' : mins + 'm';
        html += '<div class="refund-view-item"><div class="refund-view-info"><span class="refund-view-code" data-code="' + r.code + '" title="Click to copy">' + r.code + '</span><span class="refund-view-details">' + r.totalItems + ' item(s) | by ' + r.adminName + ' | expires in ' + timeStr + '</span></div><button class="refund-view-revoke" data-code="' + r.code + '">Revoke</button></div>';
    });
    html += '</div>';
    modalBody.innerHTML = html;
    modalConfirm.style.display = 'none';
    modalBody.querySelectorAll('.refund-view-code').forEach(el => {
        el.addEventListener('click', () => {
            const code = el.dataset.code;
            if (typeof lib !== 'undefined' && lib.setClipboard) lib.setClipboard(code);
            else { navigator.clipboard.writeText(code).catch(() => {}); }
            el.style.color = '#4caf50';
            el.textContent = code + ' ✓';
            setTimeout(() => { el.style.color = ''; el.textContent = code; }, 1200);
        });
    });
    modalBody.querySelectorAll('.refund-view-revoke').forEach(btn => {
        btn.addEventListener('click', (e) => {
            const code = e.target.dataset.code;
            fetch('https://cuppa_admin/revokeRefund', {
                method: 'POST',
                body: JSON.stringify({ code: code })
            });
            e.target.textContent = 'Revoked';
            e.target.disabled = true;
            e.target.style.opacity = '0.4';
        });
    });
}

// ── Data fetchers ──
function fetchItems() {
    return new Promise((resolve) => {
        if (cachedItems) return resolve(cachedItems);
        const handler = (e) => {
            if (e.data.action === 'itemList') {
                window.removeEventListener('message', handler);
                cachedItems = e.data.items || [];
                resolve(cachedItems);
            }
        };
        window.addEventListener('message', handler);
        fetch('https://cuppa_admin/getItems', { method: 'POST', body: '{}' });
    });
}

function fetchJobs() {
    return new Promise((resolve) => {
        if (cachedJobs) return resolve(cachedJobs);
        const handler = (e) => {
            if (e.data.action === 'jobList') {
                window.removeEventListener('message', handler);
                cachedJobs = e.data.jobs || [];
                resolve(cachedJobs);
            }
        };
        window.addEventListener('message', handler);
        fetch('https://cuppa_admin/getJobs', { method: 'POST', body: '{}' });
    });
}

function fetchGangs() {
    return new Promise((resolve) => {
        if (cachedGangs) return resolve(cachedGangs);
        const handler = (e) => {
            if (e.data.action === 'gangList') {
                window.removeEventListener('message', handler);
                cachedGangs = e.data.gangs || [];
                resolve(cachedGangs);
            }
        };
        window.addEventListener('message', handler);
        fetch('https://cuppa_admin/getGangs', { method: 'POST', body: '{}' });
    });
}

// ── Modal builders ──
function showItemListModal(title, fetcher, onSelect, opts) {
    opts = opts || {};
    const showQty = opts.quantity !== false;
    const showMeta = opts.metadata || false;
    const confirmLabel = opts.confirmLabel || 'Confirm';

    let qtyHtml = showQty ? '<div class="modal-qty-row"><label>Qty</label><input type="number" id="modal-qty" value="1" min="1" max="9999"></div>' : '';
    let metaHtml = showMeta ? '<div class="modal-qty-row"><label>Serial</label><input type="text" id="modal-meta-serial" placeholder="Optional"></div>' : '';

    showModal(title,
        '<div class="modal-search"><input type="text" id="modal-search" placeholder="Search..."></div>' +
        qtyHtml + metaHtml +
        '<div class="modal-list" id="modal-list"></div><div class="modal-list-empty" id="modal-loading">Loading...</div>',
        { confirmText: confirmLabel, disableConfirm: true }
    );

    fetcher().then((items) => {
        const listEl = document.getElementById('modal-list');
        const loadingEl = document.getElementById('modal-loading');
        const searchEl = document.getElementById('modal-search');
        const qtyEl = document.getElementById('modal-qty');
        if (!listEl) return;
        if (loadingEl) loadingEl.style.display = 'none';

        let selectedItem = null;

        function getQty() {
            return qtyEl ? Math.max(1, Math.min(9999, parseInt(qtyEl.value) || 1)) : 1;
        }

        function getMeta() {
            if (!showMeta) return undefined;
            const serial = document.getElementById('modal-meta-serial');
            if (serial && serial.value.trim()) return { serial: serial.value.trim() };
            return undefined;
        }

        function renderList(filter) {
            listEl.innerHTML = '';
            const lower = (filter || '').toLowerCase();
            const filtered = lower ? items.filter(i => (i.label || i.name).toLowerCase().includes(lower) || i.name.toLowerCase().includes(lower)) : items;
            if (filtered.length === 0) {
                listEl.innerHTML = '<div class="modal-list-empty">No results</div>';
                return;
            }
            filtered.forEach(item => {
                const el = document.createElement('div');
                el.className = 'modal-list-item';
                el.innerHTML = '<span class="item-label">' + (item.label || item.name) + '</span><span class="item-name">' + item.name + '</span>';
                el.addEventListener('click', () => {
                    listEl.querySelectorAll('.modal-list-item').forEach(e => e.classList.remove('selected'));
                    el.classList.add('selected');
                    selectedItem = item;
                    modalConfirm.disabled = false;
                });
                listEl.appendChild(el);
            });
        }

        renderList('');
        if (searchEl) {
            searchEl.addEventListener('input', () => renderList(searchEl.value));
        }

        modalConfirm.onclick = () => {
            if (selectedItem) {
                hideModal();
                onSelect(selectedItem, getQty(), getMeta());
            }
        };
    });
}

function showInputModal(title, fields, onConfirm) {
    let html = '';
    fields.forEach(f => {
        html += '<div class="modal-input-group"><label>' + f.label + '</label>';
        if (f.type === 'select') {
            html += '<select id="modal-field-' + f.id + '">';
            f.options.forEach(o => {
                html += '<option value="' + o.value + '">' + o.label + '</option>';
            });
            html += '</select>';
        } else {
            html += '<input type="' + (f.type || 'text') + '" id="modal-field-' + f.id + '" placeholder="' + (f.placeholder || '') + '" value="' + (f.value || '') + '"' + (f.min != null ? ' min="' + f.min + '"' : '') + (f.max != null ? ' max="' + f.max + '"' : '') + '>';
        }
        if (f.hint) html += '<div class="modal-hint">' + f.hint + '</div>';
        html += '</div>';
    });

    showModal(title, html, {
        onConfirm: () => {
            const values = {};
            fields.forEach(f => {
                const el = document.getElementById('modal-field-' + f.id);
                values[f.id] = f.type === 'number' ? parseFloat(el.value) : el.value;
            });
            hideModal();
            onConfirm(values);
        }
    });
}

// ── Command modal handlers ──
function openCommandModal(cmd, playerId) {
    switch (cmd) {
        case 'giveitem':
            showItemListModal('Give Item', fetchItems, (item, qty) => {
                submitCommand('giveitem ' + item.name + ' ' + qty + ' ' + playerId);
            }, { quantity: true });
            break;

        case 'givecash':
            showInputModal('Give Cash', [
                { id: 'amount', label: 'Amount ($)', type: 'number', placeholder: '1000', min: 1, max: 10000000 },
            ], (vals) => {
                const amount = Math.max(1, Math.min(10000000, vals.amount || 0));
                if (amount > 0) submitCommand('givecash ' + amount + ' ' + playerId);
            });
            break;

        case 'givebank':
            showInputModal('Give Bank', [
                { id: 'amount', label: 'Amount ($)', type: 'number', placeholder: '1000', min: 1, max: 10000000 },
            ], (vals) => {
                const amount = Math.max(1, Math.min(10000000, vals.amount || 0));
                if (amount > 0) submitCommand('givebank ' + amount + ' ' + playerId);
            });
            break;

        case 'setjob':
            showItemListModal('Set Job', fetchJobs, (job) => {
                showInputModal('Set Job — ' + job.label, [
                    { id: 'grade', label: 'Grade', type: 'number', value: '0', min: 0, max: 100, placeholder: '0' },
                ], (vals) => {
                    const grade = Math.max(0, vals.grade || 0);
                    submitCommand('setjob ' + job.name + ' ' + grade + ' ' + playerId);
                });
            }, { quantity: false });
            break;

        case 'setgang':
            showItemListModal('Set Gang', fetchGangs, (gang) => {
                showInputModal('Set Gang — ' + gang.label, [
                    { id: 'grade', label: 'Grade', type: 'number', value: '0', min: 0, max: 100, placeholder: '0' },
                ], (vals) => {
                    const grade = Math.max(0, vals.grade || 0);
                    submitCommand('setgang ' + gang.name + ' ' + grade + ' ' + playerId);
                });
            }, { quantity: false });
            break;

        case 'setmodel':
            showInputModal('Set Model', [
                { id: 'model', label: 'Ped Model', type: 'text', placeholder: 'e.g. a_m_m_skidrow_01' },
            ], (vals) => {
                if (vals.model) submitCommand('setmodel ' + vals.model + ' ' + playerId);
            });
            break;

        case 'car':
            showInputModal('Spawn Vehicle', [
                { id: 'model', label: 'Vehicle Model', type: 'text', placeholder: 'e.g.adder' },
            ], (vals) => {
                if (vals.model) submitCommand('car ' + vals.model + ' ' + playerId);
            });
            break;

        case 'kick':
            showInputModal('Kick Player', [
                { id: 'reason', label: 'Reason', type: 'text', placeholder: 'Reason (optional)' },
            ], (vals) => {
                const reason = vals.reason || 'No reason provided';
                submitCommand('kick ' + reason + ' ' + playerId);
            });
            break;

        case 'ban':
            showInputModal('Ban Player', [
                { id: 'reason', label: 'Reason', type: 'text', placeholder: 'Reason (optional)' },
                { id: 'duration', label: 'Duration', type: 'text', placeholder: 'e.g. 24h, 7d, 1m (blank = permanent)', hint: 'h = hours, d = days, m = months, y = years' },
            ], (vals) => {
                const reason = vals.reason || 'No reason provided';
                const dur = vals.duration ? ' ' + vals.duration : '';
                submitCommand('ban ' + reason + dur + ' ' + playerId);
            });
            break;

        case 'armor':
            showInputModal('Set Armor', [
                { id: 'amount', label: 'Armor (0-100)', type: 'number', value: '100', min: 0, max: 100, placeholder: '100' },
            ], (vals) => {
                const amount = Math.max(0, Math.min(100, vals.amount || 100));
                submitCommand('armor ' + amount + ' ' + playerId);
            });
            break;
    }
}

// ── Window Drag ──
let isDragging = false;
let dragX = 0;
let dragY = 0;

header.addEventListener('mousedown', (e) => {
    if (e.target.closest('#close-btn') || e.target.closest('#settings-btn')) return;
    isDragging = true;
    const rect = terminal.getBoundingClientRect();
    dragX = e.clientX - rect.left;
    dragY = e.clientY - rect.top;
    terminal.style.left = rect.left + 'px';
    terminal.style.top = rect.top + 'px';
    terminal.classList.add('positioned');
    e.preventDefault();
});

// ── Window Resize ──
let isResizing = false;
let resizeDir = '';
let resizeStartX = 0;
let resizeStartY = 0;
let resizeStartRect = null;

document.querySelectorAll('.resize-handle').forEach((h) => {
    h.addEventListener('mousedown', (e) => {
        isResizing = true;
        resizeDir = h.dataset.dir;
        resizeStartX = e.clientX;
        resizeStartY = e.clientY;
        resizeStartRect = terminal.getBoundingClientRect();
        terminal.style.left = resizeStartRect.left + 'px';
        terminal.style.top = resizeStartRect.top + 'px';
        terminal.classList.add('positioned');
        e.preventDefault();
        e.stopPropagation();
    });
});

// ── Divider Drag ──
let isDividerDragging = false;
let dividerStartX = 0;
let dividerStartWidth = 0;

divider.addEventListener('mousedown', (e) => {
    isDividerDragging = true;
    dividerStartX = e.clientX;
    dividerStartWidth = right.offsetWidth;
    divider.classList.add('dragging');
    e.preventDefault();
});

// ── Global mouse handlers ──
document.addEventListener('mousemove', (e) => {
    if (isDragging) {
        const tw = terminal.offsetWidth;
        const th = terminal.offsetHeight;
        const minVisible = 100;
        let newLeft = e.clientX - dragX;
        let newTop = e.clientY - dragY;
        newLeft = Math.max(-tw + minVisible, Math.min(window.innerWidth - minVisible, newLeft));
        newTop = Math.max(-th + minVisible, Math.min(window.innerHeight - minVisible, newTop));
        terminal.style.left = newLeft + 'px';
        terminal.style.top = newTop + 'px';
    }

    if (isResizing && resizeStartRect) {
        const dx = e.clientX - resizeStartX;
        const dy = e.clientY - resizeStartY;
        const r = resizeStartRect;
        let left = r.left, top = r.top, w = r.width, h = r.height;

        if (resizeDir.includes('e')) w = Math.max(700, r.width + dx);
        if (resizeDir.includes('w')) { w = Math.max(700, r.width - dx); left = r.left + r.width - w; }
        if (resizeDir.includes('s')) h = Math.max(400, r.height + dy);
        if (resizeDir.includes('n')) { h = Math.max(400, r.height - dy); top = r.top + r.height - h; }

        terminal.style.left = left + 'px';
        terminal.style.top = top + 'px';
        terminal.style.width = w + 'px';
        terminal.style.height = h + 'px';
    }

    if (isDividerDragging) {
        const dx = e.clientX - dividerStartX;
        const maxW = terminal.offsetWidth - dividerStartWidth - 60;
        const newWidth = Math.max(180, Math.min(maxW, dividerStartWidth - dx));
        right.style.width = newWidth + 'px';
    }
});

document.addEventListener('mouseup', () => {
    if (isDragging) { isDragging = false; savePosition(); }
    if (isResizing) { isResizing = false; resizeStartRect = null; savePosition(); }
    if (isDividerDragging) { isDividerDragging = false; divider.classList.remove('dragging'); saveDivider(); }
});

// ── Settings panel ──
settingsBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    settingsOverlay.style.display = 'flex';
});

settingsClose.addEventListener('click', () => { settingsOverlay.style.display = 'none'; });
settingsOverlay.addEventListener('click', (e) => { if (e.target === settingsOverlay) settingsOverlay.style.display = 'none'; });

settingAccent.addEventListener('input', (e) => { settings.accent = e.target.value; applySettings(settings); saveSettings(settings); });
settingOpacity.addEventListener('input', (e) => { settings.opacity = parseInt(e.target.value); opacityVal.textContent = settings.opacity + '%'; applySettings(settings); saveSettings(settings); });
settingBlur.addEventListener('input', (e) => { settings.blur = parseInt(e.target.value); blurVal.textContent = settings.blur + 'px'; applySettings(settings); saveSettings(settings); });
settingsReset.addEventListener('click', () => {
    Object.assign(settings, { ...DEFAULTS });
    applySettings(settings); saveSettings(settings);
    settingAccent.value = settings.accent;
    settingOpacity.value = settings.opacity;
    settingBlur.value = settings.blur;
    opacityVal.textContent = settings.opacity + '%';
    blurVal.textContent = settings.blur + 'px';
});

// ── Toolbar ──
toolbar.addEventListener('click', (e) => {
    const btn = e.target.closest('button');
    if (!btn) return;
    const cmd = btn.dataset.cmd;
    if (!cmd) return;
    if (cmd === 'announce') {
        input.value = 'announce ';
        input.focus();
    } else if (cmd === 'refund') {
        openRefundBuilder();
    } else if (cmd === 'refunds') {
        openViewRefunds();
    } else if (TOOLBAR_AUTO_EXEC.includes(cmd)) {
        submitCommand(cmd);
    }
});

// ── Terminal open/close ──
function openTerminal() {
    const savedPos = loadPosition();
    if (savedPos) {
        terminal.style.left = savedPos.x + 'px';
        terminal.style.top = savedPos.y + 'px';
        terminal.style.width = savedPos.w + 'px';
        terminal.style.height = savedPos.h + 'px';
        terminal.classList.add('positioned');
    } else {
        terminal.style.left = '';
        terminal.style.top = '';
        terminal.style.width = '';
        terminal.style.height = '';
        terminal.classList.remove('positioned');
    }

    const savedDivider = loadDivider();
    if (savedDivider) right.style.width = savedDivider + 'px';

    terminal.classList.add('open');
    isOpen = true;
    input.value = '';
    historyIndex = -1;
    showPlayerList();
    startRefresh();
    setTimeout(() => input.focus(), 50);
}

function closeTerminal() {
    terminal.classList.remove('open');
    isOpen = false;
    input.value = '';
    hideSuggestions();
    stopRefresh();
}

function toggleTerminal() {
    if (isOpen) closeTerminal();
    else openTerminal();
}

// ── NUI message handler ──
window.addEventListener('message', (e) => {
    const d = e.data;
    if (d.action === 'open') openTerminal();
    if (d.action === 'close') closeTerminal();
    if (d.action === 'output') appendOutput(d.text, d.type || 'result');
    if (d.action === 'itemList' || d.action === 'jobList' || d.action === 'gangList') return;

    if (d.action === 'playerList') {
        players = d.players || [];
        if (panelPlayers.style.display !== 'none') renderPlayerList();
        if (viewingPlayer) {
            const updated = players.find(p => p.id === viewingPlayer.id);
            if (updated) { viewingPlayer = updated; renderDetailInfo(updated); }
        }
    }

    if (d.action === 'inventoryResult') {
        renderInventory(d.items, d.error);
    }

    if (d.action === 'refundCreated') {
        if (d.code) {
            showRefundCode(d.code);
        } else if (d.error) {
            appendOutput('Refund error: ' + d.error, 'error');
        }
    }

    if (d.action === 'refundsList') {
        renderRefundsList(d.list);
    }

    if (d.action === 'refundRevoked') {
        if (d.error) {
            appendOutput('Revoke error: ' + d.error, 'error');
        } else {
            appendOutput('Refund revoked successfully', 'success');
        }
    }

    if (d.action === 'refundClaimItems') {
        showRefundClaimPicker(d.code, d.refundId, d.items);
    }
});

// ── Global Escape handler ──
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
        if (modalOverlay.style.display !== 'none') { hideModal(); return; }
        if (settingsOverlay.style.display !== 'none') { settingsOverlay.style.display = 'none'; return; }
        if (isOpen) {
            e.preventDefault();
            e.stopPropagation();
            fetch('https://cuppa_admin/closeTerminal', { method: 'POST', body: '{}' });
        }
    }
});

// ── Output ──
function appendOutput(text, type) {
    const div = document.createElement('div');
    div.className = 'line ' + type;
    div.textContent = text;
    output.appendChild(div);
    output.scrollTop = output.scrollHeight;
}

// ── Panel switching ──
function showPlayerList() {
    panelPlayers.style.display = '';
    panelDetail.style.display = 'none';
    panelInventory.style.display = 'none';
    viewingPlayer = null;
    renderPlayerList();
}

function showDetail(player) {
    viewingPlayer = player;
    selectedPlayer = player.id;
    panelPlayers.style.display = 'none';
    panelDetail.style.display = '';
    panelInventory.style.display = 'none';
    detailTitle.textContent = '#' + player.id + ' ' + player.name;
    renderDetailInfo(player);
    renderDetailCommands(player.id);
}

function showInventory() {
    panelPlayers.style.display = 'none';
    panelDetail.style.display = 'none';
    panelInventory.style.display = '';
    invList.innerHTML = '<div class="inv-empty">Loading inventory...</div>';
    invWeight.textContent = '';
    fetch('https://cuppa_admin/requestInventory', {
        method: 'POST',
        body: JSON.stringify({ playerId: viewingPlayer.id })
    });
}

// ── Player list ──
function renderPlayerList() {
    playerListEl.innerHTML = '';
    players.forEach((p) => {
        const el = document.createElement('div');
        el.className = 'player-entry';
        const initials = (p.name || '??').split(' ').map(w => w[0]).join('').substring(0, 2).toUpperCase();
        el.innerHTML =
            '<div class="player-info">' +
                '<div class="player-avatar">' + initials + '</div>' +
                '<div>' +
                    '<div class="player-name"><span class="player-id">#' + p.id + '</span> ' + p.name + '</div>' +
                    '<div class="player-job">' + (p.job || 'Unemployed') + '</div>' +
                '</div>' +
            '</div>' +
            '<span class="player-arrow">&#8250;</span>';
        el.addEventListener('click', () => showDetail(p));
        playerListEl.appendChild(el);
    });
}

// ── Detail panel ──
function renderDetailInfo(p) {
    const healthPct = p.health ? Math.max(0, Math.round(((p.health - 100) / 100) * 100)) : 0;
    const healthClass = healthPct < 30 ? 'low' : '';
    detailInfo.innerHTML =
        '<div class="info-grid">' +
            '<div class="info-card"><div class="info-label">Job</div><div class="info-value">' + (p.job || 'Unemployed') + (p.jobGrade ? ' ' + p.jobGrade : '') + '</div></div>' +
            '<div class="info-card"><div class="info-label">Health</div><div class="info-value ' + healthClass + '">' + healthPct + '%</div></div>' +
            '<div class="info-card"><div class="info-label">Cash</div><div class="info-value cash">$' + ((p.cash || 0)).toLocaleString() + '</div></div>' +
            '<div class="info-card"><div class="info-label">Bank</div><div class="info-value cash">$' + ((p.bank || 0)).toLocaleString() + '</div></div>' +
            '<div class="info-card"><div class="info-label">Armor</div><div class="info-value">' + (p.armor || 0) + '%</div></div>' +
            (p.gang ? '<div class="info-card"><div class="info-label">Gang</div><div class="info-value">' + p.gang + '</div></div>' : '') +
        '</div>';
}

function renderDetailCommands(id) {
    detailCommands.innerHTML = '';

    const categories = [
        {
            title: 'Quick',
            cmds: [
                { cmd: 'heal', label: 'Heal' },
                { cmd: 'kill', label: 'Kill', cls: 'btn-danger' },
                { cmd: 'revive', label: 'Revive' },
                { cmd: 'armor', label: 'Armor' },
                { cmd: 'freeze', label: 'Freeze' },
                { cmd: 'godmode', label: 'Godmode' },
            ]
        },
        {
            title: 'Teleport',
            cmds: [
                { cmd: 'goto', label: 'Goto' },
                { cmd: 'bring', label: 'Bring' },
                { cmd: 'tp', label: 'TP To' },
            ]
        },
        {
            title: 'Vehicle',
            cmds: [
                { cmd: 'car', label: 'Car' },
                { cmd: 'fix', label: 'Fix' },
                { cmd: 'dv', label: 'Delete', cls: 'btn-danger' },
                { cmd: 'noclip', label: 'Noclip' },
            ]
        },
        {
            title: 'Economy',
            cmds: [
                { cmd: 'givecash', label: 'Give Cash' },
                { cmd: 'givebank', label: 'Give Bank' },
                { cmd: 'giveitem', label: 'Give Item' },
            ]
        },
        {
            title: 'Management',
            cmds: [
                { cmd: 'setjob', label: 'Set Job' },
                { cmd: 'setgang', label: 'Set Gang' },
                { cmd: 'setmodel', label: 'Set Model' },
                { cmd: 'visible', label: 'Visible' },
                { cmd: 'undo', label: 'Undo' },
            ]
        },
        {
            title: 'Moderation',
            cmds: [
                { cmd: 'kick', label: 'Kick', cls: 'btn-danger' },
                { cmd: 'ban', label: 'Ban', cls: 'btn-danger' },
                { cmd: 'inventory', label: 'Inventory', cls: 'btn-info' },
            ]
        },
        {
            title: 'Developer',
            cmds: [
                { cmd: 'vec2', label: 'Vec2' },
                { cmd: 'vec3', label: 'Vec3' },
                { cmd: 'vec4', label: 'Vec4' },
                { cmd: 'heading', label: 'Heading' },
                { cmd: 'names', label: 'Names', cls: 'btn-info' },
                { cmd: 'blips', label: 'Blips', cls: 'btn-info' },
            ]
        },
    ];

    categories.forEach(cat => {
        const section = document.createElement('div');
        section.className = 'cmd-category';
        section.innerHTML = '<div class="cmd-category-title">' + cat.title + '</div>';
        const btns = document.createElement('div');
        btns.className = 'cmd-buttons';

        cat.cmds.forEach(c => {
            const btn = document.createElement('button');
            btn.textContent = c.label;
            if (c.cls) btn.className = c.cls;
            btn.addEventListener('click', () => {
                if (c.cmd === 'inventory') {
                    showInventory();
                } else if (AUTO_EXEC.includes(c.cmd) && !MODAL_CMDS[c.cmd]) {
                    submitCommand(c.cmd + ' ' + id);
                } else if (MODAL_CMDS[c.cmd]) {
                    openCommandModal(c.cmd, id);
                } else {
                    input.value = c.cmd + ' ';
                    input.focus();
                }
            });
            btns.appendChild(btn);
        });

        section.appendChild(btns);
        detailCommands.appendChild(section);
    });
}

// ── Back buttons ──
document.getElementById('detail-back').addEventListener('click', showPlayerList);
document.getElementById('inv-back').addEventListener('click', () => {
    if (viewingPlayer) showDetail(viewingPlayer);
    else showPlayerList();
});

// ── Inventory add item ──
document.getElementById('inv-add-btn').addEventListener('click', () => {
    if (!viewingPlayer) return;
    const playerId = viewingPlayer.id;
    showItemListModal('Give Item', fetchItems, (item, qty) => {
        submitCommand('giveitem ' + item.name + ' ' + qty + ' ' + playerId);
        appendOutput('Gave ' + qty + 'x ' + (item.label || item.name) + ' to ' + viewingPlayer.name, 'success');
    }, { quantity: true });
});

// ── Inventory panel ──
function renderInventory(items, error) {
    invList.innerHTML = '';
    if (error) {
        invList.innerHTML = '<div class="inv-empty">' + error + '</div>';
        invWeight.textContent = '';
        return;
    }
    if (!items || items.length === 0) {
        invList.innerHTML = '<div class="inv-empty">No items</div>';
        invWeight.textContent = 'Empty';
        return;
    }

    let totalWeight = 0;
    items.forEach(item => { totalWeight += (item.weight || 0) * (item.count || 0); });
    invWeight.textContent = items.length + ' item(s) · ' + (totalWeight / 1000).toFixed(1) + ' kg';

    items.forEach(item => {
        const el = document.createElement('div');
        el.className = 'inv-entry';
        el.innerHTML =
            '<span>' +
                '<span class="inv-slot">#' + (item.slot || '?') + '</span>' +
                '<span class="inv-name">' + item.label + '</span>' +
                '<span class="inv-label">' + item.name + '</span>' +
            '</span>' +
            '<span class="inv-right">' +
                '<span class="inv-count">&times;' + item.count + '</span>' +
                '<button class="inv-remove-btn" data-slot="' + item.slot + '" data-name="' + item.name + '" title="Remove 1">&#10005;</button>' +
            '</span>';
        invList.appendChild(el);
    });

    invList.querySelectorAll('.inv-remove-btn').forEach(btn => {
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            const slot = parseInt(btn.dataset.slot);
            const name = btn.dataset.name;
            if (!viewingPlayer) return;
            fetch('https://cuppa_admin/removeItem', {
                method: 'POST',
                body: JSON.stringify({ playerId: viewingPlayer.id, slot: slot, name: name })
            });
        });
    });
}

closeBtn.addEventListener('click', () => {
    fetch('https://cuppa_admin/closeTerminal', { method: 'POST', body: '{}' });
});

// ── Input handling ──
input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
        e.preventDefault();
        const val = input.value.trim();
        if (!val) return;
        commandHistory.unshift(val);
        historyIndex = -1;
        submitCommand(val);
        input.value = '';
        hideSuggestions();
        return;
    }
    if (e.key === 'Tab') { e.preventDefault(); handleTab(); return; }
    if (e.key === 'ArrowUp') {
        e.preventDefault();
        if (suggestionsEl.classList.contains('visible')) navigateSuggestion(-1);
        else if (commandHistory.length > 0) {
            historyIndex = Math.min(historyIndex + 1, commandHistory.length - 1);
            input.value = commandHistory[historyIndex];
        }
        return;
    }
    if (e.key === 'ArrowDown') {
        e.preventDefault();
        if (suggestionsEl.classList.contains('visible')) navigateSuggestion(1);
        else {
            historyIndex = Math.max(historyIndex - 1, -1);
            input.value = historyIndex >= 0 ? commandHistory[historyIndex] : '';
        }
        return;
    }
    hideSuggestions();
});

input.addEventListener('input', () => {
    const val = input.value.trim();
    if (val.length > 0) {
        const parts = val.split(/\s+/);
        if (parts.length === 1) showCommandSuggestions(parts[0]);
        else hideSuggestions();
    } else {
        hideSuggestions();
    }
});

// ── Tab completion ──
function handleTab() {
    const val = input.value;
    const parts = val.split(/\s+/);
    if (parts.length === 1) {
        const matches = COMMANDS.filter((c) => c.startsWith(parts[0].toLowerCase()));
        if (matches.length === 1) input.value = matches[0] + ' ';
        else if (matches.length > 1) showCommandSuggestions(parts[0]);
    } else {
        const items = suggestionsEl.querySelectorAll('.suggestion-item');
        if (items.length === 0) return;
        const texts = Array.from(items).map((el) => el.textContent.trim());
        const argStr = parts[parts.length - 1].toLowerCase();
        const matching = texts.filter((t) => t.toLowerCase().startsWith(argStr));
        if (matching.length === 1) {
            parts[parts.length - 1] = matching[0];
            input.value = parts.join(' ') + ' ';
            hideSuggestions();
        }
    }
}

// ── Suggestions ──
function showCommandSuggestions(prefix) {
    const lower = prefix.toLowerCase();
    const matches = COMMANDS.filter((c) => c.startsWith(lower));
    if (matches.length === 0 || (matches.length === 1 && matches[0] === lower)) { hideSuggestions(); return; }
    suggestionsEl.innerHTML = '';
    suggestionIndex = -1;
    matches.forEach((cmd) => {
        const div = document.createElement('div');
        div.className = 'suggestion-item';
        div.textContent = cmd;
        div.addEventListener('click', () => { input.value = cmd + ' '; input.focus(); hideSuggestions(); });
        suggestionsEl.appendChild(div);
    });
    suggestionsEl.classList.add('visible');
}

function navigateSuggestion(dir) {
    const items = suggestionsEl.querySelectorAll('.suggestion-item');
    if (items.length === 0) return;
    suggestionIndex += dir;
    if (suggestionIndex < 0) suggestionIndex = items.length - 1;
    if (suggestionIndex >= items.length) suggestionIndex = 0;
    items.forEach((el, i) => el.classList.toggle('selected', i === suggestionIndex));
}

function hideSuggestions() {
    suggestionsEl.classList.remove('visible');
    suggestionsEl.innerHTML = '';
    suggestionIndex = -1;
}

// ── Command submission ──
function submitCommand(raw) {
    let cmd = raw.trim();
    if (!cmd) return;
    appendOutput(cmd, 'cmd-line');

    const parts = cmd.split(/\s+/);
    const mainCmd = parts[0].toLowerCase();

    if (selectedPlayer && NEEDS_TARGET.includes(mainCmd) && !CUSTOM_ARGS.includes(mainCmd)) {
        const lastArg = parts[parts.length - 1];
        if (isNaN(parseInt(lastArg))) cmd = cmd + ' ' + selectedPlayer;
    }

    fetch('https://cuppa_admin/executeCommand', {
        method: 'POST',
        body: JSON.stringify({ command: cmd })
    });
}

// ── Player refresh ──
function startRefresh() {
    stopRefresh();
    refreshInterval = setInterval(() => {
        if (!isOpen) return;
        fetch('https://cuppa_admin/refreshPlayers', { method: 'POST', body: '{}' });
    }, 5000);
}

function stopRefresh() {
    if (refreshInterval) { clearInterval(refreshInterval); refreshInterval = null; }
}
