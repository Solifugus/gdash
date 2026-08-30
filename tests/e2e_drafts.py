#!/usr/bin/env python3
"""Write three dashboard drafts for the end-to-end run.

Authoring is file editing (design §10), so writing a draft is what an author
does and this file does only that. Publishing them is `gdash publish`, run by
the e2e script itself -- GDASH-3 replaced the hand-written `current` pointer
this file used to produce, and there is deliberately no second way to publish.
"""
import json, os, sys

root = sys.argv[1]
base = json.load(open("dashboards/sales/draft.json"))


def draft(name, mutate):
    d = json.loads(json.dumps(base))
    d["name"] = name
    mutate(d)
    home = f"{root}/lib/dashboards/{name}"
    os.makedirs(home, exist_ok=True)
    json.dump(d, open(f"{home}/draft.json", "w"), indent=2)


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


draft("timed", timed)
draft("opened", opened)
draft("down", down)
