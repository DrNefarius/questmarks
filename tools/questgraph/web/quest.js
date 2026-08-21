/* Level 3 -- one quest as a numbered work instruction you can edit in place.
 *
 * Why a document and not a node-link diagram: the corpus says so. Median 4
 * steps, p75 6, and 442 of 1003 quests are three steps or fewer. A quest is a
 * short annotated procedure, not a topology, and boxes-and-arrows spends its
 * whole ink budget on the part that is already trivial (the order) while
 * cramping the part that is hard (the attachments and the doubt).
 *
 * The spine down the left of the body column carries the one thing a diagram
 * WOULD have been good for, and it is the answer to "why is my marker wrong":
 *
 *     solid  = this position grants evidence the addon can observe
 *     hollow = it does not, so the mark cannot move here
 *
 * A long hollow stretch is visible before a word is read. That is the same
 * mark, with the same meaning, as the traces on levels 1 and 2.
 *
 * Three renderings are measured facts rather than taste:
 *   - a `group` is ONE rung with N members, bulleted and never numbered --
 *     numbering an unordered set is the lie;
 *   - each member carries its OWN zone, because 84 of 141 groups span more
 *     than one, so any scheme that binds zone to the rung asserts a wrong zone
 *     for up to 20 members;
 *   - `optional` hangs off the spine, which runs straight past.
 */
'use strict';

