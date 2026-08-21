"""The only write path in this tool.

This edits 179 source files that cost a reading pass each, so every rule here
is about catching a wrong write before it lands rather than after:

    a diff shown before the write          (review)
    a local copy of what was replaced      (immediate undo, uncommitted)
    an append-only ledger after the write  (what changed, and why)
    a refusal to write to any file that something else regenerates

The last one is the rule no source control supplies: a generated file will be
overwritten by the next build whatever its history says.

Two writers, no locking. Every commit re-checks the file's sha256 against the
bytes that were loaded and refuses if it moved. The pipeline's own agents edit
build/authored/ too, and a lost update between them and this tool is the one
failure nothing downstream can catch: both writes look well-formed, and only
the survivor is ever seen.

Build-time only.
"""

import datetime
import difflib
import errno
import hashlib
import io
import json
import os
import shutil

from corpus import ADDON, AuthoredFile, is_generated, qid_of, sha256_text
import gates

HERE = os.path.dirname(os.path.abspath(__file__))

#[[ Deliberately NOT under build/. Treating the whole of build/ as regenerable
#   output is true of rendered/, validated/ and reports/, and dangerously untrue
#   of build/authored/: 8.4 MB of reading that cannot be reproduced without
#   redoing it. Backups of a human correction do not belong inside a directory
#   the rest of which is disposable. ]]
BACKUPS = os.path.join(HERE, "backups")
LEDGER = os.path.join(HERE, "edits.jsonl")


class Refused(Exception):
    """A write that must not happen. The message is shown to the human."""


def _utc():
    return datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def _stamp():
    return datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")


def unified(before, after, name):
    return "".join(difflib.unified_diff(
        before.splitlines(True), after.splitlines(True),
        fromfile="a/" + name, tofile="b/" + name, n=3))


def changed_paths(old, new, prefix=""):
    """Every leaf path that differs, in the record's own vocabulary.

    Recorded on the human block so a future session can see WHAT was corrected
    without diffing anything. "steps[3].evidence" is the useful sentence, and
    it is not recoverable from a file-level diff once the file has moved on.
    """
    out = []
    if isinstance(old, dict) and isinstance(new, dict):
        for k in sorted(set(old) | set(new)):
            out += changed_paths(old.get(k), new.get(k),
                                 "%s.%s" % (prefix, k) if prefix else k)
    elif isinstance(old, list) and isinstance(new, list):
        for i in range(max(len(old), len(new))):
            o = old[i] if i < len(old) else None
            n = new[i] if i < len(new) else None
            out += changed_paths(o, n, "%s[%d]" % (prefix, i + 1))
    elif old != new:
        out.append(prefix or "(root)")
    return out


def human_block(old_record, basis, reason, author, fields):
    """The marker that says a person decided this.

    NOT the `extraction` block. That block records how the MACHINE read the
    page (reader, reader version, and the stage-D adversarial verifier's
    verdict), and it is still written by the pipeline. Overwriting
    `extraction.reader` with a person's name would destroy the only evidence
    that the verify pass ever ran on this quest, and would make "was this
    record verified?" and "did a human touch it?" the same question, which
    they are not.

    `basis` is the load-bearing field, and it is not decoration:

        reading   the page supports this; the machine read it wrong.
                  A later re-read against a CHANGED page may legitimately
                  supersede it.
        game      the page does NOT support this; play does. Ground truth.
                  Never superseded by a re-read, however good.
        resolver  the reading was right and the NAME did not resolve.
                  Recorded on a resolver pin, not here.

    `worklist.py` reads exactly that distinction to decide what it may
    schedule for re-reading.
    """
    prior = (old_record or {}).get("human")
    history = list((prior or {}).get("history") or [])
    if prior:
        p = dict(prior)
        p.pop("history", None)
        history.append(p)
    src = (old_record or {}).get("source") or {}
    return {
        "edited_at": _utc(),
        "by": author or "unknown",
        "basis": basis,
        "reason": reason.strip(),
        "fields": fields,
        #[[ Which revision of the page the human was looking at. `source` is
        #   the revision the READING was done against and a re-scrape would
        #   move it, so without this pin a correction becomes unattributable
        #   the moment the cache is refreshed. Compare the two when re-reading
        #   a record that carries a correction. ]]
        "source_at_edit": {"revision_id": src.get("revision_id"),
                           "source_sha256": src.get("source_sha256")},
        "history": history,
    }


