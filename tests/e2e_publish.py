#!/usr/bin/env python3
"""Publish three dashboards the way GDASH-3 eventually will.

GDASH-2 implements only the READ side of design §7's `current` pointer, so the
end-to-end run has to write the pointer and the snapshot itself. That is
deliberate and named in the brief (§2.4): without a published dashboard the
scheduler has nothing to schedule and the phase's whole deliverable is
untestable. When GDASH-3 ships publish, this file is what it replaces.
"""
import json, os, sys

root = sys.argv[1]
base = json.load(open("dashboards/sales/draft.json"))


def publish(name, mutate):
    d = json.loads(json.dumps(base))
    d["name"] = name
    mutate(d)
    home = f"{root}/lib/dashboards/{name}"
    os.makedirs(f"{home}/snapshots", exist_ok=True)
    json.dump(d, open(f"{home}/snapshots/0001.json", "w"), indent=2)
    # The draft stays beside it, and must never be what a published dashboard
    # serves or refreshes.
    json.dump(d, open(f"{home}/draft.json", "w"), indent=2)
    open(f"{home}/current", "w").write("0001.json\n")


def single_dataset(d):
    """Drop `regions` and everything that reads it."""
    del d["datasets"]["regions"]
    for v in list(d["visuals"]):
        if "regions" in d["visuals"][v]["sql"]:
            del d["visuals"][v]
    d["tabs"] = [{"name": "Detail", "layout": {"vert": [{"visual": "detail"}]}}]


def timed(d):
    d["datasets"]["orders"]["refresh"] = "interval"
    d["datasets"]["orders"]["every"] = 1
    d["datasets"]["regions"]["refresh"] = "interval"
    d["datasets"]["regions"]["every"] = 3600


def opened(d):
    single_dataset(d)
    d["datasets"]["orders"]["refresh"] = "on_open"


def down(d):
    single_dataset(d)
    d["datasets"]["orders"]["refresh"] = "interval"
    d["datasets"]["orders"]["every"] = 1
    d["datasets"]["orders"]["profile"] = "flaky"


publish("timed", timed)
publish("opened", opened)
publish("down", down)