(function () {

const QUEST = {};
let Q = null, M = null, SEL = null, PROB = [], PREVIEW = null, BUSY = false;

const KIND_SENTENCE = {
  talk: ['Talk to', 'npc'], trade: ['Trade to', 'npc'],
  turnin: ['Hand in to', 'npc'], examine: ['Examine', 'object'],
  fight: ['Defeat', 'none'], travel: ['Travel to', 'zone'],
  obtain: ['Obtain', 'none'], wait: ['Wait', 'none'],
  cutscene: ['Watch a cutscene at', 'npc'], other: ['Other, at', 'npc'],
};
const ROLE_VERB = { kill: 'defeat', drop: 'drops from', spawn: 'spawns' };

const esc = s => String(s === null || s === undefined ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;');

function h(tag, cls, txt) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (txt !== undefined && txt !== null) e.textContent = txt;
  return e;
}

/* ------------------------------------------------------------- rung model */
/* The client rebuilds rungs from the WORKING copy after every edit, using the
   same collapse rule the server uses, so the page reflects the edit rather
   than the last fetch. */
function rungsOf(rec) {
  const out = [];
  rec.steps.forEach(s => {
    if (s.optional) {
      if (out.length) { out[out.length - 1].spurs.push(s); return; }
      out.push({ group: null, members: [], spurs: [s], lead: true });
      return;
    }
    const last = out[out.length - 1];
    if (s.group !== null && last && last.group === s.group && last.members.length) {
      last.members.push(s);
      return;
    }
    out.push({ group: s.group, members: [s], spurs: [] });
  });
  return out;
}

const lit = s => {
  const e = s.evidence || {};
  return !!((e.all && e.all.length) || (e.alt && e.alt.length));
};
const rungLit = r => r.members.some(lit);

/* --------------------------------------------------------------- problems */
function problemsFor(n) {
  const pre = `steps[${n}]`;
  return PROB.filter(p => p.where === pre || p.where.startsWith(pre + '.'));
}
function questProblems() {
  return PROB.filter(p => !/^steps\[\d+\]/.test(p.where));
}

/* ------------------------------------------------------------------ render */
QUEST.render = function (payload, mount) {
  Q = payload;
  M = new window.QG_MODEL.Model(payload.authored);
  SEL = null; PROB = []; PREVIEW = null;
  draw(mount);
  refreshChecks();
};

function draw(mount) {
  const host = mount || document.getElementById('quest-body');
  const rec = M.rec;
  const rungs = rungsOf(rec);
  host.innerHTML = '';

  const wrap = h('div', 'wrap doc');
  host.appendChild(wrap);

  /* ---- preamble ----------------------------------------------------- */
  const pre = h('div', 'preamble');
  const t = h('h1', null, (rec.source || {}).wiki_title || Q.qid);
  pre.appendChild(t);

  const sub = h('div', 'sub');
  sub.innerHTML = `<code>${esc(Q.qid)}</code> &middot; `
    + `the game calls it <b>${esc((rec.identity || {}).dat_name || '?')}</b> &middot; `
    + `read from <a href="#layers" title="see the page, the reasoning, the facts and the shipped row">`
    + `page ${esc((rec.source || {}).page_id)} rev ${esc((rec.source || {}).revision_id)}</a>`;
  pre.appendChild(sub);

  /* The staleness warning belongs HERE as well as on the landing page. You are
     looking at the record you just corrected; if the shipped index still holds
     the version from before it, that is the single most useful thing on the
     screen and it must not be one navigation away. */
  const stale = (Q.freshness || {}).stale || [];
  if (stale.length) {
    const b = h('div', 'banner acc');
    b.innerHTML = '<b>the game is not loading this yet.</b> '
      + stale.map(esc).join('<br>')
      + ' <button class="act" id="qs-build">rebuild now</button>'
      + '<span id="qs-out" class="quiet"></span>';
    pre.appendChild(b);
    setTimeout(() => {
      const btn = document.getElementById('qs-build');
      if (!btn) return;
      btn.onclick = async () => {
        document.getElementById('qs-out').textContent = ' building…';
        const r = await fetch('/api/build', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ full: false }),
        }).then(x => x.json());
        document.getElementById('qs-out').textContent =
          r.ok ? ' rebuilt. Now `lua reload questmarks` in game.'
               : ' FAILED';
        if (r.ok) Q.freshness = { stale: [] };
      };
    }, 0);
  }

  if (rec.human) {
    const b = h('div', 'banner acc');
    b.innerHTML = `<b>corrected by a human</b> &mdash; ${esc(rec.human.by)}, `
      + `${esc(rec.human.edited_at)}, basis <b>${esc(rec.human.basis)}</b>. `
      + esc(rec.human.reason)
      + (rec.human.basis === 'game'
        ? '<br>Basis <b>game</b>: the page does not support this and play does. '
        + 'Ground truth &mdash; a re-read must not overwrite it.' : '');
    pre.appendChild(b);
  }

  pre.appendChild(gatesBlock());
  wrap.appendChild(pre);

  /* ---- the instruction ---------------------------------------------- */
  const ol = h('ol', 'rungs');
  let prevZone = null;
  let ord = 0;

  rungs.forEach((r, ri) => {
    const zone = r.members.length
      ? (r.members[0].zone || null) : (r.spurs[0] || {}).zone || null;
    /* A zone hop is drawn ONLY where it changes -- that is where the marker
       goes quiet and where a reader's mistake shows. 462 quests never hop, and
       for those this machinery draws nothing at all. */
    if (r.members.length && zone !== prevZone && ri > 0) {
      ol.appendChild(zoneHop(zone));
    }
    if (r.members.length) prevZone = zone;

    if (r.members.length) {
      const from = ord + 1;
      ord += r.members.length;
      ol.appendChild(rungEl(r, from, ord));
    }
    r.spurs.forEach(s => ol.appendChild(spurEl(s)));
  });

  wrap.appendChild(ol);
  wrap.appendChild(tailEl(rungs));

  const add = h('div', 'chips');
  const b = h('button', 'act', '+ add a step at the end');
  b.onclick = () => { const n = M.insertStep(M.rec.steps.length); select(n); };
  add.appendChild(b);
  wrap.appendChild(add);

  const qp = questProblems();
  if (qp.length) {
    const box = h('div', 'apparatus');
    qp.forEach(p => box.appendChild(probEl(p)));
    wrap.appendChild(box);
  }

  wrap.appendChild(layersEl());
  drawStrip();
}

function zoneHop(zone) {
  const li = h('li', 'zonehop');
  li.appendChild(h('span', null, zone ? '↓ ' + zone : '↓ zone unknown'));
  return li;
}

