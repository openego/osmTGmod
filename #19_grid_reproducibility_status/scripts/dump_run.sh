#!/usr/bin/env bash
#
# Dump the tables relevant to issue #804 (grid districts differ between runs)
# for one egon-data run, so that several runs can be diffed afterwards.
#
# Usage:
#   ./AI/dump_run.sh run1
#   ./AI/dump_run.sh run2
#
# Connection defaults match the egon-data docker database. Override via env:
#   PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
# e.g.
#   PGDATABASE=test-egon-data ./AI/dump_run.sh run1
#
# Everything is ordered by a key that is *stable across runs* (osm_id), never
# by bus_id -- bus_id is the value under suspicion, so ordering by it would
# renumber rows in lockstep and hide the very shift we are looking for.

set -uo pipefail

RUN="${1:-}"
if [[ -z "$RUN" ]]; then
    echo "usage: $0 <run-label>   e.g. $0 run1" >&2
    exit 1
fi

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-59734}"
export PGUSER="${PGUSER:-egon}"
export PGPASSWORD="${PGPASSWORD:-data}"
export PGDATABASE="${PGDATABASE:-egon-data}"

OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results"
mkdir -p "$OUT_DIR"

echo "Dumping '$RUN' from $PGUSER@$PGHOST:$PGPORT/$PGDATABASE into $OUT_DIR"

dump() {
    local name="$1"
    local sql="$2"
    local target="$OUT_DIR/${RUN}_${name}.csv"

    if psql -v ON_ERROR_STOP=1 -q \
            -c "COPY ($sql) TO STDOUT WITH (FORMAT csv, HEADER)" > "$target" 2>/tmp/dump_err.$$
    then
        printf '  %-28s %6s rows\n' "$name" "$(( $(wc -l < "$target") - 1 ))"
    else
        echo "  $name: FAILED" >&2
        sed 's/^/    /' /tmp/dump_err.$$ >&2
        rm -f "$target"
    fi
    rm -f /tmp/dump_err.$$
}

# 1. Suspected origin of the divergence: built with DISTINCT ON (osm_id) over a
#    subquery ORDER BY, so the surviving row per osm_id is arbitrary.
dump transfer_busses_complete "
    SELECT osm_id, bus_id, status, voltage, ST_AsText(point) AS point
    FROM public.transfer_busses_complete
    ORDER BY osm_id"

# 2. Its two inputs. bus_id here is a serial filled in arbitrary scan order.
dump hvmv_transfer_buses "
    SELECT osm_id, bus_id, status, voltage, ST_AsText(point) AS point
    FROM grid.egon_hvmv_transfer_buses
    ORDER BY osm_id, bus_id"

dump ehv_transfer_buses "
    SELECT osm_id, bus_id, status, voltage, ST_AsText(point) AS point
    FROM grid.egon_ehv_transfer_buses
    ORDER BY osm_id, bus_id"

# 3. osmTGmod's own output -- tells us whether osmTGmod itself is the
#    non-reproducible part (issue #769) or merely inherits it.
dump otg_bus_data "
    SELECT osm_substation_id, bus_i, base_kv, cntr_id, ST_AsText(geom) AS geom
    FROM osmtgmod_results.bus_data
    WHERE result_id = 1
    ORDER BY osm_substation_id, bus_i, base_kv"

# 4. The table #769 points at.
dump egon_hvmv_substation "
    SELECT osm_id, bus_id, status, voltage, subst_name,
           ST_AsText(point) AS point
    FROM grid.egon_hvmv_substation
    ORDER BY osm_id"

# 4b. The third input to the grid district algorithm. Dumped so that a
#     difference in the districts can be attributed, rather than assumed
#     to come from the substations.
dump vg250_gem_clean "
    SELECT id, ags_0, gen, round(area_ha::numeric, 2) AS area_ha,
           md5(ST_AsBinary(ST_Normalize(geometry))) AS geom_md5
    FROM boundaries.vg250_gem_clean
    ORDER BY id"

# 4c. Which datasets actually executed in this run, and at which version.
#     A dataset whose row is already present is SKIPPED, so its tables
#     keep the content of an earlier run -- see issue #804 discussion.
dump dataset_versions "
    SELECT name, version, scenarios
    FROM metadata.datasets
    ORDER BY name"

# 5. Voronoi polygons derived from it (input to the grid district algorithm).
dump hvmv_substation_voronoi "
    SELECT bus_id, ST_NPoints(geom) AS npoints,
           ST_AsText(ST_Centroid(geom)) AS centroid,
           md5(ST_AsBinary(ST_Normalize(geom))) AS geom_md5
    FROM grid.egon_hvmv_substation_voronoi
    ORDER BY bus_id"

# 6. The end result, as a compact fingerprint.
dump mv_grid_district_fingerprint "
    SELECT bus_id, round(area::numeric, 3) AS area,
           ST_NPoints(geom) AS npoints,
           ST_AsText(ST_Centroid(geom)) AS centroid,
           md5(ST_AsBinary(ST_Normalize(geom))) AS geom_md5
    FROM grid.egon_mv_grid_district
    ORDER BY bus_id"

# 6b. Full geometry too. Fine for Schleswig-Holstein; large for all of Germany.
dump mv_grid_district "
    SELECT bus_id, area, ST_AsText(geom) AS geom_wkt
    FROM grid.egon_mv_grid_district
    ORDER BY bus_id"

echo "Done."