def apply_flags(record, basis):
    """Reuse the existing flag vocabulary rather than inventing a parallel one.

    `verified_in_game` is already part of the review-flag vocabulary, already on
    10 records, and already means "treat this as ground truth and leave it
    alone". A second flag meaning the same thing would split the one query that
    matters.
    """
    flags = list(record.get("review_flags") or [])
    if "human_corrected" not in flags:
        flags.append("human_corrected")
    if basis == "game" and "verified_in_game" not in flags:
        flags.append("verified_in_game")
    record["review_flags"] = flags
    return record


class Edit(object):
    def __init__(self, corpus, qid, new_record, basis, reason, author,
                 ack_marker_removal=False):
        self.corpus = corpus
        self.qid = qid
        self.basis = basis
        self.reason = reason or ""
        self.author = author or "unknown"
        self.ack = bool(ack_marker_removal)

        if qid not in corpus.by_qid:
            raise Refused("no authored record for %s" % qid)
        self.old = corpus.by_qid[qid]
        self.fname, self.idx = corpus.loc[qid]
        self.file = corpus.files[self.fname]
        if is_generated(self.file.path, corpus.root):
            raise Refused("%s is generated" % self.file.path)

        self.new = json.loads(json.dumps(new_record))     # detach
        #[[ apply_flags must run BEFORE changed_paths(). The flags this
        #   tool adds are writes like any other, so they have to be in place
        #   before the diff is taken or `human.fields` and the ledger will
        #   under-report what the edit actually did. ]]
        apply_flags(self.new, basis)
        self.new["human"] = human_block(
            self.old, basis, self.reason, self.author,
            changed_paths({k: v for k, v in self.old.items() if k != "human"},
                          {k: v for k, v in self.new.items() if k != "human"}))

    # ------------------------------------------------------------- preview

    def check(self):
        problems, row, quarantine = gates.check_edit(
            self.old, self.new, self.basis, self.reason)
        return problems, row, quarantine

    def diff(self):
        records = list(self.file.records)
        records[self.idx] = self.new
        after = self.file.render(records)
        return unified(self.file.raw, after, "build/authored/" + self.fname), after

    def preview(self):
        problems, row, quarantine = self.check()
        diff, _after = self.diff()
        return {
            "qid": self.qid,
            "file": "build/authored/" + self.fname,
            "problems": [p.as_dict() for p in problems],
            "blocking": [p.as_dict() for p in problems if p.level == "error"],
            "diff": diff,
            "fields": self.new["human"]["fields"],
            "validated": row,
            "quarantine": quarantine,
        }

    # -------------------------------------------------------------- commit

    def commit(self):
        problems, _row, _q = self.check()
        blocking = [p for p in problems if p.level == "error"]
        if blocking:
            raise Refused("refused: %s"
                          % "; ".join("%s -- %s" % (p.where, p.text)
                                      for p in blocking))
        removals = [p for p in problems
                    if p.level == "warn" and p.where == "markers"]
        if removals and not self.ack:
            raise Refused(
                "refused: this edit removes a marker position and that was not "
                "acknowledged. %s" % removals[0].text)

        #[[ Optimistic concurrency. The pipeline's own agents write to
        #   build/authored/ as well; without this a lost update between two
        #   writers is silent, and there is no VCS to recover it from. ]]
        with io.open(self.file.path, encoding="utf-8", newline="") as f:
            on_disk = f.read()
        if sha256_text(on_disk) != self.file.sha:
            raise Refused(
                "refused: %s changed on disk since it was loaded. Something "
                "else is writing to build/authored/. Reload and re-apply."
                % self.fname)

        _diff, after = self.diff()

        #[[ The backup directory is stamped AND content-addressed, and the
        #   content half is not decoration.
        #
        #   _stamp() has one-second resolution. On a stamp alone, two
        #   corrections to the same file inside one second share a directory
        #   and the second shutil.copy2 overwrites the first one's backup, so
        #   reverting the first edit restores the state after it. Silent data
        #   loss, in the one mechanism that exists here instead of version
        #   control.
        #
        #   Keying on the sha of the bytes being saved makes it impossible:
        #   different pre-edit content cannot collide, and identical pre-edit
        #   content does not need two copies. ]]
        bdir = os.path.join(BACKUPS, "%s-%s" % (_stamp(), self.file.sha[:12]))
        try:
            os.makedirs(bdir)
        except OSError as e:
            if e.errno != errno.EEXIST:
                raise
        backup = os.path.join(bdir, self.fname)
        shutil.copy2(self.file.path, backup)

        tmp = self.file.path + ".qgtmp"
        with io.open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(after)
        os.replace(tmp, self.file.path)                   # atomic on Windows

        entry = {
            "at": _utc(),
            "qid": self.qid,
            #[[ The corpus root is recorded, and `backup` is absolute, because
            #   BACKUPS lives beside this tool while the corpus root is a
            #   parameter. Derive either from a module constant and revert
            #   silently resolves against the wrong tree. The test that runs
            #   against a throwaway copy is what catches that, which is exactly
            #   why that test runs against a throwaway copy. ]]
            "root": self.corpus.root,
            "title": (self.old.get("source") or {}).get("wiki_title"),
            "file": "build/authored/" + self.fname,
            "backup": backup.replace("\\", "/"),
            "by": self.author,
            "basis": self.basis,
            "reason": self.reason.strip(),
            "fields": self.new["human"]["fields"],
            "sha_before": self.file.sha,
            "sha_after": sha256_text(after),
            "marker_removal_acknowledged": bool(removals),
        }
        with io.open(LEDGER, "a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

        # keep the in-memory corpus consistent with disk
        self.file.raw = after
        self.file.sha = entry["sha_after"]
        self.file.records[self.idx] = self.new
        self.corpus.by_qid[self.qid] = self.new
        for i, q in enumerate(self.corpus.quests):
            if qid_of(q.get("identity") or {}) == self.qid:
                self.corpus.quests[i] = self.new
                break
        return entry


def ledger(limit=200):
    if not os.path.exists(LEDGER):
        return []
    out = []
    with io.open(LEDGER, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out[-limit:][::-1]


def revert(entry, force=False):
    """Put a backup back. The only undo there is.

    A revert is a WHOLE-FILE copy and an authored file holds 2-10 quests
    (mean 7.7), so restoring quest A's backup also un-does anything written to
    quests B..H in the same file since. `commit()` re-checks the file's sha
    before writing; this has to as well, or the safest-looking button in the
    tool is the one that destroys work silently.
    """
    root = entry.get("root") or ADDON
    src = entry["backup"]
    if not os.path.isabs(src):                 # ledger rows written before
        src = os.path.join(root, src)          # `root` was recorded
    dst = os.path.join(root, entry["file"])
    if not os.path.exists(src):
        raise Refused("backup is gone: %s" % entry["backup"])
    if is_generated(dst, root):
        raise Refused("%s is generated" % dst)
    if os.path.exists(dst) and entry.get("sha_after") and not force:
        with io.open(dst, encoding="utf-8", newline="") as f:
            now = sha256_text(f.read())
        if now != entry["sha_after"]:
            raise Refused(
                "refused: %s has been written since this edit, so reverting "
                "would also un-do whatever came after it -- the file holds "
                "several quests. Check the other corrections to this file "
                "first, then revert with force if you still mean it."
                % os.path.basename(dst))
    shutil.copy2(src, dst)
    with io.open(LEDGER, "a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps({"at": _utc(), "reverted": entry["at"],
                            "qid": entry["qid"], "file": entry["file"],
                            "from_backup": entry["backup"]},
                           ensure_ascii=False) + "\n")
    return {"restored": entry["file"], "from": entry["backup"]}