function gatesBlock() {
  const g = M.rec.gates || {};
  const box = h('div');
  const lbl = h('div', 'caps');
  lbl.textContent = 'before you can accept it';
  box.appendChild(lbl);
  const chips = h('div', 'chips');

  const chip = (text, onClick, onX, cls) => {
    const c = h('span', 'chip' + (cls ? ' ' + cls : ''));
    c.appendChild(h('span', null, text));
    if (onX) {
      const x = h('span', 'x', '×');
      x.onclick = e => { e.stopPropagation(); onX(); };
      c.appendChild(x);
    }
    if (onClick) c.onclick = e => onClick(e.currentTarget);
    chips.appendChild(c);
    return c;
  };

  (g.prev || []).forEach((p, i) => chip('after: ' + (p.title || '?'), null,
    () => { M.removePrev(i); redraw(); }));

  if (g.fame && g.fame.region) {
    chip(`fame: ${g.fame.region}${g.fame.level ? ' ' + g.fame.level : ''}`,
      a => window.QG_PICK.text(a, 'fame region', g.fame.region, v => {
        M.setGate('fame', v ? { region: v, level: g.fame.level,
                                raw: g.fame.raw } : null);
        redraw();
      }),
      () => { M.setGate('fame', null); redraw(); });
  }
  if (g.level) {
    chip('level ' + g.level,
      a => window.QG_PICK.text(a, 'level', String(g.level),
        v => { M.setGate('level', v); redraw(); }),
      () => { M.setGate('level', null); redraw(); });
  }
  (g.jobs || []).forEach(j => chip(j, null,
    () => { M.setGate('jobs', g.jobs.filter(x => x !== j)); redraw(); }));

  /* The craft gate. Shown because this tool exists to answer "why is my marker
     wrong", and a condition that greys a marker while being invisible here is
     the one thing that would make that question unanswerable -- the same
     reasoning as the trace row.

     Removable but not yet creatable: adding one needs a picker over
     res/skills.lua and res/synth_ranks.lua, and until more than one quest
     carries a craft gate a ghost chip would be a form nobody fills in. The
     record is still safe either way -- the model deep-clones and mutates, so an
     unknown gate survives a save untouched. */
  (g.craft || []).forEach((c, i) => chip(
    'craft: ' + (c.skill || '?') +
      (c.rank ? ' rank ' + c.rank : '') +
      (c.level != null ? ' skill ' + c.level : ''),
    null,
    () => { M.setGate('craft', (g.craft || []).filter((_, j) => j !== i));
            redraw(); }));
  if (g.repeatable) chip('repeatable', null,
    () => { M.setGate('repeatable', false); redraw(); });

  const start = M.rec.start || {};
  chip('starts at: ' + (start.npc || '(nobody)'),
    a => window.QG_PICK.entity(a, 'start NPC', start.npc,
      { pageId: Q.page_id, targetType: 'npc' },
      (_t, name) => { M.setStart('npc', name); redraw(); }),
    null, start.npc ? '' : 'ghost');

  /* An absent condition is DRAWN, because the ghost is the click target that
     creates it. A form you cannot see is a form you cannot fill in. */
  const addc = h('span', 'chip ghost');
  addc.appendChild(h('span', null, '+ condition'));
  addc.onclick = e => window.QG_PICK.choice(e.currentTarget, 'add a condition', [
    { value: 'prev', label: 'a quest that must come first' },
    { value: 'level', label: 'a level gate' },
    { value: 'jobs', label: 'a job gate' },
    { value: 'fame', label: 'a fame gate' },
    { value: 'repeatable', label: 'mark repeatable' },
  ], null, kind => {
    if (kind === 'repeatable') { M.setGate('repeatable', true); return redraw(); }
    window.QG_PICK.text(addc,
      kind === 'prev' ? 'quest title that must come first'
        : kind === 'jobs' ? 'job code, e.g. PLD' : kind, '', v => {
        if (!v) return;
        if (kind === 'prev') M.addPrev(v);
        else if (kind === 'jobs') M.setGate('jobs', (g.jobs || []).concat([v.toUpperCase()]));
        else if (kind === 'fame') M.setGate('fame', { region: v, level: null, raw: v });
        else M.setGate(kind, v);
        redraw();
      });
  });
  chips.appendChild(addc);
  box.appendChild(chips);
  return box;
}

