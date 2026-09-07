#!/usr/bin/env bash
# Download the public-domain datasets the sample manifests use.
#
#   data/ne/n43.tif      real SRTM elevation for N43 W080, int16, LZW GeoTIFF
#   data/ne/ne_10m_*     Natural Earth 1:10m vectors: land, lakes, rivers,
#                        urban areas, roads, populated places
#
# About 120 MB. Not committed, because it is redistributable but large.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p data/ne
cd data/ne

NE=https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson
for f in ne_10m_land ne_10m_lakes ne_10m_rivers_lake_centerlines \
         ne_10m_urban_areas ne_10m_roads ne_10m_populated_places; do
  if [ -f "$f.geojson" ]; then
    echo "have $f.geojson"
  else
    echo "fetching $f.geojson"
    curl -fsSL --retry 3 -o "$f.geojson" "$NE/$f.geojson"
  fi
done

if [ -f n43.tif ]; then
  echo "have n43.tif"
else
  echo "fetching n43.tif"
  curl -fsSL --retry 3 -o n43.tif \
    "https://raw.githubusercontent.com/OSGeo/gdal/master/autotest/gdrivers/data/n43.tif"
fi

echo
echo "ready. render the region with:"
echo "  ./build/ltb-view --no-generate --lat 43.5 --lon -79.5 --span 55 \\"
echo "      --cell-area 250000 --levels 7 --manifest data/ne/ontario.json"

mkdir -p ../imagery
cd ../imagery
NAIP=https://raw.githubusercontent.com/opengeos/data/main/naip
for f in buildings campus; do
  if [ -f "$f.tif" ]; then
    echo "have $f.tif"
  else
    echo "fetching $f.tif"
    curl -fsSL --retry 3 -o "$f.tif" "$NAIP/$f.tif"
  fi
done

echo
echo "close-up 0.5 m imagery, real 1 m NAIP aerial photography (Miami, FL):"
echo "  ./build/ltb-view --no-generate --lat 25.7916 --lon -80.3638 --span 1.3 \\"
echo "      --cell-area 0.2165 --levels 12 --manifest data/imagery/buildings.json"
