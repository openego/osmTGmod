#!/usr/bin/env bash
#
# Phase 0 harness for issue #769: run osmTGmod's abstraction repeatedly
# against one prepared database and check whether it is reproducible.
#
# Why this works without re-importing OSM data: `power_script.sql` makes no
# writes at all to the raw `power_ways` / `power_nodes` / `power_relations`
# tables (those are only written by `otg_create_power_tables()`, which runs
# at import time). It opens by dropping every working table it owns --
# bus_data, branch_data, power_line, power_substation, power_line_sep, the
# split_table_* set -- and rebuilds them from the raw tables. So it is
# idempotent, and each execution is a genuine independent trial with
# byte-identical input.
#
# Requires a database in which egon-data has already run
# `Osmtgmod.import_osm_data` (raw power tables, nuts_poly, abstr_values)
# and `SubstationExtraction` (transfer_busses).
#
# Usage:
#   ./AI/otg_trials.sh [N] [--yes]
#
#   N        number of trials, default 10
#   --yes    skip the confirmation prompt
#   --pin-plans
#            run with synchronize_seqscans=off and no parallel workers.
#            Diagnostic: if trials become deterministic only with this,
#            the abstraction is sensitive to physical scan order; if they
#            stay non-deterministic, something else is in play.
#
# Env: PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
#      OSMTGMOD_DIR   checkout to take sql-scripts/power_script.sql from
#                     (default: AI/material/osmTGmod) -- point this at a
#                     patched checkout to test a fix
#
# NOTE: this rewrites osmTGmod's working tables in the target database.
# `osmtgmod_results.*` is NOT touched -- that is written by
# `otg_save_results()`, which this harness never calls.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TRIALS=10
ASSUME_YES=0
PIN_PLANS=0
for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        --pin-plans) PIN_PLANS=1 ;;
        [0-9]*) TRIALS="$arg" ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done

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
RESULTS="$OUT_DIR/trials.tsv"

mkdir -p "$OUT_DIR"

if [[ ! -f "$POWER_SCRIPT" ]]; then
    echo "power_script.sql not found at: $POWER_SCRIPT" >&2
    exit 1
fi

q() { psql -X -q -A -t -v ON_ERROR_STOP=1 -c "$1"; }

# ------------------------------------------------------------------ preflight
echo "osmTGmod trial harness"
echo "  database    : $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
echo "  power_script: $POWER_SCRIPT"
echo "  trials      : $TRIALS"
if git -C "$OSMTGMOD_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "  checkout    : $(git -C "$OSMTGMOD_DIR" rev-parse --abbrev-ref HEAD)" \
         "$(git -C "$OSMTGMOD_DIR" rev-parse --short HEAD)" \
         "$(git -C "$OSMTGMOD_DIR" diff --quiet || echo '(dirty)')"
fi
echo "  functions.sql   md5 $(md5sum "$FUNCTIONS_SQL" | cut -c1-12)"
echo "  power_script.sql md5 $(md5sum "$POWER_SCRIPT" | cut -c1-12)"
echo

if ! q "SELECT 1" >/dev/null 2>&1; then
    echo "cannot connect to the database" >&2
    exit 1
fi

echo "-- server"
q "SELECT '  ' || version()"
q "SELECT '  ' || name || ' = ' || setting FROM pg_settings
   WHERE name IN ('work_mem','max_parallel_workers_per_gather',
                  'enable_hashjoin','enable_mergejoin','enable_nestloop',
                  'synchronize_seqscans')
   ORDER BY name"

echo "-- required input tables"
missing=0
for t in power_ways power_relations transfer_busses nuts_poly abstr_values; do
    n=$(q "SELECT count(*) FROM $t" 2>/dev/null)
    if [[ -z "$n" ]]; then
        printf "  %-20s MISSING\n" "$t"; missing=1
    elif [[ "$n" == "0" ]]; then
        printf "  %-20s EMPTY\n" "$t"; missing=1
    else
        printf "  %-20s %s rows\n" "$t" "$n"
    fi
done
if [[ $missing -ne 0 ]]; then
    echo
    echo "Input is incomplete. This database has not completed" >&2
    echo "Osmtgmod.import_osm_data and/or SubstationExtraction." >&2
    exit 1
fi

echo "-- abstraction settings (abstr_values)"
q "SELECT '  ' || rpad(val_description, 16) || ' = ' ||
          coalesce(val_int::text, val_bool::text, '(null)')
   FROM abstr_values ORDER BY val_id"

echo
echo "This will drop and rebuild osmTGmod's working tables (bus_data,"
echo "branch_data, power_line, power_substation, power_line_sep, splits)"
echo "in $PGDATABASE. osmtgmod_results.* is left alone."
if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "Proceed? [y/N] " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "aborted"; exit 1; }
fi

