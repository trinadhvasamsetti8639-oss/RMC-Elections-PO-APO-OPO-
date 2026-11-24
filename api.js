/* Shared backend client: Supabase (PostgreSQL) or local demo mode. Loaded by index.html and the LED displays. */
const C = window.APP_CONFIG || {};
const dist = (a, b, c, d) => { const r = Math.PI / 180, x = (c - a) * r, y = (d - b) * r, h = Math.sin(x / 2) ** 2 + Math.cos(a * r) * Math.cos(c * r) * Math.sin(y / 2) ** 2; return 12742000 * Math.asin(Math.sqrt(h)) };
const remote = (C.SUPABASE_URL && C.SUPABASE_ANON_KEY) ? (() => {
  const url = C.SUPABASE_URL.trim().replace(/\/rest\/v1\/?$/, '').replace(/\/+$/, '') + '/rest/v1/rpc/api', key = C.SUPABASE_ANON_KEY.trim();
  const hdr = { 'Content-Type': 'application/json', apikey: key };
  if (key.startsWith('eyJ')) hdr.Authorization = 'Bearer ' + key;   // legacy JWT anon keys only
  const call = async (fn, a = {}) => {
    let r, j;
    try { r = await fetch(url, { method: 'POST', headers: hdr, body: JSON.stringify({ fn, a: { u: ME && ME.u, p: ME && ME.p, ...a } }) }); j = await r.json(); }
    catch (e) { throw new Error('Cannot reach Supabase – check SUPABASE_URL, key and internet'); }
    if (!r.ok) throw new Error((j && (j.message || j.hint)) || 'Request failed (' + r.status + ')');
    return j;
  };
  return {
    login: (u, p) => call('login', { u, p }),
    settings: () => call('settings'),
    save: s => call('saveSettings', { s }),
    mark: x => call('mark', { x }),
    unmark: k => call('unmark', { k }),
    all: () => call('all'),
    assign: (g, r, id) => call('assign', { g: String(g), r, id }),
    unassign: (g, r) => call('unassign', { g: String(g), r }),
    distSet: (g, st, v) => call('distSet', { g: String(g), st, v }),
    dataGet: nm => call('dataGet', { nm }),
    dataSave: (nm, body) => call('dataSave', { nm, body }),
    report: () => call('report'),
    users: () => call('users'),
    addU: (n, p, r, g) => call('addU', { n, np: p, r, g }),
    delU: n => call('delU', { n })
  };
})() : (() => {
  const ld = () => JSON.parse(localStorage.getItem('demo5') || '{"users":{"admin":["admin123","admin",[]],"user":["user123","user",[]],"ro":["ro123","ro",["1/1","1/2","1/3","1/4","1/5"]],"sec":["sec123","sec",[]],"dist":["dist123","dist",[]],"display":["led123","display",[]]},"set":{"enabled":false,"radius":200},"att":{},"asg":[],"dist":[]}'),
    sv = d => localStorage.setItem('demo5', JSON.stringify(d)),
    ds = () => JSON.parse(localStorage.getItem('demoData5') || '{}');
  const ro = (d, r) => ME.role !== 'ro' || ME.groups.includes(String(r.group_no));
  return {
    login: async (u, p) => { const x = ld().users[u]; return x && x[0] === p ? { role: x[1], groups: x[2] } : null },
    settings: async () => ld().set,
    save: async s => { const d = ld(); d.set = s; sv(d) },
    mark: async x => {
      if (!['admin', 'user'].includes(ME.role)) throw Error('Not allowed to capture attendance');
      const d = ld(), s = d.set;
      if (s.enabled && s.lat != null) { if (x.lat == null) throw Error('Location is required'); const m = dist(s.lat, s.lng, x.lat, x.lng); if (m > s.radius) throw Error(`Outside allowed area (${Math.round(m)} m away, limit ${s.radius} m)`) }
      d.att[x.k] = { ...x, group_no: x.group_no != null ? String(x.group_no) : null, marked_by: ME.u, marked_at: Date.now() }; sv(d)
    },
    unmark: async k => {
      if (!['admin', 'user'].includes(ME.role)) throw Error('Not allowed to roll back attendance');
      const d = ld();
      if (k.startsWith('R')) {
        const rid = +k.slice(1);
        if (d.asg.some(a => a.rid === rid)) throw Error('Cannot roll back: this reserve staff is currently assigned to a polling station. Remove assignment first.');
      }
      delete d.att[k]; sv(d)
    },
    all: async () => { const d = ld(); return { att: Object.values(d.att).filter(r => ro(d, r)), asg: d.asg.filter(r => ro(d, r)), dist: d.dist.filter(r => ro(d, r)) } },
    assign: async (g, r, id) => {
      if (!['admin', 'sec'].includes(ME.role)) throw Error('Only the Administrative Secretary can assign reserve staff');
      const ps = String(g), d = ld();
      if (d.att['R' + id]?.status !== 'Attended') throw Error('Reserve staff is not present - cannot be assigned');
      const t = Object.values(d.att).find(a => a.kind === 'T' && String(a.group_no) === ps && a.role === r); if (t?.status === 'Attended') throw Error('That polling station member is already present');
      if (d.asg.some(a => a.rid === id && !(String(a.group_no) === ps && a.role === r))) throw Error('Reserve staff is already assigned to another polling station');
      d.asg = d.asg.filter(a => !(String(a.group_no) === ps && a.role === r)); d.asg.push({ group_no: ps, role: r, rid: id, assigned_by: ME.u, assigned_at: Date.now() }); sv(d)
    },
    unassign: async (g, r) => { const ps = String(g), d = ld(); d.asg = d.asg.filter(a => !(String(a.group_no) === ps && a.role === r)); sv(d) },
    distSet: async (g, st, v) => {
      const ps = String(g);
      if (!['admin', 'sec', 'dist', 'ro'].includes(ME.role)) throw Error('Not allowed');
      if (ME.role === 'ro' && !ME.groups.includes(ps)) throw Error('You can only update disbursement status for your allotted polling stations');
      const d = ld();
      st.forEach(n => { d.dist = d.dist.filter(x => !(String(x.group_no) === ps && x.stage === n)); if (v) d.dist.push({ group_no: ps, stage: n, by: ME.u, time: Date.now() }) });
      sv(d)
    },
    dataGet: async nm => ds()[nm] || null,
    dataSave: async (nm, body) => { const x = ds(); x[nm] = body; localStorage.setItem('demoData5', JSON.stringify(x)) },
    report: async () => { throw Error('Database reports need Supabase: set SUPABASE_URL and SUPABASE_ANON_KEY in config.js') },
    users: async () => Object.entries(ld().users).map(([username, v]) => ({ username, role: v[1], groups: v[2] })),
    addU: async (n, p, r, g) => { const d = ld(), o = d.users[n]; if (!p && !o) throw Error('A new user needs a password'); d.users[n] = [p || o[0], r, g]; sv(d) },
    delU: async n => { const d = ld(); delete d.users[n]; sv(d) }
  };
})();

/* Visible warning when running without the Supabase backend */
if (!(C.SUPABASE_URL && C.SUPABASE_ANON_KEY)) document.addEventListener('DOMContentLoaded', () => {
  const b = document.createElement('div');
  b.textContent = '⚠ DEMO MODE – data is saved only in this browser. Set SUPABASE_URL and SUPABASE_ANON_KEY in config.js to use the database.';
  b.style.cssText = 'position:fixed;bottom:0;left:0;right:0;z-index:99999;background:#b42318;color:#fff;font:600 13px system-ui;padding:6px 10px;text-align:center';
  document.body.appendChild(b);
});
