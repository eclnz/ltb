#!/usr/bin/env python3
"""
Pull confirmed New Zealand bat occurrence records and write them as GeoJSON.

Both surviving species are queried by name from GBIF, which aggregates the DOC
Bat Distribution Database, Te Papa and AUT collections, and iNaturalist NZ:

    Chalinolobus tuberculatus   long-tailed bat, pekapeka-tou-roa
    Mystacina tuberculata       lesser short-tailed bat, pekapeka-tou-poto

    tools/nz-bat-records.py --bbox 175.4 -38.7 175.9 -38.2 \
        --out data/nz/pureora-bats.geojson

Each feature carries `species` (the codes in NZ_BAT_SPECIES: 1 long-tailed,
2 short-tailed), `year`, `count` and `basis`, so a manifest can drive
bat.species_present, bat.last_detected_year and bat.records straight off it.

Records are observations, not a survey design. A cell with no record is a cell
nobody has listened in, not a cell without bats -- which is why the manifests
ingest them alongside bat.survey_effort rather than instead of it.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.gbif.org/v1/occurrence/search"

SPECIES = {
    "Chalinolobus tuberculatus": 1,  # long-tailed bat
    "Mystacina tuberculata": 2,  # lesser short-tailed bat
}

PAGE = 300  # GBIF's maximum page size


def fetch_page(name, bbox, offset, attempts=4):
    params = {
        "scientificName": name,
        "country": "NZ",
        "hasCoordinate": "true",
        "hasGeospatialIssue": "false",
        "limit": PAGE,
        "offset": offset,
    }
    if bbox:
        west, south, east, north = bbox
        # GBIF wants a WKT polygon wound counter-clockwise.
        params["geometry"] = (
            f"POLYGON(({west} {south},{east} {south},{east} {north},"
            f"{west} {north},{west} {south}))"
        )
    url = API + "?" + urllib.parse.urlencode(params)
    last = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "ltb-nz-bat-records/1.0"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001 - any transport failure is retryable
            last = e
            time.sleep(2 ** attempt)
    raise SystemExit(f"could not reach GBIF: {last}")


def collect(name, code, bbox, limit):
    features = []
    offset = 0
    while offset < limit:
        page = fetch_page(name, bbox, offset)
        results = page.get("results", [])
        for rec in results:
            lat, lon = rec.get("decimalLatitude"), rec.get("decimalLongitude")
            if lat is None or lon is None:
                continue
            features.append(
                {
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [lon, lat]},
                    "properties": {
                        "species": code,
                        "name": name,
                        "year": rec.get("year") or 0,
                        "count": rec.get("individualCount") or 1,
                        "basis": rec.get("basisOfRecord", ""),
                        "dataset": rec.get("datasetName", ""),
                        "uncertainty_m": rec.get("coordinateUncertaintyInMeters") or 0,
                    },
                }
            )
        if page.get("endOfRecords", True) or not results:
            break
        offset += PAGE
    return features


def main():
    p = argparse.ArgumentParser(
        description="Fetch New Zealand bat occurrence records as GeoJSON.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--bbox",
        nargs=4,
        type=float,
        metavar=("WEST", "SOUTH", "EAST", "NORTH"),
        default=None,
        help="restrict to a bounding box; omit for the whole country",
    )
    p.add_argument("--limit", type=int, default=6000, help="maximum records per species")
    p.add_argument("--out", required=True, help="GeoJSON file to write")
    args = p.parse_args()

    features = []
    for name, code in SPECIES.items():
        got = collect(name, code, args.bbox, args.limit)
        print(f"{name}: {len(got)} records")
        features.extend(got)

    if not features:
        print("no records in that area -- which for bats is common and not an error")

    with open(args.out, "w") as f:
        json.dump({"type": "FeatureCollection", "features": features}, f)
    print(f"wrote {args.out} ({len(features)} features)")


if __name__ == "__main__":
    sys.exit(main())
