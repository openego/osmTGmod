"""
Verify the fix for issue #804 without re-running the whole pipeline.

The grid district algorithm is rebuilt from scratch on every run out of just
three tables (`boundaries.vg250_gem_clean`, `grid.egon_hvmv_substation`,
`grid.egon_hvmv_substation_voronoi`). So it can be re-executed repeatedly
against one existing database, which holds the *substation input constant*
and therefore isolates #804 from #769 (osmTGmod's own irreproducibility).

Two independent checks:

* ``--probe`` (cheap, conclusive, read-only) counts how many municipality
  assignments are decided by a *tie*, i.e. how many polygons touch more
  than one candidate district and are therefore all at `ST_Distance` 0.
  Every one of those is a coin flip on the unfixed code. This does not
  depend on catching a flip in the act, so it is the check to trust.

* the default mode re-runs ``define_mv_grid_districts()`` several times
  with different query plans and compares the results. An arbitrary
  ``DISTINCT ON`` pick follows whichever plan the planner chose, so
  forcing different join strategies and sort behaviour can flip it. This
  is empirical: agreement is weak evidence, disagreement is proof.

Usage (from the egon-data working directory, i.e. the one containing
`egon-data.configuration.yaml`, with the egon-data venv active):

    python /path/to/AI/verify_804.py --probe     # start here
    python /path/to/AI/verify_804.py
    python /path/to/AI/verify_804.py --cluster   # strongest perturbation

`--cluster` additionally reorders the source tables physically between
repetitions (via CLUSTER on their spatial index). Row order is what an
unordered `DISTINCT ON` actually follows, so this is the most effective
knob -- but note it rewrites those tables in place. Harmless to their
contents, but don't point it at a database you care about preserving
byte-for-byte.
"""

import argparse

from egon.data import db
from egon.data.datasets.mv_grid_districts import define_mv_grid_districts

# Each entry is one repetition: settings that push PostgreSQL towards a
# different plan for the neighbour-assignment queries. `work_mem` matters
# because `DISTINCT ON` is implemented as Sort+Unique on the DISTINCT ON
# key alone; that sort is not stable, so whether the subquery's own
# ordering survives depends on which sort algorithm is used.
PLAN_VARIANTS = {
    "default": {},
    "no-hashjoin": {"enable_hashjoin": "off"},
    "no-mergejoin": {"enable_mergejoin": "off"},
    "no-nestloop": {"enable_nestloop": "off"},
    "no-seqscan": {"enable_seqscan": "off"},
    "no-parallel": {"max_parallel_workers_per_gather": "0"},
    "nestloop-only": {"enable_hashjoin": "off", "enable_mergejoin": "off"},
    "tiny-work-mem": {"work_mem": "'64kB'"},
    "tiny-work-mem-nohash": {"work_mem": "'64kB'", "enable_hashjoin": "off"},
    "huge-work-mem": {"work_mem": "'512MB'"},
}

FINGERPRINT = """
    SELECT bus_id,
           round(area::numeric, 3) AS area,
           md5(ST_AsBinary(ST_Normalize(geom))) AS geom_md5
    FROM grid.egon_mv_grid_district
    ORDER BY bus_id
"""

# Municipalities holding no substation are assigned whole, to the "nearest"
# district. Every district their polygon touches was a candidate at
# distance exactly 0, so any count > 1 is a tie the ORDER BY cannot break
# on its own. Counts are an upper bound: the iterative assignment loop may
# not have had every neighbour available yet at the time it decided.
TIE_PROBE = """
    WITH municipalities_without_substation AS (
        SELECT g.id, g.geometry
        FROM boundaries.vg250_gem_clean g
        LEFT JOIN grid.egon_hvmv_substation s
               ON ST_Contains(g.geometry, ST_Transform(s.point, 3035))
        GROUP BY g.id, g.geometry
        HAVING count(s.bus_id) = 0
    )
    SELECT m.id,
           count(DISTINCT d.bus_id) AS candidate_districts,
           round(ST_Area(m.geometry)::numeric / 1e6, 1) AS area_km2
    FROM municipalities_without_substation m
    JOIN grid.egon_mv_grid_district d
      ON ST_Intersects(m.geometry, d.geom)
    GROUP BY m.id, m.geometry
    ORDER BY count(DISTINCT d.bus_id) DESC, m.id
"""

SOURCE_TABLES = [
    "boundaries.vg250_gem_clean",
    "grid.egon_hvmv_substation",
    "grid.egon_hvmv_substation_voronoi",
]


def database_name():
    return db.credentials()["POSTGRES_DB"]


def apply_settings(settings):
    """Set planner GUCs as database defaults and force fresh connections.

    `ALTER DATABASE ... SET` only takes effect for sessions opened
    afterwards. egon-data caches its engine and pools connections, so
    without disposing the pool the already-open connections -- carrying the
    *old* settings -- would be handed back out and the perturbation would
    silently do nothing.
    """
    name = database_name()
    for key, value in settings.items():
        db.execute_sql(f'ALTER DATABASE "{name}" SET {key} = {value};')
    db.engine().dispose()


def reset_settings(settings):
    name = database_name()
    for key in settings:
        db.execute_sql(f'ALTER DATABASE "{name}" RESET {key};')
    db.engine().dispose()


