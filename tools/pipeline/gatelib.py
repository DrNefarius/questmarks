"""Shared baseline handling for the authored-data gates.

A gate that fails on 228 pre-existing problems is a gate nobody can turn on.
A gate that is only advisory is one nobody reads. The way out is a BASELINE:
record what is wrong today, fail on anything NEW, and keep the known set
printed so it cannot quietly become permanent.

The baseline is a plain sorted text file, one problem per line, so a diff of it
is readable in review and shrinking it is an obvious, satisfying change. It is
NOT a suppression list: every entry stays in the output under its own heading,
with a count, every run.

Rebuild it deliberately with --write-baseline. Never automatically: a gate that
re-baselines itself when it fails is a gate that always passes.

Build-time only.
"""

import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(HERE, "..", ".."))


#[[ The four arguments every gate takes, in one place.
#
#   emit_lua.py's run_gates shells out to all three by bare filename and reads
#   only the exit code, so it cannot pass anything and cannot see a
#   disagreement. Three copies of the same block is how one of them quietly
#   grows a different --in default and starts checking a different corpus than
#   the build thinks it did. Per-gate arguments (--quiet, --show) stay on the
#   gate that owns them. ]]
def add_args(ap, baseline_name):
    ap.add_argument("--in", dest="indir",
                    default=os.path.join(ADDON, "build", "authored"))
    ap.add_argument("pattern", nargs="?", default="*.json")
    ap.add_argument("--baseline", default=os.path.join(HERE, baseline_name))
    ap.add_argument("--write-baseline", action="store_true")


def load_baseline(path):
    if not path or not os.path.isfile(path):
        return set()
    out = set()
    with io.open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                out.add(line)
    return out


def write_baseline(path, problems, title):
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("# %s\n" % title)
        f.write("# %d known problem(s), recorded so the gate can fail on NEW ones.\n"
                % len(problems))
        f.write("# Shrinking this file is the point. Regenerate deliberately with\n"
                "# --write-baseline; nothing rewrites it on failure.\n")
        for p in sorted(problems):
            f.write(p + "\n")


def apply(problems, baseline_path, write, title, label):
    """-> (new_problems, known_count). Prints the split; caller decides exit."""
    problems = sorted(set(problems))
    if write:
        write_baseline(baseline_path, problems, title)
        print("wrote baseline %s (%d entry/entries)"
              % (os.path.basename(baseline_path), len(problems)))
        return [], len(problems)

    known = load_baseline(baseline_path)
    new = [p for p in problems if p not in known]
    fixed = [p for p in known if p not in set(problems)]

    if known:
        still = len(problems) - len(new)
        print("%d known %s from the baseline (%s)"
              % (still, label, os.path.basename(baseline_path)))
    if fixed:
        #[[ Reported loudly and treated as a reason to rebaseline, not as a
        #   failure. A shrinking baseline is the desired direction and the tool
        #   should say so; leaving stale entries in means the next real
        #   regression hides behind a line that no longer applies. ]]
        print("%d baseline entry/entries no longer occur -- rerun with "
              "--write-baseline to shrink it:" % len(fixed))
        for p in fixed[:10]:
            print("    " + p)
        if len(fixed) > 10:
            print("    ... and %d more" % (len(fixed) - 10))
    return new, len(problems) - len(new)