function rungEl(r, from, to) {
  const s = r.members[0];
  const li = h('li', 'rung');
  const on = rungLit(r);
  if (on) li.classList.add('lit');
  if (SEL === s.n) li.classList.add('sel');
  const probs = r.members.flatMap(m => problemsFor(m.n));
  if (probs.some(p => p.level === 'error' || p.level === 'warn')) {
    li.classList.add('problem');
  }

  /* margin: zone only where it changes (the caller drew the hop), grid always */
  const zc = h('div', 'zone');
  if (r.members.length > 1) {
    const zs = [...new Set(r.members.map(m => m.zone).filter(Boolean))];
    zc.appendChild(h('span', null, zs.slice(0, 3).join(' · ')
      + (zs.length > 3 ? ` +${zs.length - 3}` : '')));
  } else {
    zc.appendChild(h('span', null, s.zone || ''));
    if (s.grid) zc.appendChild(h('span', 'grid', s.grid));
  }
  li.appendChild(zc);

  const num = h('div', 'num', r.members.length > 1 ? `${from}-${to}` : String(from));
  num.title = 'click for step actions';
  num.style.cursor = 'pointer';
  num.onclick = e => stepMenu(e.currentTarget, s.n, r);
  li.appendChild(num);

  const body = h('div', 'body');
  body.onclick = e => { if (!e.target.closest('.val,.chip,.pop')) select(s.n); };

  if (r.members.length > 1) {
    const hd = h('div', 'grouphdr');
    hd.textContent = 'in any order, ' + r.members.length + ' places';
    body.appendChild(hd);
    const ul = h('ul', 'members');
    r.members.forEach(m => {
      const mi = h('li', lit(m) ? 'lit' : '');
      const nm = h('span', 'val', m.target.name || '(unnamed)');
      nm.onclick = ev => { ev.stopPropagation(); editTarget(ev.currentTarget, m); };
      mi.appendChild(nm);
      if (m.zone) mi.appendChild(h('span', 'mz', m.zone + (m.grid ? ' ' + m.grid : '')));
      ul.appendChild(mi);
    });
    body.appendChild(ul);
  } else {
    body.appendChild(sentence(s));
  }

  body.appendChild(ledger(s, r));

  const app = h('div', 'apparatus');
  probs.forEach(p => app.appendChild(probEl(p)));
  if (s.note) app.appendChild(h('div', 'meta', s.note));
  if ((s.source_bullets || []).length) {
    app.appendChild(h('div', 'meta', 'wiki bullet ' + s.source_bullets.join(', ')));
  }
  body.appendChild(app);

  li.appendChild(body);
  return li;
}

function spurEl(s) {
  const li = h('li', 'rung opt' + (SEL === s.n ? ' sel' : ''));
  li.appendChild(h('div', 'zone', s.zone || ''));
  const num = h('div', 'num', '·');
  num.style.cursor = 'pointer';
  num.onclick = e => stepMenu(e.currentTarget, s.n, { members: [s], spurs: [] });
  li.appendChild(num);
  const body = h('div', 'body');
  body.onclick = e => { if (!e.target.closest('.val,.chip,.pop')) select(s.n); };
  const cap = h('div', 'caps');
  cap.textContent = 'optional';
  body.appendChild(cap);
  body.appendChild(sentence(s));
  body.appendChild(ledger(s, { members: [s] }));
  const app = h('div', 'apparatus');
  problemsFor(s.n).forEach(p => app.appendChild(probEl(p)));
  body.appendChild(app);
  li.appendChild(body);
  return li;
}