def effective_settings(keys):
    """Read the settings back through a *worker* connection."""
    if not keys:
        return {}
    columns = ", ".join(f"current_setting('{k}') AS {k}" for k in keys)
    row = db.select_dataframe(f"SELECT {columns}", warning=False).iloc[0]
    return dict(row)


def cluster_source_tables():
    """Reorder the source tables physically, to change scan order.

    An unordered `DISTINCT ON` returns whichever row the scan reaches
    first, so heap order is the dominant influence on the arbitrary pick.
    """
    for qualified in SOURCE_TABLES:
        schema, table = qualified.split(".")
        index = db.select_dataframe(
            f"""
            SELECT indexname FROM pg_indexes
            WHERE schemaname = '{schema}' AND tablename = '{table}'
            ORDER BY indexname
            LIMIT 1
            """,
            warning=False,
        )
        if index.empty:
            print(f"    no index on {qualified}, cannot CLUSTER")
            continue
        name = index.iloc[0]["indexname"]
        try:
            db.execute_sql(f"CLUSTER {qualified} USING {name};")
            db.execute_sql(f"ANALYZE {qualified};")
            print(f"    clustered {qualified} on {name}")
        except Exception as error:  # noqa: BLE001
            print(f"    could not CLUSTER {qualified}: {error}")


def fingerprint():
    rows = db.select_dataframe(FINGERPRINT, warning=False)
    return rows, tuple(map(tuple, rows.values))


def probe():
    """Count assignments that are decided by a tie rather than by distance."""
    result = db.select_dataframe(TIE_PROBE, warning=False)
    total = len(result)
    tied = result[result["candidate_districts"] > 1]

    print("=" * 70)
    print("Tie exposure of the municipality assignment")
    print("=" * 70)
    print(f"  municipalities without their own substation : {total}")
    print(f"  of those, touching >1 grid district         : {len(tied)}")
    if total:
        print(f"  i.e. {100 * len(tied) / total:.0f}% of these assignments"
              " have at least two candidates at distance 0")
    print()

    if tied.empty:
        print("  No ties at all -- on this data set the unfixed code cannot")
        print("  flip, and comparing repeated runs will prove nothing.")
        return 0

    print(f"  {'vg250_gem_clean.id':>20}{'candidates':>13}{'area km2':>12}")
    for _, row in tied.head(25).iterrows():
        print(f"  {int(row['id']):>20}{int(row['candidate_districts']):>13}"
              f"{float(row['area_km2']):>12,.1f}")
    if len(tied) > 25:
        print(f"  ... and {len(tied) - 25} more")

    print()
    print("  Every row above is an assignment the unfixed code decides by")
    print("  whichever row the query plan happens to surface first. After")
    print("  the fix they are decided by centroid distance, then bus_id.")
    return 0


def compare(cluster):
    results = {}

    for label, settings in PLAN_VARIANTS.items():
        print(f"--- repetition '{label}' {settings or '(as configured)'}")
        apply_settings(settings)
        try:
            if settings:
                shown = effective_settings(list(settings))
                print(f"    in effect: {shown}")
                for key, value in settings.items():
                    want = value.strip("'").lower()
                    got = str(shown.get(key, "")).lower()
                    if want not in (got, got.replace("kb", "kb")):
                        print(f"    WARNING: {key} is '{got}',"
                              f" expected '{want}' -- perturbation may not"
                              " have been applied")
            if cluster:
                cluster_source_tables()
            define_mv_grid_districts()
            frame, key = fingerprint()
            results[label] = key
            print(f"    {len(frame)} grid districts")
        finally:
            reset_settings(settings)

    distinct = {}
    for label, key in results.items():
        distinct.setdefault(key, []).append(label)

    print()
    print("=" * 70)
    if len(distinct) == 1:
        print(f"No disagreement across {len(results)} repetitions.")
        print()
        print("This is NOT proof of determinism -- an arbitrary pick only")
        print("flips when the plan actually changes. Run with --probe to")
        print("see how many assignments are ties, and with --cluster to")
        print("perturb physical row order, which is the stronger knob.")
        return 0

    print(f"NON-DETERMINISTIC: {len(results)} repetitions produced "
          f"{len(distinct)} different results.")
    for i, (key, labels) in enumerate(distinct.items(), start=1):
        print(f"  result {i}: {len(key)} districts, from {labels}")

    first, second = list(distinct)[:2]
    a = {row[0]: row for row in first}
    b = {row[0]: row for row in second}
    changed = sorted(k for k in set(a) & set(b) if a[k] != b[k])
    print(f"\n  bus_ids only in result 1: {sorted(set(a) - set(b))}")
    print(f"  bus_ids only in result 2: {sorted(set(b) - set(a))}")
    print(f"  bus_ids with a different geometry ({len(changed)}): "
          f"{changed[:20]}{' ...' if len(changed) > 20 else ''}")
    for k in changed[:10]:
        print(f"    bus_id {k}: area {a[k][1]} -> {b[k][1]}")
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--probe",
        action="store_true",
        help="only count tie-decided assignments (read-only, fast)",
    )
    parser.add_argument(
        "--cluster",
        action="store_true",
        help="also reorder the source tables physically between runs",
    )
    args = parser.parse_args()

    return probe() if args.probe else compare(args.cluster)


if __name__ == "__main__":
    raise SystemExit(main())
