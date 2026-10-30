#!/usr/bin/env bash
#
# Phase 1 for issue #769: find which otg_* call in power_script.sql first
# produces a different result between runs.
#
# Generates an instrumented copy of power_script.sql with a probe after every
# top-level `SELECT otg_*();` call. Each probe records the row counts and a
# content hash of bus_data and branch_data into table otg_probe. Running the
# instrumented script several times and diffing the probe tables per step
# gives the first step at which two runs disagree.
#
# Usage:
#   ./AI/otg_bisect.sh [N]        # N trials, default 5
#
# Env: PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE OSMTGMOD_DIR
#
# The instrumented script is written to AI/results/otg/power_script.probed.sql
# and is never written back over the original.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIALS="${1:-5}"

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-59734}"
export PGUSER="${PGUSER:-egon}"
export PGPASSWORD="${PGPASSWORD:-data}"
export PGDATABASE="${PGDATABASE:-egon-data}"

# These scripts live inside the osmTGmod repository, two levels below
# its root, so the checkout under test defaults to that root. Point
# OSMTGMOD_DIR elsewhere to trial a different checkout.
OSMTGMOD_DIR="${OSMTGMOD_DIR:-$(cd "$HERE/../.." && pwd)}"
POWER_SCRIPT="$OSMTGMOD_DIR/sql-scripts/power_script.sql"
FUNCTIONS_SQL="$OSMTGMOD_DIR/sql-scripts/functions.sql"
OUT_DIR="$(cd "$HERE/.." && pwd)/results/otg"
PROBED="$OUT_DIR/power_script.probed.sql"

mkdir -p "$OUT_DIR"

# ------------------------------------------------------- build instrumentation
python3 - "$POWER_SCRIPT" "$PROBED" <<'PY'
import re, sys

src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().split("\n")

# A probe is only meaningful once bus_data exists, and it must not blow up
# before then, hence the to_regclass guard.
PROBE = """
DO $probe$
DECLARE
    v_step INT := {step};
BEGIN
    -- bus_data and branch_data are created near the top of
    -- power_script.sql, before the first otg_* call, so they can be
    -- referenced directly.
    INSERT INTO otg_probe (step, script_line, label,
                           bus_rows, branch_rows,
                           bus_noid, bus_full, branch_noid, bus_cols,
                           branch_full)
    SELECT v_step, {line}, {label},
           (SELECT count(*) FROM bus_data),
           (SELECT count(*) FROM branch_data),
           -- vertex multiset, ids ignored
           (SELECT md5(coalesce(string_agg(j, '|' ORDER BY j), ''))
              FROM (SELECT (to_jsonb(t) - 'id')::text AS j
                      FROM bus_data t) s),
           -- vertices including ids: separates a renumbering from a
           -- genuine content change
           (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, '|'
                                           ORDER BY t.id), ''))
              FROM bus_data t),
           (SELECT md5(coalesce(string_agg(j, '|' ORDER BY j), ''))
              FROM (SELECT (to_jsonb(t) - 'branch_id')::text AS j
                      FROM branch_data t) s),
           -- one hash per column of bus_data, so a divergence can be
           -- attributed to a specific column instead of the whole row
           (SELECT string_agg(k || ':' || left(h, 8), ' ' ORDER BY k)
              FROM (SELECT e.key AS k,
                           md5(string_agg(e.value::text, '|'
                                          ORDER BY e.value::text)) AS h
                      FROM bus_data t, jsonb_each(to_jsonb(t)) e
                     GROUP BY e.key) z),
           -- branch_data INCLUDING branch_id. branch_noid drops it, so a
           -- renumbering of branches was invisible to this probe while the
           -- plain-script harness (which hashes ids) could see it.
           (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, '|'
                                           ORDER BY t.branch_id), ''))
              FROM branch_data t);

    -- power_line_sep only exists from otg_seperate_voltage_levels
    -- onwards, so it must be reached through EXECUTE. A plain reference
    -- guarded by to_regclass in a CASE does NOT work: PostgreSQL parses
    -- the entire statement before running any of it, so the missing
    -- relation is a parse-time error and the guard never runs.
    IF to_regclass('power_line_sep') IS NOT NULL THEN
        EXECUTE format($q$
            UPDATE otg_probe SET
                linesep_rows = (SELECT count(*) FROM power_line_sep),
                -- edge topology, id-independent: each edge as its
                -- line_id plus the geometry of both endpoint buses
                topo_md5 = (SELECT md5(coalesce(string_agg(j, '|' ORDER BY j), ''))
                              FROM (SELECT l.line_id::text || ':' ||
                                           coalesce(bf.the_geom::text, '-') || ':' ||
                                           coalesce(bt.the_geom::text, '-') AS j
                                      FROM power_line_sep l
                                 LEFT JOIN bus_data bf ON bf.id = l.f_bus
                                 LEFT JOIN bus_data bt ON bt.id = l.t_bus) e)
            WHERE step = %s $q$, v_step);
    END IF;

    -- power_circ_members and power_line feed branch_data but were not
    -- covered, which is why a divergence in them only surfaced later, at
    -- the first probe after branch_data gets filled. Same EXECUTE
    -- deferral as above: they do not exist for the whole run.
    IF to_regclass('power_circ_members') IS NOT NULL THEN
        EXECUTE format($q$
            UPDATE otg_probe SET circ_md5 =
                (SELECT md5(coalesce(string_agg(j, '|' ORDER BY j), ''))
                   FROM (SELECT (to_jsonb(t) - 'id')::text AS j
                           FROM power_circ_members t) s)
            WHERE step = %s $q$, v_step);
    END IF;

    IF to_regclass('power_line') IS NOT NULL THEN
        EXECUTE format($q$
            UPDATE otg_probe SET line_md5 =
                (SELECT md5(coalesce(string_agg(j, '|' ORDER BY j), ''))
                   FROM (SELECT (to_jsonb(t) - 'id')::text AS j
                           FROM power_line t) s)
            WHERE step = %s $q$, v_step);
    END IF;
END
$probe$;
"""

