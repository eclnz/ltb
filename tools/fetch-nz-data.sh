#!/usr/bin/env bash
# Download the data for one or more New Zealand bat regions.
#
#   tools/fetch-nz-data.sh                 list the regions
#   tools/fetch-nz-data.sh pureora         one region
#   tools/fetch-nz-data.sh all             all of them
#
# Each region gets, under data/nz/<region>/:
#
#   dem.tif        elevation, from AWS Terrain Tiles (LINZ 8 m DEM). No key.
#   aerial.tif     LINZ Basemaps aerial photography. Needs LINZ_API_KEY.
#   osm.geojson    roads, rivers, forest and built-up polygons from OpenStreetMap
#                  via Overpass. No key.
#   bats.geojson   confirmed bat records from GBIF, which aggregates the DOC Bat
#                  Distribution Database. No key.
#   lcdb.geojson   Land Cover Database v5. Needs LRIS_API_KEY.
#   tenure.geojson DOC public conservation areas. Needs LINZ_API_KEY.
#
# Free API keys. LINZ Basemaps and the LINZ Data Service issue SEPARATE keys and
# one will not authenticate the other, so aerial.tif and tenure.geojson may need
# different values in LINZ_API_KEY depending on which you are after:
#   LINZ_API_KEY   https://basemaps.linz.govt.nz/  for aerial.tif (tiles), or
#                  https://data.linz.govt.nz/      for tenure.geojson (WFS)
#   LRIS_API_KEY   https://lris.scinfo.org.nz/     Manaaki Whenua, LCDB and soils
#
# The Koordinates layer ids below (layer-104400 for LCDB v5, layer-754 for DOC
# public conservation areas) are the least certain thing in this script. If a
# WFS fetch comes back empty or 404s, check the id on the portal's page for the
# layer before assuming the key is wrong.
#
# Everything here is openly licensed: LINZ and DOC data CC BY 4.0, LCDB CC BY 4.0,
# OpenStreetMap ODbL, GBIF records under their own dataset licences. None of it is
# committed; the files are large and the sources are the authority.
set -euo pipefail
cd "$(dirname "$0")/.."

# name|latitude|longitude|half-span km|aerial zoom|why this place
REGIONS=(
  "eglinton|-44.98|168.02|12|15|Eglinton Valley, Fiordland. Red and silver beech flats on the Milford road, and the longest-running study of both species in the country."
  "pureora|-38.47|175.63|15|15|Pureora Forest Park. Tall podocarp forest hard against pine plantation and farmland, with both species present."
  "hamilton|-37.787|175.279|8|16|Hamilton and the Waikato River. One of the few cities anywhere with a resident long-tailed bat population, foraging along the river and the gullies."
  "hanmer|-42.523|172.828|8|15|Hanmer Forest, North Canterbury. Long-tailed bats roosting in exotic plantation, which is what makes harvest scheduling a bat question."
  "rangataua|-39.40|175.48|10|15|Rangataua Forest, southern Ruapehu. Old-growth podocarp holding one of the largest central lesser short-tailed bat populations."
)

usage() {
  echo "usage: $0 [all | region ...]"
  echo
  echo "regions:"
  for row in "${REGIONS[@]}"; do
    IFS='|' read -r name lat lon span zoom why <<<"$row"
    printf "  %-10s %8.3f %9.3f  %3s km   %s\n" "$name" "$lat" "$lon" "$span" "$why"
  done
  echo
  echo "keys: LINZ_API_KEY${LINZ_API_KEY:+ (set)} LRIS_API_KEY${LRIS_API_KEY:+ (set)}"
}

# Bounding box of a region, as west south east north.
bbox() {
  python3 - "$1" "$2" "$3" <<'PY'
import math, sys
lat, lon, span = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
dlat = span / 110.574
dlon = span / (111.320 * math.cos(math.radians(lat)))
print(f"{lon-dlon:.5f} {lat-dlat:.5f} {lon+dlon:.5f} {lat+dlat:.5f}")
PY
}

have() { [ -s "$1" ] && { echo "  have $(basename "$1")"; return 0; } || return 1; }

fetch_dem() {
  local dir=$1 lat=$2 lon=$3 span=$4
  have "$dir/dem.tif" && return 0
  tools/nz-tiles.py dem --lat "$lat" --lon "$lon" --span-km "$span" --out "$dir/dem.tif"
}

