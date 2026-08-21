/* Pickers. Nobody types a resource id, and nobody invents an entity name.
 *
 * Two different kinds of field, because there are two different kinds of truth
 * behind them:
 *
 *   items / key items / zones   are in the game's own res/ tables. A name
 *                               either resolves or it does not, so the picker
 *                               is a SEARCH over what exists and picking is
 *                               the only sane way to fill the field.
 *
 *   NPCs / objects / monsters   are in no res table at all. The picker offers
 *                               what THIS quest's own cached wiki page links,
 *                               which is 98% of NPC targets -- but it is a
 *                               SUGGESTION, never a gate. Free text is always
 *                               allowed, because the names that miss are real:
 *                               `abandoned mineshaft`, `acid-eaten door`,
 *                               `altar of rancor`. A field that refused them
 *                               would make it impossible to add the missing
 *                               target a correction exists to add.
 *
 * Measured: NPC targets are linked on their own page 2820/2890 = 98%. OBJECT
 * targets 225/867 = 26%, with 500 linked nowhere at all. So "not found" is a
 * red flag for an NPC and completely normal for an object, and the two must
 * not be shown the same way.
 */
'use strict';

(function () {

const PK = {};

function el(tag, cls, txt) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (txt !== undefined) e.textContent = txt;
  return e;
}

function closePop() {
  const p = document.querySelector('.pop');
  if (p) p.remove();
  document.removeEventListener('mousedown', PK._away, true);
  document.removeEventListener('keydown', PK._esc, true);
}
PK.close = closePop;

function openPop(anchor, build) {
  closePop();
  const pop = el('div', 'pop');
  document.body.appendChild(pop);
  build(pop);
  const r = anchor.getBoundingClientRect();
  pop.style.left = Math.min(r.left, window.innerWidth - pop.offsetWidth - 12) + 'px';
  const below = r.bottom + 6;
  pop.style.top = (below + pop.offsetHeight > window.innerHeight - 8
    ? Math.max(8, r.top - pop.offsetHeight - 6) : below) + window.scrollY + 'px';
  pop.style.left = parseFloat(pop.style.left) + window.scrollX + 'px';
  PK._away = e => { if (!pop.contains(e.target)) closePop(); };
  PK._esc = e => { if (e.key === 'Escape') { e.stopPropagation(); closePop(); } };
  setTimeout(() => {
    document.addEventListener('mousedown', PK._away, true);
    document.addEventListener('keydown', PK._esc, true);
  }, 0);
  const f = pop.querySelector('input, select');
  if (f) f.focus();
  return pop;
}
PK.open = openPop;

/* ------------------------------------------------- one-of-a-fixed-set ---- */
PK.choice = function (anchor, title, options, current, onPick) {
  openPop(anchor, pop => {
    pop.appendChild(el('div', 'hd', title));
    const box = el('div', 'opts');
    options.forEach(o => {
      const v = typeof o === 'string' ? o : o.value;
      const label = typeof o === 'string' ? o : o.label;
      const d = el('div', 'opt' + (v === current ? ' on' : ''));
      d.appendChild(el('span', null, label));
      if (typeof o === 'object' && o.hint) d.appendChild(el('span', 't', o.hint));
      d.onclick = () => { closePop(); onPick(v); };
      box.appendChild(d);
    });
    pop.appendChild(box);
  });
};

/* --------------------------------------------------- free text + suggest -- */
function debounce(fn, ms) {
  let t = null;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
}

/* Entity field: NPC / object / monster name.
 * `ctx` = {pageId, targetType, demote:[], allowTypes:bool} */
PK.entity = function (anchor, title, current, ctx, onPick) {
  openPop(anchor, pop => {
    pop.appendChild(el('div', 'hd', title));
    const input = el('input');
    input.type = 'text';
    input.value = current || '';
    input.placeholder = 'type a name, or pick one linked on this page';
    pop.appendChild(input);

    let typeSel = null;
    if (ctx.allowTypes) {
      const row = el('div', 'row');
      const seg = el('div', 'seg');
      ['npc', 'object', 'zone', 'none'].forEach(t => {
        const b = el('button', ctx.targetType === t ? 'on' : '', t);
        b.onclick = () => {
          ctx.targetType = t;
          [...seg.children].forEach(c => c.classList.toggle('on', c.textContent === t));
          if (t === 'none' || t === 'zone') { closePop(); onPick(t, null); }
        };
        seg.appendChild(b);
      });
      row.appendChild(seg);
      pop.appendChild(row);
      typeSel = seg;
    }

    const opts = el('div', 'opts');
    pop.appendChild(opts);
    const note = el('div', 'warn');
    pop.appendChild(note);

    const commit = name => { closePop(); onPick(ctx.targetType, name || null); };

    const render = rows => {
      opts.innerHTML = '';
      rows.forEach(r => {
        const d = el('div', 'opt tier-' + r.tier);
        d.appendChild(el('span', null, r.name));
        d.appendChild(el('span', 't',
          r.tier === 'page' ? 'on this page' : 'bg-wiki'));
        d.onclick = () => commit(r.name);
        opts.appendChild(d);
      });
      if (!rows.length) {
        const d = el('div', 'opt');
        d.appendChild(el('span', 'quiet', 'nothing linked matches'));
        opts.appendChild(d);
      }
    };

    const search = debounce(async () => {
      const q = input.value.trim();
      const u = `/api/entities?page_id=${ctx.pageId || 0}&q=${encodeURIComponent(q)}`
        + `&type=${ctx.targetType || 'npc'}`
        + (ctx.demote || []).map(d => `&demote=${encodeURIComponent(d)}`).join('');
      render(await (await fetch(u)).json());
      if (q) {
        const t = await (await fetch(
          `/api/entity_tier?page_id=${ctx.pageId || 0}&name=${encodeURIComponent(q)}`
          + `&type=${ctx.targetType || 'npc'}`)).json();
        /* A signal, never a gate -- and deliberately silent for the case where
           absence means nothing. 58% of objects are linked nowhere. */
        note.textContent = t.tier === 'unknown' && ctx.targetType !== 'object'
          ? '⚠ ' + t.why : '';
      } else note.textContent = '';
    }, 130);

    input.oninput = search;
    input.onkeydown = e => {
      if (e.key === 'Enter') { e.preventDefault(); commit(input.value.trim()); }
    };
    search();
  });
};

/* Resource field: item | ki | zone. Always a real id behind it. */
PK.resource = function (anchor, kind, current, onPick, opts) {
  opts = opts || {};
  openPop(anchor, pop => {
    pop.appendChild(el('div', 'hd',
      kind === 'ki' ? 'key item' : kind));
    const input = el('input');
    input.type = 'text';
    input.value = current && current.name || '';
    input.placeholder = 'search ' + (kind === 'ki' ? 'key items' : kind + 's');
    pop.appendChild(input);

    let count = null;
    if (opts.count) {
      const row = el('div', 'row');
      row.appendChild(el('span', 'hd', 'count'));
      count = el('input');
      count.type = 'number'; count.min = '1'; count.style.width = '80px';
      count.value = (current && current.count) || 1;
      row.appendChild(count);
      pop.appendChild(row);
    }

    let kindSel = kind;
    if (opts.kinds) {
      const row = el('div', 'row');
      const seg = el('div', 'seg');
      [['item', 'item'], ['ki', 'key item']].forEach(([v, l]) => {
        const b = el('button', kindSel === v ? 'on' : '', l);
        b.onclick = () => {
          kindSel = v;
          [...seg.children].forEach((c, i) => c.classList.toggle('on', i === (v === 'item' ? 0 : 1)));
          search();
        };
        seg.appendChild(b);
      });
      row.appendChild(seg);
      pop.appendChild(row);
    }

    const list = el('div', 'opts');
    pop.appendChild(list);
    const warn = el('div', 'warn');
    pop.appendChild(warn);

    const search = debounce(async () => {
      const q = input.value.trim();
      if (!q) { list.innerHTML = ''; warn.textContent = ''; return; }
      const rows = await (await fetch(
        `/api/pick?kind=${kindSel}&q=${encodeURIComponent(q)}`)).json();
      list.innerHTML = '';
      rows.forEach(r => {
        const d = el('div', 'opt');
        d.appendChild(el('span', null, r.name));
        if (r.or_group) {
          d.appendChild(el('span', 't', r.ids.length + ' ids, any will do'));
        } else if (r.ambiguous) {
          d.appendChild(el('span', 't', r.ids.length + ' share this name'));
        }
        d.onclick = () => {
          closePop();
          onPick({ kind: kindSel, name: r.name,
                   count: count ? Math.max(1, Number(count.value) || 1) : 1 });
        };
        d.onmouseenter = () => {
          /* The difference between the two duplicate cases, stated where the
             user is about to make the mistake. `differs` is empty when the ids
             are indistinguishable in res -- one key item per unit carried,
             which validate.py already spreads into an OR-list. It is non-empty
             when they are genuinely different things sharing a name, and then
             the resolver picks one over an unordered pairs() and the winner is
             not stable between runs. */
          if (r.ambiguous) {
            const k = Object.keys(r.differs)[0];
            warn.textContent = `⚠ ${r.ids.length} different items are called `
              + `"${r.name}", separated by ${k} ${r.differs[k].join(' / ')}. `
              + `The resolver picks one arbitrarily -- pin it in `
              + `tools/pipeline/resolve_overrides.json.`;
          } else if (r.or_group) {
            warn.textContent = `${r.ids.length} ids share this name and are `
              + `indistinguishable: one per unit carried. Holding any satisfies it.`;
          } else warn.textContent = '';
        };
        list.appendChild(d);
      });
      if (!rows.length) {
        warn.textContent = '✖ nothing in res/ matches -- an unresolvable '
          + 'name costs this step its requirement silently.';
      }
    }, 130);

    input.oninput = search;
    input.onkeydown = e => { if (e.key === 'Enter') e.preventDefault(); };
    if (input.value) search();
  });
};

/* Monster: a name plus a role, and the role decides the glyph in game. */
PK.mob = function (anchor, current, ctx, onPick, onDelete) {
  openPop(anchor, pop => {
    pop.appendChild(el('div', 'hd', 'monster'));
    const input = el('input');
    input.type = 'text';
    input.value = (current && current.name) || '';
    input.placeholder = 'monster name';
    pop.appendChild(input);

    let role = (current && current.role) || 'kill';
    const row = el('div', 'row');
    const seg = el('div', 'seg');
    [['kill', 'defeat'], ['drop', 'drops from'], ['spawn', 'spawns']]
      .forEach(([v, l]) => {
        const b = el('button', role === v ? 'on' : '', l);
        b.onclick = () => {
          role = v;
          [...seg.children].forEach(c => c.classList.remove('on'));
          b.classList.add('on');
        };
        seg.appendChild(b);
      });
    row.appendChild(seg);
    const cnt = el('input');
    cnt.type = 'number'; cnt.min = '1'; cnt.placeholder = 'n';
    cnt.style.width = '64px';
    cnt.value = (current && current.count) || '';
    row.appendChild(cnt);
    pop.appendChild(row);

    const list = el('div', 'opts');
    pop.appendChild(list);

    const search = debounce(async () => {
      const q = input.value.trim();
      const rows = await (await fetch(
        `/api/entities?page_id=${ctx.pageId || 0}&q=${encodeURIComponent(q)}&type=npc`)).json();
      list.innerHTML = '';
      rows.slice(0, 12).forEach(r => {
        const d = el('div', 'opt tier-' + r.tier);
        d.appendChild(el('span', null, r.name));
        d.appendChild(el('span', 't', r.tier === 'page' ? 'on this page' : 'bg-wiki'));
        d.onclick = () => { input.value = r.name; };
        list.appendChild(d);
      });
    }, 130);
    input.oninput = search;
    search();

    const bar = el('div', 'row');
    const ok = el('button', 'act primary', current ? 'save' : 'add');
    ok.onclick = () => {
      const name = input.value.trim();
      if (!name) return;
      closePop();
      onPick(name, role, cnt.value ? Number(cnt.value) : null);
    };
    bar.appendChild(ok);
    if (onDelete) {
      const rm = el('button', 'act', 'remove');
      rm.onclick = () => { closePop(); onDelete(); };
      bar.appendChild(rm);
    }
    pop.appendChild(bar);
  });
};

/* Free text with no vocabulary behind it: grid refs, notes, group names. */
PK.text = function (anchor, title, current, onPick, hint) {
  openPop(anchor, pop => {
    pop.appendChild(el('div', 'hd', title));
    const input = el('input');
    input.type = 'text';
    input.value = current || '';
    if (hint) input.placeholder = hint;
    pop.appendChild(input);
    input.onkeydown = e => {
      if (e.key === 'Enter') { closePop(); onPick(input.value.trim() || null); }
    };
    const bar = el('div', 'row');
    const ok = el('button', 'act primary', 'set');
    ok.onclick = () => { closePop(); onPick(input.value.trim() || null); };
    bar.appendChild(ok);
    const clear = el('button', 'act', 'clear');
    clear.onclick = () => { closePop(); onPick(null); };
    bar.appendChild(clear);
    pop.appendChild(bar);
  });
};

window.QG_PICK = PK;
})();