HEADER = """
DROP TABLE IF EXISTS otg_probe;
CREATE TABLE otg_probe (
    step         INT,
    script_line  INT,
    label        TEXT,
    bus_rows     BIGINT,
    branch_rows  BIGINT,
    linesep_rows BIGINT,
    bus_noid     TEXT,
    bus_full     TEXT,
    branch_noid  TEXT,
    topo_md5     TEXT,
    circ_md5     TEXT,
    line_md5     TEXT,
    bus_cols     TEXT,
    branch_full  TEXT
);
"""

call = re.compile(r"^\s*SELECT\s+(otg_[a-z0-9_]+)\s*\(", re.IGNORECASE)
out, step = [HEADER], 0
for i, ln in enumerate(lines, 1):
    out.append(ln)
    m = call.match(ln)
    # only when the statement is complete on this line. Strip a trailing
    # `-- comment` first: two calls (otg_substract_cables_within_buffer_all
    # and otg_connect_substation_vertices) carry one, and were silently
    # skipped, which is why divergences inside them showed up as belonging
    # to the *next* probed step.
    stripped = re.sub(r"--.*$", "", ln).rstrip()
    if m and stripped.endswith(";"):
        step += 1
        label = f"{m.group(1)}"
        # keep the argument, it distinguishes the split_table_* calls
        arg = re.search(r"\(\s*'([^']*)'\s*\)", ln)
        if arg:
            label += f"({arg.group(1)})"
        out.append(PROBE.format(step=step, line=i,
                                label="'" + label.replace("'", "''") + "'"))

# The script does not end with an otg_* call: lines after the last one
# still DELETE from branch_data and UPDATE bus_data. Probe the final state
# too, otherwise the tail is invisible and the bisect disagrees with the
# plain harness for a purely uninteresting reason.
step += 1
out.append(PROBE.format(step=step, line=len(lines), label="'END-of-script'"))

open(dst, "w", encoding="utf-8").write("\n".join(out))
print(f"instrumented {step} otg_* calls -> {dst}")
PY

[[ -f "$PROBED" ]] || { echo "instrumentation failed" >&2; exit 1; }

echo "database: $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
echo -n "reloading functions.sql ... "
if psql -X -q -v ON_ERROR_STOP=1 -f "$FUNCTIONS_SQL" \
        > "$OUT_DIR/functions_reload.log" 2>&1; then
    echo ok
else
    echo FAILED; tail -n 15 "$OUT_DIR/functions_reload.log" | sed 's/^/  /'; exit 1
fi