function sentence(s) {
  const p = h('p', 'sentence');
  const [verb] = KIND_SENTENCE[s.kind] || ['Other, at', 'npc'];

  const v = h('span', 'verb val', verb);
  v.onclick = e => {
    e.stopPropagation();
    window.QG_PICK.choice(e.currentTarget, 'what happens here',
      window.QG_MODEL.KINDS.map(k => ({ value: k, label: KIND_SENTENCE[k][0], hint: k })),
      s.kind, k => { M.setStepField(s.n, 'kind', k); redraw(); });
  };
  p.appendChild(v);
  p.appendChild(document.createTextNode(' '));

  const name = s.target.name;
  const tv = h('span', 'val' + (name ? '' : ' empty'), name || 'nobody named');
  if (name && Q.entityTier && Q.entityTier[name] === 'unknown'
      && s.target.type === 'npc') {
    tv.classList.add('unverified');
    tv.title = 'not linked anywhere in the wiki page cache';
  }
  tv.onclick = e => { e.stopPropagation(); editTarget(e.currentTarget, s); };
  p.appendChild(tv);

  if (s.zone || s.grid) {
    p.appendChild(document.createTextNode(' in '));
    const z = h('span', 'val' + (s.zone ? '' : ' empty'), s.zone || 'no zone');
    z.onclick = e => {
      e.stopPropagation();
      window.QG_PICK.resource(e.currentTarget, 'zone', { name: s.zone },
        r => { M.setStepField(s.n, 'zone', r.name); redraw(); });
    };
    p.appendChild(z);
    p.appendChild(document.createTextNode(' '));
    const gr = h('span', 'val' + (s.grid ? '' : ' empty'), s.grid || '');
    gr.onclick = e => {
      e.stopPropagation();
      window.QG_PICK.text(e.currentTarget, 'grid reference', s.grid,
        vv => { M.setStepField(s.n, 'grid', vv); redraw(); }, 'e.g. H-9');
    };
    p.appendChild(gr);
  } else {
    const z = h('span', 'val empty', ' · set a zone');
    z.onclick = e => {
      e.stopPropagation();
      window.QG_PICK.resource(e.currentTarget, 'zone', null,
        r => { M.setStepField(s.n, 'zone', r.name); redraw(); });
    };
    p.appendChild(z);
  }
  return p;
}

function editTarget(anchor, s) {
  window.QG_PICK.entity(anchor, 'who or what is targeted', s.target.name, {
    pageId: Q.page_id, targetType: s.target.type || 'npc', allowTypes: true,
    demote: [s.zone].concat((s.items || []).map(i => i.name)),
  }, (type, name) => { M.setTarget(s.n, type, name); redraw(); });
}

/* the ledger: needs / grants / mobs, at one x for the whole page */
function ledger(s, r) {
  const dl = h('dl', 'ledger');

  const row = (label, node, ghost) => {
    const dt = h('dt', ghost ? 'ghost' : '', label);
    dl.appendChild(dt);
    dl.appendChild(node);
  };

  /* needs */
  const needs = h('dd');
  const items = s.items || [], alts = s.items_alt || [];
  items.forEach((it, i) => needs.appendChild(entryChip(s, 'items', i, it)));
  if (alts.length) {
    needs.appendChild(h('span', 'or', 'or'));
    alts.forEach((it, i) => needs.appendChild(entryChip(s, 'items_alt', i, it)));
  }
  if (s.items_partial) {
    needs.appendChild(h('span', 'acc', ' …and more (list incomplete)'));
  }
  needs.appendChild(addChip('+', a => window.QG_PICK.resource(a, 'item', null,
    e => { M.addEntry(s.n, 'items', e); redraw(); },
    { count: true, kinds: true })));
  if (items.length) {
    needs.appendChild(addChip('+ or', a => window.QG_PICK.resource(a, 'item', null,
      e => { M.addEntry(s.n, 'items_alt', e); redraw(); },
      { count: true, kinds: true })));
  }
  row('needs', needs, !items.length && !alts.length);

  /* grants */
  const ev = s.evidence || {};
  const grants = h('dd');
  (ev.all || []).forEach((it, i) =>
    grants.appendChild(entryChip(s, 'evidence.all', i, it)));
  if ((ev.alt || []).length) {
    grants.appendChild(h('span', 'or', 'or'));
    (ev.alt || []).forEach((it, i) =>
      grants.appendChild(entryChip(s, 'evidence.alt', i, it)));
  }
  grants.appendChild(addChip('+', a => window.QG_PICK.resource(a, 'ki', null,
    e => { M.addEntry(s.n, 'evidence.all', e); redraw(); },
    { count: true, kinds: true })));
  row('grants', grants, !(ev.all || []).length && !(ev.alt || []).length);

  /* mobs */
  const mobs = h('dd');
  (s.mobs || []).forEach((m, i) => {
    const c = h('span', 'chip');
    c.appendChild(h('span', null,
      `${ROLE_VERB[m.role] || m.role} ${m.name}${m.count ? ' ×' + m.count : ''}`));
    c.onclick = e => window.QG_PICK.mob(e.currentTarget, m, { pageId: Q.page_id },
      (name, role, n) => { M.editMob(s.n, i, name, role, n); redraw(); },
      () => { M.removeMob(s.n, i); redraw(); });
    mobs.appendChild(c);
  });
  mobs.appendChild(addChip('+', a => window.QG_PICK.mob(a, null,
    { pageId: Q.page_id },
    (name, role, n) => { M.addMob(s.n, name, role, n); redraw(); })));
  row('mobs', mobs, !(s.mobs || []).length);

  return dl;
}

