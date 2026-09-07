#!/usr/bin/env python3
"""
Convert an Overpass API response into the flat GeoJSON the engine ingests.

Overpass `out geom` is nearly GeoJSON but not quite: geometry is a list of
lat/lon objects rather than coordinate pairs, and tags sit under their own key.
The engine's manifests classify and filter on flat properties -- "highway",
"landuse", "natural" -- so tags are lifted to the top level here.

    tools/osm-to-geojson.py raw.json out.geojson

A closed way carrying an area tag becomes a Polygon; anything else closed or not
becomes a LineString. That distinction matters downstream: a polygon can be
measured for coverage, a line only for presence and density.
"""

import json
import sys

# Waterway values that enclose water rather than trace a channel.
AREA_WATERWAY = ("riverbank", "dock")


def is_area(tags, ring_closed):
    if not ring_closed:
        return False
    if tags.get("area") == "yes":
        return True
    if "building" in tags or "landuse" in tags or "leisure" in tags:
        return True
    if tags.get("natural") in ("water", "wood", "scrub", "wetland", "sand", "bare_rock"):
        return True
    if tags.get("waterway") in AREA_WATERWAY:
        return True
    return False


def convert(raw):
    features = []
    for el in raw.get("elements", []):
        tags = el.get("tags") or {}
        if not tags:
            continue
        kind = el.get("type")
        if kind == "node":
            if el.get("lat") is None:
                continue
            geom = {"type": "Point", "coordinates": [el["lon"], el["lat"]]}
        elif kind == "way":
            pts = el.get("geometry") or []
            coords = [[p["lon"], p["lat"]] for p in pts if p.get("lon") is not None]
            if len(coords) < 2:
                continue
            closed = len(coords) > 3 and coords[0] == coords[-1]
            if is_area(tags, closed):
                geom = {"type": "Polygon", "coordinates": [coords]}
            else:
                geom = {"type": "LineString", "coordinates": coords}
        else:
            continue  # relations need member resolution; the ways carry enough
        features.append({"type": "Feature", "properties": dict(tags), "geometry": geom})
    return {"type": "FeatureCollection", "features": features}


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(argv[1]) as f:
        raw = json.load(f)
    out = convert(raw)
    with open(argv[2], "w") as f:
        json.dump(out, f)
    kinds = {}
    for feat in out["features"]:
        kinds[feat["geometry"]["type"]] = kinds.get(feat["geometry"]["type"], 0) + 1
    summary = ", ".join(f"{n} {k}" for k, n in sorted(kinds.items()))
    print(f"wrote {argv[2]}: {len(out['features'])} features ({summary or 'none'})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
