"""
Compare two runs dumped by `dump_run.sh`, stage by stage.

Every table is compared on a key that is *stable across runs*, never on a
value that is itself suspected of moving. In particular grid districts and
voronoi cells are re-keyed from `bus_id` to the `osm_id` of the substation
carrying that `bus_id`, because osmTGmod may renumber buses.

Usage:

    python AI/compare_runs.py run5 run6
    python AI/compare_runs.py run1 run2 --dir AI/results/results

Reads `<dir>/<run>_<table>.csv` for every table `dump_run.sh` writes and
skips whatever is missing.
"""

import argparse
import csv
import sys
from pathlib import Path

csv.field_size_limit(sys.maxsize)

#: table -> columns forming a run-stable key. `None` means "compare the
#: whole set of rows", used where no stable key exists.
KEYS = {
    "transfer_busses_complete": ["osm_id"],
    "hvmv_transfer_buses": ["osm_id"],
    "ehv_transfer_buses": ["osm_id"],
    "otg_bus_data": None,
    "egon_hvmv_substation": ["osm_id"],
    "hvmv_substation_voronoi": ["__osm_id__"],
    "mv_grid_district_fingerprint": ["__osm_id__"],
    "mv_grid_district": ["__osm_id__"],
}


def load(directory, run, table):
    path = directory / f"{run}_{table}.csv"
    if not path.exists():
        return None
    with open(path) as handle:
        return list(csv.DictReader(handle))


def bus_to_osm(directory, run):
    """Map bus_id -> substation osm_id, so districts can be re-keyed."""
    rows = load(directory, run, "egon_hvmv_substation")
    if rows is None:
        return {}
    return {row["bus_id"]: row["osm_id"] for row in rows}


def keyed(rows, key_columns, mapping):
    out = {}
    for row in rows:
        if key_columns == ["__osm_id__"]:
            key = mapping.get(row["bus_id"], f"<bus_id:{row['bus_id']}>")
        else:
            key = tuple(row[c] for c in key_columns)
        out.setdefault(key, []).append(row)
    return out


#: Columns holding a float that is summed in SQL. Summation over a group
#: is order-dependent in the last bit, so a difference of a few ULP means
#: the aggregate ran in a different order, not that the data changed.
#: `grid.egon_mv_grid_district.area` is `sum(...)` over the district's
#: parts and wobbles by ~1e-8 m² on an otherwise byte-identical geometry.
FLOAT_NOISE_COLUMNS = {"area"}
FLOAT_NOISE_TOLERANCE = 1e-9  # relative


def cells_equal(column, left, right):
    if column not in FLOAT_NOISE_COLUMNS or left == right:
        return left == right
    try:
        a, b = float(left), float(right)
    except (TypeError, ValueError):
        return False
    scale = max(abs(a), abs(b), 1.0)
    return abs(a - b) / scale <= FLOAT_NOISE_TOLERANCE


def rows_equal(left, right):
    """Compare two row lists, ignoring bus_id and float-summation noise.

    bus_id is excluded because renumbering is reported separately and
    would otherwise mask every other change.
    """
    if len(left) != len(right):
        return False, False
    exact = True
    for row_a, row_b in zip(left, right):
        columns = set(row_a) | set(row_b)
        for column in columns:
            if column == "bus_id":
                continue
            value_a, value_b = row_a.get(column), row_b.get(column)
            if value_a != value_b:
                exact = False
                if not cells_equal(column, value_a, value_b):
                    return False, False
    return True, exact


def compare_keyed(a_rows, b_rows, key_columns, map_a, map_b):
    a = keyed(a_rows, key_columns, map_a)
    b = keyed(b_rows, key_columns, map_b)

    only_a = sorted(set(a) - set(b), key=str)
    only_b = sorted(set(b) - set(a), key=str)
    shared = sorted(set(a) & set(b), key=str)

    differing = []
    noise_only = []
    for key in shared:
        equal, exact = rows_equal(a[key], b[key])
        if not equal:
            differing.append(key)
        elif not exact:
            noise_only.append(key)

    renumbered = [
        key
        for key in shared
        if len(a[key]) == 1
        and len(b[key]) == 1
        and "bus_id" in a[key][0]
        and a[key][0]["bus_id"] != b[key][0]["bus_id"]
    ]
    return only_a, only_b, shared, differing, renumbered, noise_only