function entryChip(s, list, i, it) {
  const c = h('span', 'chip');
  c.appendChild(h('span', null,
    it.name + (it.count > 1 ? ' ×' + it.count : '')
    + (it.kind === 'ki' ? ' (key item)' : '')));
  const x = h('span', 'x', '×');
  x.onclick = e => { e.stopPropagation(); M.removeEntry(s.n, list, i); redraw(); };
  c.appendChild(x);
  c.onclick = e => window.QG_PICK.resource(e.currentTarget, it.kind, it,
    en => { M.editEntry(s.n, list, i, en); redraw(); },
    { count: true, kinds: true });
  return c;
}

function addChip(label, fn) {
  const c = h('span', 'chip ghost');
  c.appendChild(h('span', null, label));
  c.onclick = e => { e.stopPropagation(); fn(e.currentTarget); };
  return c;
}

function probEl(p) {
  const d = h('div', 'prob ' + p.level);
  d.appendChild(h('span', 'g',
    p.level === 'error' ? '✖' : p.level === 'warn' ? '⚠' : 'ℹ'));
  d.appendChild(h('span', null, p.text));
  return d;
}

function tailEl(rungs) {
  const box = h('div', 'terminator caps');
  const tier = (Q.validated || {}).conf;
  if (!M.rec.steps.length) {
    box.textContent = 'no walkthrough was extractable';
  } else if (tier === 1) {
    box.textContent = '// the walkthrough stops here (start-NPC only)';
  } else {
    box.textContent = '≡ end of the quest';
  }
  return box;
}

function stepMenu(anchor, n, r) {
  const s = M.step(n);
  window.QG_PICK.choice(anchor, 'step ' + n, [
    { value: 'after', label: '+ add a step after this' },
    { value: 'before', label: '+ add a step before this' },
    { value: 'opt', label: s.optional ? 'make it required' : 'make it optional' },
    { value: 'up', label: 'move up' },
    { value: 'down', label: 'move down' },
    { value: 'group', label: s.group ? 'ungroup' : 'group with the next step' },
    { value: 'note', label: 'edit the note' },
    { value: 'del', label: 'delete this step' },
  ], null, v => {
    if (v === 'after') select(M.insertStep(n));
    else if (v === 'before') select(M.insertStep(n - 1));
    else if (v === 'opt') { M.setStepField(n, 'optional', !s.optional); redraw(); }
    else if (v === 'up') select(M.moveStep(n, -1));
    else if (v === 'down') select(M.moveStep(n, 1));
    else if (v === 'group') {
      if (s.group) { M.setStepField(n, 'group', null); redraw(); }
      else {
        const nx = M.step(n + 1);
        const g = 'g' + n;
        M.setStepField(n, 'group', g);
        if (nx) M.setStepField(n + 1, 'group', g);
        redraw();
      }
    } else if (v === 'note') {
      window.QG_PICK.text(anchor, 'note', s.note,
        t => { M.setStepField(n, 'note', t); redraw(); });
    } else if (v === 'del') { M.deleteStep(n); redraw(); }
  });
}

