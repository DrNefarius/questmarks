/* questgraph -- shell, routing, and levels 1 and 2.
 *
 * THE ONE OBJECT: the trace. A row of marks, one per collapsed ladder
 * position, filled where the addon can observe that position and hollow where
 * it cannot. It is the same object at all three zooms and it never means
 * anything else:
 *
 *   level 1   one aggregate trace per area -- mark height is the fraction of
 *             that area's quests observable at position k
 *   level 2   one trace per quest, packed into CSS columns so position k sits
 *             at the same x in every column: a systematic failure at position
 *             3 draws as a vertical band across the screen
 *   level 3   the same law at full scale, as the spine of the document
 *
 * There is no bulk edit and no find-and-replace across quests, deliberately.
 * The dataset exists because 1003 pages were read instead of pattern-matched.
 */
'use strict';

(function () {

const $ = (s, r) => (r || document).querySelector(s);
const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
const esc = s => String(s === null || s === undefined ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;');

const api = {
  async get(u) { const r = await fetch(u); return r.json(); },
  async post(u, b) {
    const r = await fetch(u, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(b),
    });
    return r.json();
  },
};

const S = { stats: null, areas: null, area: null, quest: null };

const SVGNS = 'http://www.w3.org/2000/svg';
function svg(tag, attrs) {
  const e = document.createElementNS(SVGNS, tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  return e;
}

/* ------------------------------------------------------------- the trace */
/* Geometry is fixed and shared so that a mark means the same size everywhere.
   Cap at 24 positions -- the longest quest is 18 collapsed, so the cap only
   ever fires on data that has grown, and it fires visibly. */
const PITCH = 10, CELL = 6, CAP = 24;

function traceSvg(trace, opts) {
  opts = opts || {};
  const width = 12 + CAP * PITCH + 12;
  const s = svg('svg', { width: opts.width || 264, height: 16,
                         viewBox: `0 0 ${width} 16`, class: 'trace' });
  const base = 11;

  if (opts.flags) {
    /* Vertical ink = human debt. Horizontal ink = machine blindness. The two
       axes are deliberately orthogonal: a quest can be long on one and zero on
       the other, and conflating them would hide both. */
    const hgt = opts.flags >= 3 ? 10 : opts.flags === 2 ? 7 : 4;
    s.appendChild(svg('rect', { x: 0, y: base - hgt + 2, width: 2, height: hgt,
                                fill: 'var(--accent)' }));
  }
  if (opts.human) {
    s.appendChild(svg('circle', { cx: 7, cy: base - 2, r: 1.8,
                                  fill: 'var(--ink)' }));
  }
  if (opts.broken) {
    s.appendChild(svg('rect', { x: 4.5, y: base - 6, width: 5, height: 5,
                                fill: 'var(--accent)' }));
  }

  trace.slice(0, CAP).forEach((t, k) => {
    const x = 12 + k * PITCH;
    const grouped = (t.members || 1) > 1;
    const hgt = grouped ? 12 : 8;
    const y = base - hgt + 2;
    s.appendChild(svg('rect', {
      x, y, width: CELL, height: hgt,
      fill: t.lit ? 'var(--ink)' : 'none',
      stroke: t.lit ? 'none' : 'var(--hollow)',
      'stroke-width': 1,
    }));
    /* An optional step hangs BELOW the baseline -- literally the same
       off-the-spine statement the document makes at level 3. */
    for (let i = 0; i < (t.spurs || 0) && i < 3; i++) {
      s.appendChild(svg('rect', { x: x + i * 2.5, y: base + 3, width: 1.6,
                                  height: 3, fill: 'var(--hollow)' }));
    }
  });
  if (trace.length > CAP) {
    const t = svg('text', { x: 12 + CAP * PITCH + 2, y: base + 1,
                            'font-size': 9, fill: 'var(--hollow)' });
    t.textContent = '+' + (trace.length - CAP);
    s.appendChild(t);
  }
  return s;
}

/* -------------------------------------------------------------- routing */
function setCrumbs(parts) {
  const c = $('#crumbs');
  c.innerHTML = '';
  parts.forEach((p, i) => {
    if (i) c.appendChild(Object.assign(document.createElement('span'),
      { className: 'sep', textContent: '›' }));
    if (p.href) {
      const a = document.createElement('a');
      a.href = p.href; a.textContent = p.text;
      c.appendChild(a);
    } else {
      const s = document.createElement('span');
      s.className = 'here'; s.textContent = p.text;
      c.appendChild(s);
    }
  });
}

function show(view) {
  $$('.view').forEach(v => v.classList.toggle('on', v.id === 'v-' + view));
}

async function route() {
  const h = location.hash.slice(1);
  closeStrip();
  /* Navigating away retires the post-commit notice; QG_AFTER_COMMIT calls
     openQuest() directly rather than route(), so this cannot clear its own. */
  const pc = $('#post-commit');
  if (pc) pc.innerHTML = '';
  if (h.startsWith('q/')) return openQuest(h.slice(2));
  if (h.startsWith('a/')) return openArea(decodeURIComponent(h.slice(2)));
  if (h === 'play') { show('play'); setCrumbs([{ text: 'from play' }]); return; }
  if (h === 'edits') { show('edits'); setCrumbs([{ text: 'corrections' }]); return loadLedger(); }
  return openAreas();
}
function closeStrip() { const s = $('#strip'); if (s) s.remove(); }

window.addEventListener('hashchange', route);

/* ------------------------------------------------------------- level 1 */
async function openAreas() {
  show('areas');
  setCrumbs([{ text: 'areas' }]);
  if (!S.areas) S.areas = await api.get('/api/areas');
  const { areas, stats } = S.areas;
  S.stats = stats;

  const tot = areas.reduce((a, r) => a + r.quests, 0);
  const broken = areas.reduce((a, r) => a + (r.bands.broken || 0), 0);
  const stalls = areas.reduce((a, r) => a + (r.bands.stalls || 0), 0);
  const flagged = areas.reduce((a, r) => a + (r.bands.flagged || 0), 0);

  const fresh = stats.freshness && stats.freshness.stale || [];

  $('#areas-body').innerHTML = `
  ${fresh.length ? `<div class="banner acc"><b>the shipped data is behind the
    reasoning.</b> ${fresh.map(esc).join('<br>')}
    <button class="act" id="rebuild" style="margin-left:8px">rebuild now</button>
    <div id="rebuild-out"></div></div>` : ''}

  <p class="lede"><b>${tot}</b> quests were read from the wiki.
    <b>${broken}</b> cannot be trusted, <b>${stalls}</b> stall part-way through,
    and <b>${flagged}</b> are waiting on a judgement a reader could not make.
    Pick where to look.</p>

  <table class="areas"><thead><tr>
    <td class="name caps">area</td>
    <td class="agg caps">can the marker move?</td>
    <td class="n caps" title="a name does not resolve">broken</td>
    <td class="n caps" title="observable, then five or more positions dark">stalls</td>
    <td class="n caps" title="a reader flagged a judgement call">flagged</td>
    <td class="n caps" title="no observable evidence -- usually correct">dark</td>
    <td class="n caps">quests</td>
  </tr></thead><tbody id="area-rows"></tbody></table>

  <p class="hint">The bars are the fraction of each area's quests whose marker
    can still move at position 1, 2, 3&hellip; A profile that starts high and
    falls away is the normal shape. A flat hollow line from the first position
    is an extraction failure at the scale of a whole area.</p>
  <p class="hint">Missions &mdash; 438 rows across 15 areas &mdash; are not
    authored here and cannot be corrected with this tool.</p>`;

  if (fresh.length) $('#rebuild').onclick = rebuild;

  const tb = $('#area-rows');
  areas.forEach(a => {
    const tr = document.createElement('tr');
    tr.onclick = () => { location.hash = 'a/' + a.area; };

    const nm = document.createElement('td');
    nm.className = 'name';
    nm.textContent = a.area.replace('_', ' ');
    tr.appendChild(nm);

    const ag = document.createElement('td');
    ag.className = 'agg';
    ag.appendChild(aggregateSvg(a.aggregate));
    tr.appendChild(ag);

    [['broken', a.bands.broken], ['stalls', a.bands.stalls],
     ['flagged', a.bands.flagged], ['dark', a.bands.dark]]
      .forEach(([k, v]) => {
        const td = document.createElement('td');
        td.className = 'n' + (!v ? ' zero' : (k === 'broken' && v ? ' hot' : ''));
        td.textContent = v || 0;
        tr.appendChild(td);
      });
    const q = document.createElement('td');
    q.className = 'n'; q.textContent = a.quests;
    tr.appendChild(q);
    tb.appendChild(tr);
  });
}

function aggregateSvg(agg) {
  const s = svg('svg', { width: 250, height: 18, viewBox: '0 0 250 18' });
  agg.slice(0, 24).forEach((f, k) => {
    const x = 2 + k * 10;
    const hgt = Math.round(10 * f);
    if (hgt <= 0) {
      s.appendChild(svg('rect', { x, y: 12, width: 6, height: 1,
                                  fill: 'var(--hollow)' }));
    } else {
      s.appendChild(svg('rect', { x, y: 13 - hgt, width: 6, height: hgt,
                                  fill: 'var(--ink)' }));
    }
  });
  return s;
}

async function rebuild() {
  const out = $('#rebuild-out');
  out.textContent = 'building…';
  const r = await api.post('/api/build', { full: false });
  out.innerHTML = `<span class="${r.ok ? '' : 'acc'}">${r.ok ? 'rebuilt' : 'FAILED'}</span>`;
  S.areas = null; S.area = null;
  if (r.ok) openAreas();
}

/* ------------------------------------------------------------- level 2 */
const BAND_TEXT = {
  broken: ['cannot be trusted',
    'a name does not resolve, so a marker is silently absent right now'],
  stalls: ['stalls mid-quest',
    'observable, then five or more positions dark, so the marker visibly stops'],
  flagged: ['awaiting judgement',
    'a reader recorded a call they could not make with confidence'],
  dark: ['never moves',
    'no observable evidence anywhere. Usually correct: the mark sits one past '
    + 'the giver for the whole quest, which is the honest answer'],
  quiet: ['nothing found', 'no signal of any kind'],
};
const BAND_ORDER = ['broken', 'stalls', 'flagged', 'dark', 'quiet'];

async function openArea(area) {
  show('area');
  setCrumbs([{ text: 'areas', href: '#' }, { text: area.replace('_', ' ') }]);
  S.area = await api.get('/api/area/' + encodeURIComponent(area));
  const byBand = {};
  S.area.quests.forEach(q => (byBand[q.band] = byBand[q.band] || []).push(q));

  const host = $('#area-body');
  host.innerHTML = `<p class="lede"><b>${S.area.quests.length}</b> quests in
    ${esc(area.replace('_', ' '))}. Each row is one quest: a mark per position,
    <b>filled</b> where the addon can see you finished it and hollow where it
    cannot. A long hollow run is a marker that cannot move.
    <label style="float:right;font-size:12px" class="quiet">
      <input type="checkbox" id="labels"> show titles</label></p>`;

  BAND_ORDER.forEach(b => {
    const rows = byBand[b] || [];
    if (!rows.length) return;
    const sec = document.createElement('div');
    sec.className = 'band ' + b;
    const [name, why] = BAND_TEXT[b];
    sec.innerHTML = `<h2><b>${esc(name)}</b><span class="c">${rows.length}</span>
      <span class="why">${esc(why)}</span></h2>`;
    const rack = document.createElement('div');
    rack.className = 'rack';
    rows.forEach(q => rack.appendChild(traceRow(q)));
    sec.appendChild(rack);
    host.appendChild(sec);
  });

  $('#labels').onchange = e => {
    $$('.rack').forEach(r => r.classList.toggle('labelled', e.target.checked));
  };
}

function traceRow(q) {
  const a = document.createElement('a');
  a.className = 'tr';
  a.href = '#q/' + q.qid;
  a.title = `${q.title}\n${q.reasons.join('; ') || 'nothing flagged'}`;
  a.appendChild(traceSvg(q.trace, {
    flags: (q.flags || []).length, human: q.human, broken: q.quarantine > 0,
  }));
  const l = document.createElement('span');
  l.className = 'lbl';
  l.textContent = q.title || q.qid;
  a.appendChild(l);
  return a;
}

/* ------------------------------------------------------------- level 3 */
async function openQuest(qid) {
  show('quest');
  const payload = await api.get('/api/quest/' + qid);
  if (payload.error) {
    setCrumbs([{ text: 'areas', href: '#' }, { text: qid }]);
    $('#quest-body').innerHTML = `<div class="wrap"><div class="banner acc">
      <b>${esc(payload.error)}</b>: <code>${esc(qid)}</code>
      ${payload.index ? '<p class="quiet">It IS in the shipped index, so the '
        + 'addon knows it, but no authored record backs it. Every shipped row '
        + 'should have one, so the corpus and the index are out of step. '
        + 'Rebuild before reading anything into this.</p>' : ''}
      </div></div>`;
    return;
  }
  const area = qid.split('/')[1];
  setCrumbs([{ text: 'areas', href: '#' },
             { text: area.replace('_', ' '), href: '#a/' + area },
             { text: (payload.authored.source || {}).wiki_title || qid }]);

  /* Tier every named target once, so the sentence can mark an NPC the wiki
     has never heard of without a request per keystroke. */
  payload.entityTier = {};
  await Promise.all([...new Set(payload.authored.steps
    .map(s => (s.target || {}).name).filter(Boolean))]
    .map(async n => {
      const t = await api.get(`/api/entity_tier?page_id=${payload.page_id}`
        + `&name=${encodeURIComponent(n)}&type=npc`);
      payload.entityTier[n] = t.tier;
    }));

  S.quest = payload;
  window.QG_QUEST.render(payload, $('#quest-body'));
}

/* The commit already rebuilt, server-side, before this was called. All that is
   left is to say so -- and to say the ONE step the tool genuinely cannot do
   for you, which is making the running addon re-read the file.

   Rendered into #post-commit, which lives outside #quest-body precisely
   because draw() clears that host on every re-render. Putting it inside is
   what destroyed the old rebuild prompt one line after it was created. */
window.QG_AFTER_COMMIT = async function (entry, build) {
  S.areas = null; S.area = null;
  closeStrip();
  await openQuest(entry.qid);

  const host = $('#post-commit');
  const ok = build && build.ok;
  const failed = build && !build.ok
    ? (build.steps || []).filter(s => s.rc !== 0) : [];

  host.innerHTML = `<div class="banner ${ok ? 'info' : 'acc'}">
    <b>written</b> to <code>${esc(entry.file)}</code>, backed up first
    ${build ? (ok
      ? `&middot; <b>rebuilt</b> &mdash; <code>quest_steps.lua</code> and
         <code>quest_index.lua</code> are current.
         <br>In game: <code>lua reload questmarks</code> to make the running
         addon re-read them. That is the only step left, and it is the one
         thing this tool cannot do for you.`
      : `&middot; <b class="acc">THE REBUILD FAILED</b>, so the game is still
         loading the previous data. The record is saved and safe.`)
      : '&middot; not rebuilt'}
    <button class="link" id="pc-x" style="float:right">dismiss</button>
    ${failed.length ? '<div id="pc-detail"></div>' : ''}
  </div>`;

  if (failed.length) {
    $('#pc-detail').innerHTML = failed.map(s =>
      `<details open><summary><code>${esc(s.step)}</code> rc=${s.rc}</summary>
        <pre class="diff">${esc(s.out)}</pre></details>`).join('');
  }
  $('#pc-x').onclick = () => { host.innerHTML = ''; };
};

/* -------------------------------------------------------------- search */
let searchTimer = null;
$('#search').addEventListener('input', e => {
  clearTimeout(searchTimer);
  const q = e.target.value.trim();
  searchTimer = setTimeout(() => runSearch(q), 170);
});

async function runSearch(q) {
  const box = $('#results');
  if (!q) { box.innerHTML = ''; box.style.display = 'none'; return; }
  if (/^\w+\/\w+\/\d+$/.test(q)) { location.hash = 'q/' + q; return; }
  const rows = await api.get('/api/search?q=' + encodeURIComponent(q));
  box.style.display = '';
  box.innerHTML = rows.map(r => `<a href="#q/${esc(r.qid)}">
      <span class="t">${esc(r.title || r.qid)}</span>
      <span class="q">${esc(r.qid)}</span>
      <span class="q">${esc(r.start || '')}</span>
      ${r.human ? '<span class="q acc">human</span>' : ''}
    </a>`).join('') || '<a class="q">nothing</a>';
  box.onclick = () => { box.style.display = 'none'; $('#search').value = ''; };
}

/* ---------------------------------------------------------------- play */
$('#play-parse').onclick = async () => {
  renderPlay(await api.post('/api/play/parse', { text: $('#play-text').value }));
};
$('#play-log').onclick = async () => renderPlay(await api.get('/api/play'));

function renderPlay(r) {
  const host = $('#play-body');
  if (r.error) { host.innerHTML = `<div class="banner acc">${esc(r.error)}</div>`; return; }
  const unstamped = (r.boots || []).filter(b => !b.stamped).length;
  host.innerHTML = `
    ${unstamped ? `<div class="banner info">${unstamped} of ${r.boots.length}
      boot lines predate the version stamp, so anything under them cannot be
      attributed to a build.</div>` : ''}
    <div class="results">${(r.entries || []).map(e => e.authored
      ? `<a href="#q/${esc(e.qid)}">
          <span class="t">${esc(e.title || e.name)}</span>
          <span class="q">${esc(e.npc || '')}</span>
          <span class="q">${esc(e.state || '')}</span>
          <span class="q">${e.step ? 'step ' + e.step.idx + '/' + e.step.n : ''}</span>
         </a>`
      : `<a class="q"><span class="t">${esc(e.name)}</span>
          <span class="q">${esc(e.qid)}</span>
          <span class="q acc">no authored record</span></a>`
    ).join('') || '<a class="q">nothing recognised</a>'}</div>`;
}

/* -------------------------------------------------------------- ledger */
async function loadLedger() {
  const rows = await api.get('/api/ledger');
  $('#edits-body').innerHTML = `
    <p class="lede">Every correction this editor has made, in order, with the
      reason given for each.</p>
    <div class="results">${rows.length ? rows.map(e => e.reverted
      ? `<a class="q">reverted the edit of ${esc(e.reverted)} in ${esc(e.file)}</a>`
      : `<a href="#q/${esc(e.qid)}">
           <span class="q mono">${esc(e.at)}</span>
           <span class="t">${esc(e.title || e.qid)}</span>
           <span class="q">${esc(e.basis)}</span>
           <span class="q">${esc(e.reason)}</span>
         </a>`).join('') : '<a class="q">no corrections yet</a>'}</div>`;
}

/* ---------------------------------------------------------------- boot */
$$('[data-go]').forEach(b => b.onclick = () => { location.hash = b.dataset.go; });
document.addEventListener('keydown', e => {
  if (e.key === '/' && document.activeElement !== $('#search')) {
    e.preventDefault(); $('#search').focus();
  }
});
route();
})();