# --------------------------------------------------------------- fingerprints
# bus_full     : full contents, ordered by id. Changes if anything changes.
# bus_noid     : contents with `id` dropped, ordered by the content itself.
#                Identical bus_noid with differing bus_full means the buses
#                were merely renumbered; differing bus_noid means the
#                abstraction actually produced different buses.
# branch_full  : full contents ordered by branch_id.
read -r -d '' FINGERPRINT_SQL <<'SQL'
SELECT
  (SELECT count(*) FROM bus_data),
  (SELECT count(*) FROM branch_data),
  (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), ''))
     FROM bus_data t),
  (SELECT md5(coalesce(string_agg(j, '|' ORDER BY j), ''))
     FROM (SELECT (to_jsonb(t) - 'id')::text AS j FROM bus_data t) s),
  (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, '|'
                                  ORDER BY t.branch_id), ''))
     FROM branch_data t),
  -- branch_data with branch_id dropped. Together with branch_full this
  -- separates a pure renumbering of branches from a real content change --
  -- the same distinction bus_noid/bus_full already gives for buses.
  (SELECT md5(coalesce(string_agg(j, '|' ORDER BY j), ''))
     FROM (SELECT (to_jsonb(t) - 'branch_id')::text AS j
             FROM branch_data t) s)
SQL

# The abstraction logic lives in the database: egon-data loads
# functions.sql during import. Editing it on disk changes nothing until it
# is reloaded, so reload it here -- it is pure DDL (66 CREATE OR REPLACE
# FUNCTION plus 7 triggers, nothing top-level), so this touches no data.
echo
echo -n "reloading $FUNCTIONS_SQL ... "
if psql -X -q -v ON_ERROR_STOP=1 -f "$FUNCTIONS_SQL" > "$OUT_DIR/functions_reload.log" 2>&1
then
    echo "ok"
else
    echo "FAILED, see $OUT_DIR/functions_reload.log"
    tail -n 15 "$OUT_DIR/functions_reload.log" | sed 's/^/    /'
    exit 1
fi

if [[ $PIN_PLANS -eq 1 ]]; then
    export PGOPTIONS="-c synchronize_seqscans=off -c max_parallel_workers_per_gather=0"
    echo
    echo "plans pinned: synchronize_seqscans=off, max_parallel_workers_per_gather=0"
fi

# ------------------------------------------------------------------- the loop
# Keep previous results: the point of the exercise is before/after.
if [[ -f "$RESULTS" ]]; then
    n=1
    while [[ -e "$OUT_DIR/trials.prev$n.tsv" ]]; do n=$((n + 1)); done
    mv "$RESULTS" "$OUT_DIR/trials.prev$n.tsv"
    echo "previous results kept as trials.prev$n.tsv"
fi

printf 'trial\tseconds\tbus_rows\tbranch_rows\tbus_full\tbus_noid\tbranch_full\tbranch_noid\n' \
    > "$RESULTS"

for ((i = 1; i <= TRIALS; i++)); do
    log="$OUT_DIR/trial_${i}.log"
    printf "trial %2d/%d ... " "$i" "$TRIALS"
    # A previous run that died partway can leave split_table_* and other
    # mid-script tables behind, making the next run fail on CREATE TABLE.
    # Clear them so every trial is independent.
    psql -X -q -f "$HERE/otg_cleanup.sql" >/dev/null 2>&1
    start=$SECONDS
    if ! psql -X -q -v ON_ERROR_STOP=1 -f "$POWER_SCRIPT" > "$log" 2>&1; then
        echo "FAILED, see $log"
        tail -n 15 "$log" | sed 's/^/    /'
        exit 1
    fi
    elapsed=$((SECONDS - start))

    line=$(psql -X -q -A -t -F $'\t' -v ON_ERROR_STOP=1 -c "$FINGERPRINT_SQL")
    printf '%d\t%d\t%s\n' "$i" "$elapsed" "$line" >> "$RESULTS"

    bus_rows=$(cut -f1 <<< "$line")
    bus_full=$(cut -f3 <<< "$line")
    printf "%3ds  %s buses  %s\n" "$elapsed" "$bus_rows" "${bus_full:0:12}"
done

# --------------------------------------------------------------------- verdict
echo
echo "======================================================================"
echo "Result over $TRIALS trials"
echo "======================================================================"
column -t -s $'\t' "$RESULTS" | sed 's/^/  /'

distinct() { tail -n +2 "$RESULTS" | cut -f"$1" | sort -u | wc -l; }
n_full=$(distinct 5)
n_noid=$(distinct 6)
n_branch=$(distinct 7)
n_bnoid=$(distinct 8)
n_rows=$(distinct 3)

echo
printf "  distinct bus_rows    : %s\n" "$n_rows"
printf "  distinct bus_full    : %s\n" "$n_full"
printf "  distinct bus_noid    : %s\n" "$n_noid"
printf "  distinct branch_full : %s\n" "$n_branch"
printf "  distinct branch_noid : %s\n" "$n_bnoid"
echo

if [[ "$n_full" -eq 1 && "$n_branch" -eq 1 ]]; then
    echo "  DETERMINISTIC across $TRIALS trials."
    echo "  (Not a proof, but this is the loop a fix has to keep green.)"
    exit 0
fi

echo "  NON-DETERMINISTIC -- reproduced in $TRIALS trials."
if [[ "$n_noid" -eq 1 && "$n_full" -gt 1 ]]; then
    echo "  bus_noid is constant while bus_full varies: the buses are the"
    echo "  same, only their ids differ. Renumbering alone."
else
    echo "  bus_noid varies too: the abstraction produced genuinely"
    echo "  different buses, not just a renumbering."
fi
echo
echo "  Next: bisect which otg_* call diverges (phase 1)."
exit 1