function select(n) { SEL = n; redraw(); }

function redraw() {
  draw();
  refreshChecks();
}

/* ---------------------------------------------------- the four layers ---- */
function layersEl() {
  const d = h('details');
  d.id = 'layers';
  const sm = h('summary', 'caps');
  sm.textContent = 'the evidence, the reasoning, the facts and what shipped';
  d.appendChild(sm);
  const g = h('div', 'layers');
  const sec = (title, node) => {
    const s = h('section');
    s.appendChild(h('h3', null, title));
    const inn = h('div', 'in');
    inn.appendChild(node);
    s.appendChild(inn);
    g.appendChild(s);
  };
  sec('the page: what the wiki says', h('pre', 'page', Q.page || '(none)'));
  const notes = h('div');
  notes.appendChild(h('p', null, M.rec.notes || '(no notes)'));
  const fl = h('div', 'chips');
  (M.rec.review_flags || []).forEach(f => {
    const c = h('span', 'chip');
    c.appendChild(h('span', null, f));
    const x = h('span', 'x', '×');
    x.onclick = e => { e.stopPropagation(); M.removeFlag(f); redraw(); };
    c.appendChild(x);
    fl.appendChild(c);
  });
  fl.appendChild(addChip('+ flag', a => window.QG_PICK.text(a, 'review flag', '',
    v => { M.addFlag(v); redraw(); })));
  notes.appendChild(fl);
  const nb = h('button', 'act', 'edit the notes');
  nb.onclick = () => window.QG_PICK.text(nb, 'notes', M.rec.notes,
    v => { M.setNotes(v); redraw(); });
  notes.appendChild(nb);
  sec('the reasoning: what a reader made of it', notes);
  sec('the facts: what survived name resolution',
    h('pre', 'page', JSON.stringify(Q.validated, null, 1)));
  sec('shipped: what the addon loads',
    h('pre', 'page', JSON.stringify(Q.index, null, 1)));
  d.appendChild(g);
  return d;
}

