/* The typed record model.
 *
 * THE POINT OF THIS FILE: the UI never edits text. It mutates a typed object
 * through named operations and serialises it at the end, so a JSON syntax
 * error cannot be authored -- not "is caught", cannot be authored. That is the
 * real answer to "we don't save invalid jsons"; a parse check after the fact
 * only tells you afterwards that you wasted your time.
 *
 * Every mutation goes through here, and every mutation keeps the record
 * SCHEMA-SHAPED: `n` stays dense, lists stay lists, and a key is never dropped
 * (AUTHORING.md: explicit null is a positive assertion, an omitted key is
 * indistinguishable from a truncated response).
 *
 * Schema-valid is not the same as correct. That is what gates.py is for, and
 * nothing here duplicates it.
 */
'use strict';

(function () {

const KINDS = ['talk', 'trade', 'turnin', 'examine', 'fight', 'travel',
  'obtain', 'wait', 'cutscene', 'other'];
const TARGET_TYPES = ['npc', 'object', 'zone', 'none'];
const CONFIDENCE = ['high', 'medium', 'low'];
const ROLES = ['kill', 'drop', 'spawn'];

const clone = o => JSON.parse(JSON.stringify(o));

function blankStep(n) {
  /* Every key present, explicitly. A step built by omission would fail
     schema_check on keys the user never saw and cannot be asked about. */
  return {
    n, kind: 'talk',
    target: { type: 'none', name: null },
    zone: null, grid: null,
    items: [], items_alt: [], items_partial: false,
    evidence: null, mobs: [], group: null, optional: false,
    confidence: 'medium', note: null, source_bullets: []
  };
}

class Model {
  constructor(record) {
    this.base = clone(record);
    this.rec = clone(record);
  }

  get steps() { return this.rec.steps; }
  step(n) { return this.rec.steps.find(s => s.n === n); }

  /* ---- serialisation: the ONLY way a record leaves this file ---------- */
  serialise() {
    const r = clone(this.rec);
    this.renumber(r);
    return r;
  }

  /* `n` is dense 1..N in array order -- a hard gate in validate.py. Done
     automatically on every read, so it can never be got wrong by hand, and
     `renumbered()` reports what moved so the UI can show it. */
  renumber(r) {
    (r || this.rec).steps.forEach((s, i) => { s.n = i + 1; });
    return r || this.rec;
  }

  renumbered() {
    const out = [];
    this.rec.steps.forEach((s, i) => {
      if (s.n !== i + 1) out.push({ from: s.n, to: i + 1 });
    });
    return out;
  }

  dirty() { return JSON.stringify(this.serialise()) !== JSON.stringify(this.base); }

  /* A path-keyed summary of what changed, so the UI can mark the exact lines
     rather than saying "something changed". */
  changed() {
    const out = new Set();
    const walk = (a, b, p) => {
      if (a === b) return;
      const ta = Object.prototype.toString.call(a);
      const tb = Object.prototype.toString.call(b);
      if (ta === '[object Object]' && tb === '[object Object]') {
        new Set([...Object.keys(a), ...Object.keys(b)])
          .forEach(k => walk(a[k], b[k], p ? p + '.' + k : k));
      } else if (ta === '[object Array]' && tb === '[object Array]') {
        const n = Math.max(a.length, b.length);
        for (let i = 0; i < n; i++) walk(a[i], b[i], `${p}[${i + 1}]`);
      } else if (JSON.stringify(a) !== JSON.stringify(b)) {
        out.add(p);
      }
    };
    walk(this.base, this.serialise(), '');
    return out;
  }

  stepChanged(n) {
    const pre = `steps[${n}]`;
    return [...this.changed()].some(p => p === pre || p.startsWith(pre + '.'));
  }

  /* ---- quest-level ---------------------------------------------------- */
  setConfidence(v) { if (CONFIDENCE.includes(v)) this.rec.confidence = v; }
  setNotes(v) { this.rec.notes = v || null; }

  setGate(key, value) {
    const g = this.rec.gates;
    if (key === 'level') g.level = value === null || value === '' ? null : Number(value);
    else if (key === 'repeatable') g.repeatable = !!value;
    else if (key === 'expansion') g.expansion = value || null;
    else if (key === 'jobs') g.jobs = Array.isArray(value) ? value : [];
    else if (key === 'fame') g.fame = value;      // {region, level, raw} or null
    /* A LIST, and an AND-list -- unlike `jobs`, which is an OR. Absent rather
       than empty when there is none, so a quest that never had a craft gate
       does not grow an empty key it cannot have meant. */
    else if (key === 'craft') {
      if (Array.isArray(value) && value.length) g.craft = value;
      else delete g.craft;
    }
  }
  addPrev(title) {
    if (!title) return;
    this.rec.gates.prev.push({ title, cat: null, area: null, id: null });
  }
  removePrev(i) { this.rec.gates.prev.splice(i, 1); }

  setStart(field, v) { this.rec.start[field] = v === '' ? null : v; }

  /* ---- steps ---------------------------------------------------------- */
  setStepField(n, field, v) {
    const s = this.step(n); if (!s) return;
    if (field === 'kind') { if (KINDS.includes(v)) s.kind = v; }
    else if (field === 'zone') s.zone = v || null;
    else if (field === 'grid') s.grid = v || null;
    else if (field === 'note') s.note = v || null;
    else if (field === 'group') s.group = v || null;
    else if (field === 'optional') s.optional = !!v;
    else if (field === 'items_partial') s.items_partial = !!v;
    else if (field === 'confidence') { if (CONFIDENCE.includes(v)) s.confidence = v; }
  }

  setTarget(n, type, name) {
    const s = this.step(n); if (!s) return;
    if (!TARGET_TYPES.includes(type)) return;
    /* type and name move together: a typed target with no name and an
       untyped target with a name are both schema errors, and letting the UI
       produce either would mean the user meets a refusal for a state the UI
       put them in. */
    s.target = { type, name: (type === 'none' || type === 'zone') ? null : (name || null) };
    if (type === 'none') s.target.name = null;
  }

  insertStep(afterN) {
    const i = afterN === 0 ? 0 : this.rec.steps.findIndex(s => s.n === afterN) + 1;
    const s = blankStep(0);
    this.rec.steps.splice(i, 0, s);
    this.renumber();
    return s.n;
  }

  deleteStep(n) {
    const i = this.rec.steps.findIndex(s => s.n === n);
    if (i < 0) return;
    this.rec.steps.splice(i, 1);
    this.renumber();
  }

  moveStep(n, delta) {
    const i = this.rec.steps.findIndex(s => s.n === n);
    const j = i + delta;
    if (i < 0 || j < 0 || j >= this.rec.steps.length) return n;
    const [s] = this.rec.steps.splice(i, 1);
    this.rec.steps.splice(j, 0, s);
    this.renumber();
    return s.n;
  }

  /* ---- attachments ---------------------------------------------------- */
  /* `list` is one of items | items_alt | evidence.all | evidence.alt */
  _list(n, list, make) {
    const s = this.step(n); if (!s) return null;
    if (list.startsWith('evidence')) {
      if (!s.evidence) {
        if (!make) return null;
        s.evidence = { all: [], alt: [] };
      }
      const k = list.split('.')[1];
      if (!Array.isArray(s.evidence[k])) s.evidence[k] = [];
      return s.evidence[k];
    }
    if (!Array.isArray(s[list])) s[list] = [];
    return s[list];
  }

  addEntry(n, list, entry) {
    const l = this._list(n, list, true); if (!l) return;
    l.push({ kind: entry.kind, name: entry.name, count: entry.count || 1 });
  }
  editEntry(n, list, i, entry) {
    const l = this._list(n, list); if (!l || !l[i]) return;
    l[i] = { kind: entry.kind, name: entry.name, count: entry.count || 1 };
  }
  removeEntry(n, list, i) {
    const l = this._list(n, list); if (!l) return;
    l.splice(i, 1);
    /* An empty AND-list with no alt is illegal -- vacuously true, it would
       advance the mark on nothing. Emptying evidence therefore nulls it,
       which is the correct positive assertion "nothing observable here". */
    const s = this.step(n);
    if (s.evidence && !(s.evidence.all || []).length && !(s.evidence.alt || []).length) {
      s.evidence = null;
    }
  }

  addMob(n, name, role, count) {
    const s = this.step(n); if (!s) return;
    if (!ROLES.includes(role)) role = 'kill';
    s.mobs.push({ name, count: count || null, role });
  }
  editMob(n, i, name, role, count) {
    const s = this.step(n); if (!s || !s.mobs[i]) return;
    s.mobs[i] = { name, count: count || null, role: ROLES.includes(role) ? role : 'kill' };
  }
  removeMob(n, i) { const s = this.step(n); if (s) s.mobs.splice(i, 1); }

  /* ---- flags ---------------------------------------------------------- */
  addFlag(f) {
    f = (f || '').trim().toLowerCase().replace(/\s+/g, '_');
    if (f && !this.rec.review_flags.includes(f)) this.rec.review_flags.push(f);
  }
  removeFlag(f) {
    this.rec.review_flags = this.rec.review_flags.filter(x => x !== f);
  }
}

window.QG_MODEL = { Model, KINDS, TARGET_TYPES, CONFIDENCE, ROLES, blankStep, clone };
})();