# ------------------------------------------------------------------- the loop
for ((i = 1; i <= TRIALS; i++)); do
    printf "trial %d/%d ... " "$i" "$TRIALS"
    # A previous run that died partway can leave split_table_* and other
    # mid-script tables behind, making the next run fail on CREATE TABLE.
    # Clear them so every trial is independent.
    psql -X -q -f "$HERE/otg_cleanup.sql" >/dev/null 2>&1
    start=$SECONDS
    if ! psql -X -q -v ON_ERROR_STOP=1 -f "$PROBED" \
            > "$OUT_DIR/probe_trial_${i}.log" 2>&1; then
        echo "FAILED, see $OUT_DIR/probe_trial_${i}.log"
        tail -n 20 "$OUT_DIR/probe_trial_${i}.log" | sed 's/^/  /'
        exit 1
    fi
    psql -X -q -A -t -F $'\t' -v ON_ERROR_STOP=1 \
        -c "SELECT step, script_line, label, bus_rows, branch_rows,
                   coalesce(linesep_rows, -1), bus_noid, bus_full, branch_noid,
                   coalesce(topo_md5, '-'), coalesce(circ_md5, '-'),
                   coalesce(line_md5, '-'), coalesce(bus_cols, '-'),
                   coalesce(branch_full, '-')
            FROM otg_probe ORDER BY step" > "$OUT_DIR/probe_${i}.tsv"
    printf "%3ds  %s probes\n" "$((SECONDS - start))" "$(wc -l < "$OUT_DIR/probe_${i}.tsv")"
done

# --------------------------------------------------------------------- compare
echo
python3 - "$OUT_DIR" "$TRIALS" <<'REPORT'
import sys
out_dir, trials = sys.argv[1], int(sys.argv[2])
COLS = ["bus_noid", "bus_full", "branch_noid", "branch_full",
        "topo_md5", "circ_md5", "line_md5"]

runs = []
for i in range(1, trials + 1):
    rows = {}
    for ln in open(f"{out_dir}/probe_{i}.tsv", encoding="utf-8"):
        f = ln.rstrip("\n").split("\t")
        if len(f) < 14:
            continue
        rows[int(f[0])] = dict(line=f[1], label=f[2], bus_rows=f[3],
                               branch_rows=f[4], linesep_rows=f[5],
                               bus_noid=f[6], bus_full=f[7],
                               branch_noid=f[8], topo_md5=f[9],
                               circ_md5=f[10], line_md5=f[11],
                               bus_cols=f[12], branch_full=f[13])
    runs.append(rows)

steps = sorted(set().union(*[set(r) for r in runs]))
print("=" * 104)
print("Distinct values per fingerprint, per step   (1 = stable, xN = N variants)")
print("=" * 104)
print(f"  {'step':>4} {'line':>5}  {'label':<34}"
      + "".join(f"{c:>12}" for c in COLS))

firsts = {}
for st in steps:
    present = [r[st] for r in runs if st in r]
    v0 = present[0]
    counts = {c: len({v[c] for v in present}) for c in COLS}
    for c in COLS:
        if counts[c] > 1 and c not in firsts:
            firsts[c] = (st, v0["line"], v0["label"])
    marks = "".join((f"{counts[c]:>13}" if counts[c] == 1
                     else f"{('x' + str(counts[c])):>13}") for c in COLS)
    print(f"  {st:>4} {v0['line']:>5}  {v0['label']:<36}{marks}"
          f"   {v0['bus_rows']}/{v0['branch_rows']}/{v0['linesep_rows']}")

print()
print("=" * 104)
for c in COLS:
    if c in firsts:
        st, line, label = firsts[c]
        print(f"  {c:<12} first differs at step {st:>3}  "
              f"power_script.sql:{line}  {label}")
    else:
        print(f"  {c:<12} stable across all {trials} trials")

# attribute a bus_data divergence to specific columns
if "bus_noid" in firsts or "bus_full" in firsts:
    st = min(firsts[c][0] for c in ("bus_noid", "bus_full") if c in firsts)
    present = [r[st] for r in runs if st in r]
    parsed = []
    for v in present:
        d = {}
        for tok in (v.get("bus_cols") or "").split(" "):
            if ":" in tok:
                k, h = tok.split(":", 1)
                d[k] = h
        parsed.append(d)
    keys = sorted(set().union(*[set(d) for d in parsed])) if parsed else []
    differing = [k for k in keys if len({d.get(k) for d in parsed}) > 1]
    print()
    print(f"  bus_data columns differing at step {st}:")
    if differing:
        for k in differing:
            variants = sorted({d.get(k) for d in parsed})
            print(f"    {k:<16} {len(variants)} variants  {variants}")
    else:
        print("    none - the per-column hashes all agree, so the difference"
              " is in the row *combination*, not a single column")
REPORT
