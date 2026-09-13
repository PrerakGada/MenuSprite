#!/usr/bin/env python3
"""Reconcile a native --work-validate export with its SQLite backup, without writes."""
import csv
import json
import math
import pathlib
import sqlite3
import sys

directory = pathlib.Path(sys.argv[1]).resolve()
connection = sqlite3.connect((directory / "paneclock.snapshot.db").as_uri() + "?mode=ro", uri=True)
expected = {
    (project or "Unresolved project", client or ""): seconds
    for project, client, seconds in connection.execute(
        "SELECT project,client,SUM(active_seconds) FROM intervals GROUP BY project,client"
    ) if seconds > 0
}
with (directory / "real-summary.csv").open(newline="") as file:
    summary = list(csv.DictReader(file))
assert len(summary) == len(expected), "Project count differs"
for row in summary:
    seconds = expected[(row["Project"], row["Client"])]
    assert math.isclose(float(row["Active hours"]) * 3600, seconds, abs_tol=0.00001), row["Project"]
with (directory / "real-intervals.csv").open(newline="") as file:
    entries = list(csv.DictReader(file))
assert len(entries) == connection.execute("SELECT COUNT(*) FROM intervals WHERE active_seconds>0").fetchone()[0]
csv_seconds = sum(float(row["Active seconds"]) for row in entries)
source_seconds = sum(expected.values())
assert math.isclose(csv_seconds, source_seconds, abs_tol=0.001), "Interval sum differs"
result = {
    "projectRows": len(summary), "nonzeroIntervals": len(entries),
    "sourceIntervals": connection.execute("SELECT COUNT(*) FROM intervals").fetchone()[0],
    "sourceSeconds": source_seconds, "csvSeconds": csv_seconds, "allProjectTotalsMatch": True,
}
connection.close()
(directory / "csv-reconciliation.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