def compare_sets(a_rows, b_rows):
    a = {tuple(sorted(row.items())) for row in a_rows}
    b = {tuple(sorted(row.items())) for row in b_rows}
    return sorted(a - b), sorted(b - a), a & b


def show_row(row, limit=4):
    items = [f"{k}={v}" for k, v in row if k != "geom_wkt"]
    return " ".join(items[:limit])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_a")
    parser.add_argument("run_b")
    parser.add_argument(
        "--dir",
        default=None,
        help="directory holding the dumps (default: auto-detect)",
    )
    args = parser.parse_args()

    here = Path(__file__).resolve().parent
    candidates = (
        [Path(args.dir)]
        if args.dir
        else [here.parent / "results", here.parent / "data",
              here / "results" / "results", here / "results", here,
              Path.cwd()]
    )
    directory = next(
        (
            d
            for d in candidates
            if (d / f"{args.run_a}_egon_hvmv_substation.csv").exists()
        ),
        None,
    )
    if directory is None:
        print(f"Found no dumps for '{args.run_a}' in: "
              + ", ".join(str(d) for d in candidates))
        return 2

    print(f"Comparing '{args.run_a}' vs '{args.run_b}' in {directory}\n")
    map_a = bus_to_osm(directory, args.run_a)
    map_b = bus_to_osm(directory, args.run_b)

    verdicts = {}
    for table, key_columns in KEYS.items():
        a_rows = load(directory, args.run_a, table)
        b_rows = load(directory, args.run_b, table)
        if a_rows is None or b_rows is None:
            print(f"-- {table}: missing in one of the runs, skipped")
            continue

        print("=" * 70)
        print(f"{table}   ({len(a_rows)} vs {len(b_rows)} rows)")
        print("=" * 70)

        if key_columns is None:
            only_a, only_b, shared = compare_sets(a_rows, b_rows)
            identical = not only_a and not only_b
            print(f"  identical rows      : {len(shared)}")
            print(f"  only in {args.run_a:<12}: {len(only_a)}")
            print(f"  only in {args.run_b:<12}: {len(only_b)}")
            for row in only_a[:5]:
                print(f"    - {show_row(row)}")
            for row in only_b[:5]:
                print(f"    + {show_row(row)}")
        else:
            (only_a, only_b, shared, differing, renumbered,
             noise_only) = compare_keyed(
                a_rows, b_rows, key_columns, map_a, map_b
            )
            identical = not only_a and not only_b and not differing
            label = ("substation osm_id" if key_columns == ["__osm_id__"]
                     else "+".join(key_columns))
            print(f"  keyed on            : {label}")
            print(f"  present in both     : {len(shared)}")
            print(f"  identical           : {len(shared) - len(differing)}")
            print(f"  differing content   : {len(differing)}")
            if noise_only:
                print(f"  of the identical ones, {len(noise_only)} differ"
                      " only in a summed float by a few ULP"
                      " (aggregate ran in a different order, data is"
                      " unchanged)")
            print(f"  only in {args.run_a:<12}: {len(only_a)}"
                  f"{'  ' + str(only_a[:5]) if only_a else ''}")
            print(f"  only in {args.run_b:<12}: {len(only_b)}"
                  f"{'  ' + str(only_b[:5]) if only_b else ''}")
            if renumbered:
                print(f"  same key, different bus_id: {len(renumbered)}"
                      f"  e.g. {renumbered[:5]}")
            for key in differing[:8]:
                print(f"    differs: {key}")

        verdicts[table] = identical
        print(f"  -> {'IDENTICAL' if identical else 'DIFFERS'}\n")

    print("=" * 70)
    print("Summary")
    print("=" * 70)
    for table, identical in verdicts.items():
        print(f"  {'IDENTICAL' if identical else 'DIFFERS  '}  {table}")

    print()
    if verdicts.get("otg_bus_data") is False:
        print("  osmtgmod_results.bus_data differs between the runs.")
        if verdicts.get("transfer_busses_complete", True):
            print("  Its egon-data input (transfer_busses_complete) does")
            print("  not, so the irreproducibility is internal to osmTGmod")
            print("  -- issue #769 cannot be closed from egon-data.")
        else:
            print("  Its input differs too, so fix that first.")
    elif "otg_bus_data" in verdicts:
        print("  osmtgmod_results.bus_data is identical across the runs.")
        print("  That is what #769 asks for.")

    return 0 if all(verdicts.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
