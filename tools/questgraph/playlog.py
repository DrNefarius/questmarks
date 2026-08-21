"""Turn what the game said back into a quest you can open.

The human does not find the problem in this tool. They find it in play, from a
marker that makes no sense, and the shortest path from "this marker is wrong"
to "fixed" is to arrive here with the quest already open.

Two inputs, both real:

  * a `//qm why` block pasted straight out of the chat log;
  * `addons/questmarks/questmarks.log`, which every command also writes to. It
    appends across sessions and is stamped with the addon version at each boot,
    so one file spans several builds. A block has to be attributed to the build
    that produced it or its numbers mean nothing.

Parsing only. Build-time only.
"""

import io
import os
import re

from corpus import ADDON

LOG = os.path.join(ADDON, "questmarks.log")

#[[ `cmd_why` in questmarks.lua: line('[%s/%s #%d] %s', cat, area, id, name).
#   This is the one line in the whole output that identifies an entry exactly,
#   and it appears in //qm why, //qm diag and //qm npcs alike. ]]
RE_ENTRY = re.compile(r"\[(\w+)/(\w+)\s*#(-?\d+)\]\s*(.*?)\s*$")

#[[ The boot stamp, in BOTH shapes, and the older one is not hypothetical.
#
#   The boot block at the foot of questmarks.lua prints
#       v%s loaded %s entries over %d NPCs (%s step ladders) at %.2f ...
#   but every boot line in the questmarks.log on disk today reads
#       loaded 1504 entries over 1946 NPCs at 2.00 marker height.
#   The older shape carries no version and no ladder count. The stamp was
#   added after that log's last entry, and the log appends forever rather
#   than rotating.
#
#   So the one file this tool exists to read is mostly in the old format, and
#   a parser that only accepted the new one would be correct and useless. A
#   block with version=None is reported as predating the stamp, which is
#   exactly the distinction the stamp was added to make. ]]
RE_BOOT = re.compile(
    r"(?:v(?P<version>[\d.]+)\s+)?loaded\s+(?P<entries>\d+)\s+entries"
    r"(?:\s+over\s+(?P<npcs>\d+)\s+NPCs)?"
    r"(?:\s*\((?P<ladders>\d+)\s+step ladders\))?"
    r"\s+at\s+[\d.]+\s+marker height")

RE_TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\|\s?(.*)$")

RE_LADDER = re.compile(r"^\s*([>\s])([*\s])\s+(\d+)\s+(\w+)\s*(.*?)\s*$")
RE_STEPHDR = re.compile(r"^\s*ladder:\s*step\s+(\d+)\s+of\s+(\d+)\s*\(([^)]*)\)")
RE_STATE = re.compile(r"^\s*state:\s*(\S+)\s+marker:\s*(.*?)\s*$")
RE_REASON = re.compile(r"^\s*([+x?])\s+(.*?)\s*$")
RE_HEADER = re.compile(r"^(.*?)\s+--\s+(\d+)\s+indexed entr(?:y|ies)\s*$")


def strip_ts(line):
    m = RE_TS.match(line)
    return (m.group(1), m.group(2)) if m else (None, line)


def parse(text):
    """-> {boots: [...], blocks: [...], entries: [...]}

    A `block` is one entry's worth of //qm why output: its identity, its state,
    its reasons and its ladder. `entries` is the flat, deduplicated list of
    every entry id the text mentions, in first-seen order. That list is what
    the editor turns into links.
    """
    boots = []
    blocks = []
    order = []
    seen = set()
    cur = None
    npc = None

    for raw in text.splitlines():
        ts, line = strip_ts(raw)

        mb = RE_BOOT.search(line)
        if mb:
            b = mb.groupdict()
            b["at"] = ts
            b["stamped"] = b["version"] is not None
            boots.append(b)
            continue

        mh = RE_HEADER.match(line)
        if mh:
            npc = mh.group(1).strip()
            continue

        me = RE_ENTRY.search(line)
        if me:
            cat, area, qid_num, name = me.groups()
            qid = "%s/%s/%s" % (cat, area, qid_num)
            cur = {"qid": qid, "cat": cat, "area": area, "id": int(qid_num),
                   "name": name, "npc": npc, "at": ts,
                   "state": None, "marker": None, "hidden": None,
                   "reasons": [], "ladder": [], "step": None}
            blocks.append(cur)
            if qid not in seen:
                seen.add(qid)
                order.append(qid)
            continue

        if cur is None:
            continue

        ms = RE_STATE.match(line)
        if ms:
            cur["state"], cur["marker"] = ms.group(1), ms.group(2)
            continue
        if line.strip().startswith("- hidden:"):
            cur["hidden"] = line.split("hidden:", 1)[1].strip()
            continue
        mstep = RE_STEPHDR.match(line)
        if mstep:
            cur["step"] = {"idx": int(mstep.group(1)),
                           "n": int(mstep.group(2)),
                           "source": mstep.group(3)}
            continue
        ml = RE_LADDER.match(line)
        if ml and cur["step"] is not None:
            cur["ladder"].append({
                "current": ml.group(1) == ">",
                "marker": ml.group(2) == "*",
                "n": int(ml.group(3)),
                "kind": ml.group(4),
                "rest": ml.group(5),
            })
            continue
        mr = RE_REASON.match(line)
        if mr:
            mark = mr.group(1)
            cur["reasons"].append({
                "ok": True if mark == "+" else (False if mark == "x" else None),
                "text": mr.group(2)})

    return {"boots": boots, "blocks": blocks, "entries": order}


def read_log(path=LOG, tail_bytes=400000):
    """The tail of questmarks.log. It only ever grows, and the interesting
    part is always the end. 67 KB today, but it spans every session."""
    if not os.path.exists(path):
        return None
    size = os.path.getsize(path)
    with io.open(path, encoding="utf-8", errors="replace") as f:
        if size > tail_bytes:
            f.seek(size - tail_bytes)
            f.readline()               # discard the partial line
        return f.read()


def summarise(parsed, corpus):
    """Join what the game said to what the editor holds.

    The useful column is the one that says whether a mentioned entry even HAS
    an authored record. 1115 index rows sit over 1003 authored ones, so a
    marker can be wrong about a quest whose reasoning does not exist here at
    all, and that is a different problem with a different fix.
    """
    out = []
    for qid in parsed["entries"]:
        blocks = [b for b in parsed["blocks"] if b["qid"] == qid]
        last = blocks[-1]
        out.append({
            "qid": qid,
            "name": last["name"],
            "npc": last["npc"],
            "at": last["at"],
            "state": last["state"],
            "marker": last["marker"],
            "step": last["step"],
            "mentions": len(blocks),
            "authored": qid in corpus.by_qid,
            "indexed": qid in corpus.index_by_qid,
            "title": ((corpus.by_qid.get(qid) or {}).get("source") or {})
                     .get("wiki_title"),
        })
    return out