fetch_aerial() {
  local dir=$1 lat=$2 lon=$3 span=$4 zoom=$5
  have "$dir/aerial.tif" && return 0
  if [ -z "${LINZ_API_KEY:-}" ]; then
    echo "  skipping aerial.tif: set LINZ_API_KEY (free, basemaps.linz.govt.nz)"
    return 0
  fi
  # Imagery is the expensive one: a 15 km half-span at zoom 16 is around a
  # gigabyte. Pull a tighter box than the model region and let the rest of the
  # frame run on the DEM and land cover.
  local imagery_span
  imagery_span=$(python3 -c "print(min($span, 6))")
  tools/nz-tiles.py aerial --lat "$lat" --lon "$lon" --span-km "$imagery_span" \
    --zoom "$zoom" --out "$dir/aerial.tif"
}

fetch_osm() {
  local dir=$1 box=$2
  have "$dir/osm.geojson" && return 0
  read -r w s e n <<<"$box"
  echo "  fetching osm.geojson from Overpass"
  # Overpass wants south,west,north,east.
  local query="[out:json][timeout:180];
(
  way[\"highway\"]($s,$w,$n,$e);
  way[\"waterway\"~\"river|stream|canal\"]($s,$w,$n,$e);
  way[\"natural\"=\"water\"]($s,$w,$n,$e);
  way[\"landuse\"~\"forest|residential|industrial|farmland|meadow|orchard\"]($s,$w,$n,$e);
  way[\"natural\"~\"wood|scrub|wetland\"]($s,$w,$n,$e);
  way[\"building\"]($s,$w,$n,$e);
);
out geom;"
  curl -fsSL --retry 3 --data-urlencode "data=$query" \
    -o "$dir/osm.json" https://overpass-api.de/api/interpreter
  tools/osm-to-geojson.py "$dir/osm.json" "$dir/osm.geojson"
  rm -f "$dir/osm.json"
}

fetch_bats() {
  local dir=$1 box=$2
  have "$dir/bats.geojson" && return 0
  read -r w s e n <<<"$box"
  tools/nz-bat-records.py --bbox "$w" "$s" "$e" "$n" --out "$dir/bats.geojson"
}

# Koordinates WFS, which is what both LINZ and Manaaki Whenua serve their
# vectors through. Override a `layer-NNNNN` id from the environment when a
# portal renumbers one: LCDB_LAYER and DOC_LAYER.
fetch_wfs() {
  local out=$1 host=$2 key=$3 layer=$4 box=$5 label=$6
  have "$out" && return 0
  if [ -z "$key" ]; then
    echo "  skipping $(basename "$out"): no API key for $label"
    return 0
  fi
  read -r w s e n <<<"$box"
  echo "  fetching $(basename "$out") ($label $layer)"
  curl -fsSL --retry 3 -o "$out" \
    "https://${host}/services;key=${key}/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=${layer}&outputFormat=application/json&SRSName=EPSG:4326&bbox=${s},${w},${n},${e},urn:ogc:def:crs:EPSG::4326" \
    || echo "  $label $layer failed; check the key and that the layer is still published"
}

fetch_region() {
  local row=$1
  IFS='|' read -r name lat lon span zoom why <<<"$row"
  local dir="data/nz/$name"
  mkdir -p "$dir"
  echo
  echo "== $name =================================================="
  echo "$why"
  local box
  box=$(bbox "$lat" "$lon" "$span")
  echo "bbox $box"

  fetch_dem "$dir" "$lat" "$lon" "$span"
  fetch_aerial "$dir" "$lat" "$lon" "$span" "$zoom"
  fetch_osm "$dir" "$box"
  fetch_bats "$dir" "$box"
  # LCDB v5, Manaaki Whenua's land cover, on the LRIS portal.
  fetch_wfs "$dir/lcdb.geojson" "lris.scinfo.org.nz" "${LRIS_API_KEY:-}" "${LCDB_LAYER:-layer-104400}" "$box" "LRIS"
  # DOC public conservation areas, published through LINZ.
  fetch_wfs "$dir/tenure.geojson" "data.linz.govt.nz" "${LINZ_API_KEY:-}" "${DOC_LAYER:-layer-754}" "$box" "LINZ"

  echo
  echo "render it with:"
  echo "  ./build/ltb-view --manifest data/nz/$name.json"
}

main() {
  if [ $# -eq 0 ]; then
    usage
    exit 0
  fi
  local wanted=("$@")
  if [ "${1:-}" = "all" ]; then
    for row in "${REGIONS[@]}"; do fetch_region "$row"; done
    return
  fi
  for want in "${wanted[@]}"; do
    local found=""
    for row in "${REGIONS[@]}"; do
      IFS='|' read -r name _ <<<"$row"
      if [ "$name" = "$want" ]; then
        fetch_region "$row"
        found=1
      fi
    done
    if [ -z "$found" ]; then
      echo "no region named $want" >&2
      usage >&2
      exit 2
    fi
  done
}

main "$@"
