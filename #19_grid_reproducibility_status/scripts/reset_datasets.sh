#!/usr/bin/env bash
#
# Force the datasets on the grid-district chain to re-execute on the next
# pipeline trigger, without editing any version strings.
#
# A `Dataset` skips all of its tasks when `metadata.datasets` already holds
# a row with its name, version and scenarios (see `Dataset.check_version`).
# Re-triggering the DAG against the same database therefore does NOT
# re-execute a dataset whose version has not changed -- its tables keep the
# content of an earlier run, while datasets that *did* change are refreshed
# around them. That silently produces a database whose tables were built at
# different points in time, which makes run-to-run comparisons meaningless.
#
# Deleting the recorded rows is enough to force execution. Note that
# `metadata.dependency_graph` references `metadata.datasets.id` without
# ON DELETE CASCADE, so those rows have to go first.
#
# Usage (before each pipeline run):
#   ./AI/reset_datasets.sh
#
# Connection defaults match the egon-data docker database; override via
# PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE, e.g.
#   PGDATABASE=test-egon-data ./AI/reset_datasets.sh

set -uo pipefail

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-59734}"
export PGUSER="${PGUSER:-egon}"
export PGPASSWORD="${PGPASSWORD:-data}"
export PGDATABASE="${PGDATABASE:-egon-data}"

# Every dataset between the OSM import and the grid districts. Leaving any
# of these out is what invalidated the earlier comparison runs.
DATASETS="'Osmtgmod', 'substation_extraction', 'substation_voronoi', 'MvGridDistricts'"

echo "Resetting dataset versions in $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
echo "  datasets: $DATASETS"

psql -v ON_ERROR_STOP=1 -q <<SQL
BEGIN;

\echo '-- recorded before:'
SELECT name, version FROM metadata.datasets
WHERE name IN ($DATASETS) ORDER BY name;

DELETE FROM metadata.dependency_graph
WHERE dependency_id IN (
          SELECT id FROM metadata.datasets WHERE name IN ($DATASETS))
   OR dependent_id IN (
          SELECT id FROM metadata.datasets WHERE name IN ($DATASETS));

DELETE FROM metadata.datasets WHERE name IN ($DATASETS);

\echo '-- recorded after (should be empty):'
SELECT name, version FROM metadata.datasets
WHERE name IN ($DATASETS) ORDER BY name;

COMMIT;
SQL

status=$?
if [[ $status -eq 0 ]]; then
    echo "Done. The next pipeline run will re-execute these datasets."
else
    echo "FAILED (exit $status) -- nothing was changed, the whole reset" >&2
    echo "runs in one transaction." >&2
fi
exit $status