/* ------------------------------------------------------- checks + commit */
let checkTimer = null;
function refreshChecks() {
  clearTimeout(checkTimer);
  checkTimer = setTimeout(async () => {
    if (!M.dirty()) { PROB = []; PREVIEW = null; drawStrip(); return; }
    const body = {
      qid: Q.qid, record: M.serialise(),
      basis: document.getElementById('e-basis')
        ? document.getElementById('e-basis').value : 'reading',
      reason: 'checking',
      author: localStorage.getItem('qg-author') || 'unknown',
    };
    const r = await fetch('/api/preview', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then(x => x.json()).catch(() => null);
    if (!r || !r.problems) return;
    /* The "reason too short" note is an artefact of the placeholder this
       background check sends -- it is a real refusal at commit and noise here. */
    PROB = r.problems.filter(p => p.where !== 'human.reason');
    PREVIEW = r;
    draw();
    drawStrip();
  }, 220);
}

function drawStrip() {
  let s = document.getElementById('strip');
  if (s) s.remove();
  if (!M || !M.dirty()) return;
  const wrap = h('div', 'stripwrap');
  wrap.id = 'strip';
  const box = h('div', 'panelbox');

  const head = h('div', 'strip');
  const changed = [...M.changed()];
  const n = h('span', 'n', changed.length + ' change' + (changed.length === 1 ? '' : 's'));
  head.appendChild(n);
  const renum = M.renumbered();
  if (renum.length) {
    head.appendChild(h('span', 'quiet',
      `steps renumbered: ${renum.map(r => r.from + '→' + r.to).join(', ')}`));
  }
  const errs = PROB.filter(p => p.level === 'error');
  if (errs.length) {
    head.appendChild(h('span', 'acc', errs.length + ' blocking'));
  }
  const grow = h('span', 'grow');
  head.appendChild(grow);

  const revert = h('button', 'act', 'discard');
  revert.onclick = () => {
    M = new window.QG_MODEL.Model(M.base);
    PROB = []; PREVIEW = null; redraw();
  };
  head.appendChild(revert);

  const review = h('button', 'act primary', 'review and commit');
  review.onclick = () => {
    box.classList.toggle('open');
    body.style.display = body.style.display === 'none' ? '' : 'none';
  };
  head.appendChild(review);
  box.appendChild(head);

  const body2 = h('div');
  const body = body2;
  body.style.display = 'none';

  body.appendChild(labelled('why did you change this?', (() => {
    const ta = h('textarea');
    ta.id = 'e-reason';
    ta.rows = 2;
    ta.placeholder = 'a future session reads this to decide whether to trust the record';
    return ta;
  })()));

  const row = h('div', 'chips');
  const basis = h('select', 'wide');
  basis.id = 'e-basis';
  basis.innerHTML =
    '<option value="reading">the page supports this &mdash; the machine read it wrong</option>'
    + '<option value="game">the page is WRONG &mdash; play says otherwise</option>';
  basis.style.maxWidth = '420px';
  row.appendChild(basis);
  const who = h('input');
  who.className = 'wide'; who.style.maxWidth = '160px';
  who.placeholder = 'your name';
  who.value = localStorage.getItem('qg-author') || '';
  who.onchange = () => localStorage.setItem('qg-author', who.value);
  row.appendChild(who);
  body.appendChild(row);

  if (PROB.length) {
    const pl = h('div', 'apparatus');
    PROB.forEach(p => pl.appendChild(probEl(p)));
    body.appendChild(pl);
  }

  if (PREVIEW && PREVIEW.diff) {
    body.appendChild(labelled('the diff that will be written', (() => {
      const pre = h('pre', 'diff');
      pre.innerHTML = PREVIEW.diff.split('\n').map(l => {
        const c = l.startsWith('+++') || l.startsWith('---') ? 'quiet'
          : l.startsWith('@@') ? 'hunk' : l.startsWith('+') ? 'add'
            : l.startsWith('-') ? 'del' : '';
        return `<span class="${c}">${esc(l)}</span>`;
      }).join('\n');
      return pre;
    })()));
  }

  const removal = PROB.some(p => p.level === 'warn' && p.where === 'markers');
  let ack = null;
  if (removal) {
    const w = h('div', 'banner acc');
    w.innerHTML = '<b>this removes a marker position.</b> Bad data may move a '
      + 'marker; it may never delete one. Tick only if that is what you mean.';
    const cb = h('input'); cb.type = 'checkbox'; cb.id = 'e-ack';
    const lab = h('label');
    lab.appendChild(cb);
    lab.appendChild(document.createTextNode(' I mean to remove it'));
    w.appendChild(lab);
    body.appendChild(w);
    ack = cb;
  }

  const bar = h('div', 'chips');
  const commit = h('button', 'act primary', 'write it');
  commit.disabled = errs.length > 0;
  commit.onclick = async () => {
    if (BUSY) return;
    const reason = document.getElementById('e-reason').value.trim();
    if (!reason) { document.getElementById('e-reason').focus(); return; }
    BUSY = true; commit.disabled = true;
    /* The commit rebuilds server-side, which takes a few seconds. Saying so
       matters: a button that sits there looking broken is how somebody
       double-clicks and then wonders which write won. */
    commit.textContent = 'writing and rebuilding…';
    const r = await fetch('/api/commit', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        qid: Q.qid, record: M.serialise(), basis: basis.value,
        reason, author: who.value,
        ack_marker_removal: ack ? ack.checked : false,
      }),
    }).then(x => x.json());
    BUSY = false;
    if (r.refused || r.error) {
      const b = h('div', 'banner acc');
      b.textContent = r.refused || r.error;
      body.insertBefore(b, body.firstChild);
      commit.disabled = false; commit.textContent = 'write it';
      return;
    }
    window.QG_AFTER_COMMIT(r.entry, r.build);
  };
  bar.appendChild(commit);
  body.appendChild(bar);

  box.appendChild(body);
  wrap.appendChild(box);
  document.body.appendChild(wrap);
}

function labelled(text, node) {
  const d = h('div');
  d.appendChild(h('label', 'lbl', text));
  d.appendChild(node);
  return d;
}

window.QG_QUEST = QUEST;
})();
