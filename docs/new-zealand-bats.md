# New Zealand bat regions

This build is specialised to the places in New Zealand that still have bats, and
to the data that decides whether they keep them. `ltb` is the long-tailed bat.

Two species survive:

| | long-tailed bat | lesser short-tailed bat |
|---|---|---|
| | *Chalinolobus tuberculatus*, pekapeka-tou-roa | *Mystacina tuberculata*, pekapeka-tou-poto |
| forages | fast, in the open air along **edges** — forest margins, river channels, shelter belts, treelined roads | in the air and **on the forest floor**, inside large unbroken tracts |
| roosts | cavities in big old trees, indigenous or exotic, switching almost daily | cavities in very large old indigenous emergents |
| tolerates | farmland, plantation, even a city, given old trees and dark linear structure | almost no fragmentation at all |
| killed by | ship rats and stoats off the roost; roost trees felled | the same, worse, because it spends time on the ground |

Everything below follows from that split. The two species want opposite things
from a landscape, so the model produces two answers, not one.

## Regions

Five regions ship as manifests in `data/nz/`. Each is a real population with a
real management question attached.

| region | centre | what it is |
|---|---|---|
| `eglinton` | -44.980, 168.020 | Eglinton Valley, Fiordland. Beech flats on the Milford road; both species; the country's longest-running bat study. Nearly all conservation land, so predation is the whole story. |
| `pureora` | -38.470, 175.630 | Pureora Forest Park. Tall podocarp against pine plantation and dairy. The reserve boundary is the interesting line: long-tailed bats cross it, short-tailed bats do not. |
| `hamilton` | -37.787, 175.279 | Hamilton and the Waikato River. A city with resident long-tailed bats. Lighting, cats and tree removal dominate, not rats. |
| `hanmer` | -42.523, 172.828 | Hanmer Forest. Bats roosting in a working plantation, where the harvest schedule decides whether the roosts survive. |
| `rangataua` | -39.400, 175.480 | Rangataua Forest, southern Ruapehu. Old-growth podocarp holding a large central short-tailed bat population. |

Adding a region is a row in `REGIONS` in `tools/fetch-nz-data.sh` and a manifest
beside the others; nothing in the engine knows the list.

## Getting the data

```sh
tools/fetch-nz-data.sh                # list the regions
tools/fetch-nz-data.sh pureora        # fetch one
tools/fetch-nz-data.sh all            # fetch all five
```

| file | source | key | licence |
|---|---|---|---|
| `dem.tif` | AWS Terrain Tiles, which over New Zealand carry the LINZ 8 m DEM | none | CC BY 4.0 |
| `aerial.tif` | LINZ Basemaps aerial photography, 0.05–0.5 m | `LINZ_API_KEY` (Basemaps) | CC BY 4.0 |
| `osm.geojson` | OpenStreetMap via Overpass: roads, waterways, forest, buildings | none | ODbL |
| `bats.geojson` | GBIF, which aggregates the DOC Bat Distribution Database, Te Papa, iNaturalist NZ | none | per dataset |
| `lcdb.geojson` | Land Cover Database v5, Manaaki Whenua, on the LRIS portal | `LRIS_API_KEY` | CC BY 4.0 |
| `tenure.geojson` | DOC public conservation areas, via LINZ | `LINZ_API_KEY` (Data Service) | CC BY 4.0 |

The keys are free, and there are three of them, not two: **LINZ Basemaps and the
LINZ Data Service issue separate keys and neither authenticates the other**, so
`LINZ_API_KEY` serves whichever of imagery or tenure you set it for. Get them
from [basemaps.linz.govt.nz](https://basemaps.linz.govt.nz/),
[data.linz.govt.nz](https://data.linz.govt.nz/) and
[lris.scinfo.org.nz](https://lris.scinfo.org.nz/).

Without any of them you still get elevation, OpenStreetMap and the bat records,
which is enough to run the model — canopy cover then comes from OSM forest
polygons instead of LCDB, and the structural priors below are not written.

The Koordinates layer ids the script uses (`layer-104400` for LCDB v5,
`layer-754` for DOC public conservation areas) are the least certain part of it.
Override them with `LCDB_LAYER` and `DOC_LAYER` if a portal has renumbered one.

Nothing fetched is committed; `data/nz/*/` is ignored. The manifests are.

### Tile fetching

`tools/nz-tiles.py` turns web map tiles into one GeoTIFF, because the engine
reads GeoTIFF and every New Zealand imagery service publishes tiles. It works in
EPSG:3857, which is the projection the tiles were cut in, so nothing is resampled
before `ltb` resamples it onto hexes.

```sh
tools/nz-tiles.py aerial --lat -38.45 --lon 175.65 --span-km 6 --zoom 16 \
    --out data/nz/pureora/aerial.tif
tools/nz-tiles.py dem --lat -38.45 --lon 175.65 --span-km 25 --out data/nz/pureora/dem.tif
```

It uses the standard library only: PNG is inflated and unfiltered in the script,
and the GeoTIFF it writes is the dullest layout in the format — one strip,
uncompressed, chunky interleave. Imagery is the expensive part; a 6 km half-span
at zoom 16 is about 400 tiles and a few hundred megabytes, and there is no point
pulling more pixels than you have cells.

## Running a region

```sh
./build.sh
./build/ltb-view --manifest data/nz/pureora.json
```

No coordinates on the command line: each manifest carries a `"region"` block
with its centre, span, cell size and opening layer, so opening one places the
world. They also appear in the viewer's File menu by title.

The cell size is 100 m across for the forest regions and 60 m for Hamilton,
which is roughly the scale a bat makes decisions at: a hundred metres is the
difference between a forest edge and a forest interior. Press `[` and `]` to
walk the layers; the ones to look at are `bat.habitat_suitability`,
`bat.habitat_suitability_short_tailed`, `bat.commuting_value` and
`forest.edge_density`.

Nothing is invented. Every cell comes from a file, and the bat model is a
derivation the manifest asks for by name — `"derive": [..., "bat_habitat"]` —
not something that runs behind your back. It writes only where its own inputs
are present, so a layer with no data still reads as no data.

## Layers

The New Zealand catalogue is in `src/layers/nz.odin`, registered alongside the
standard one, so `--list-layers` shows everything.

**Vocabularies** are the ones the national datasets use, not translations of
them: LCDB v5 class codes, NES-PF erosion susceptibility classes, tracking tunnel
indices and residual trap catch, DOC tenure classes, and eleven New Zealand tree
groups (podocarp, beech, broadleaved hardwood, kauri, mānuka/kānuka, tree fern,
nīkau, radiata, Douglas-fir, eucalypt, riparian exotics) replacing the generic
functional types for `forest.composition_nz`.

**Groups added**: `bats` (activity, records, roosts, and the modelled surfaces),
`predators` (rat, stoat and possum indices, control regime, mast risk),
`forestry` (crop species, silviculture, rotation, erosion class, riparian
setbacks, retained habitat), and New Zealand additions to `vegetation`,
`imagery` and `human` — including `forest.emergent_height`,
`forest.cavity_tree_density`, `forest.edge_density` and `human.night_light`.

## The model

`src/ingest/derive_bat.odin`, run by the `bat_habitat` derivation. Three passes,
because the answer is not local: a bat roosts in one cell and feeds in another.

1. **Edge density** from the contrast in canopy cover across each of a cell's six
   shared sides. A closed-canopy cell ringed by pasture scores the maximum; a
   cell inside continuous forest scores nothing. The habitat model normalises
   against the maximum the layout can produce, so the response does not change
   when you change the cell size, even though metres per hectare does.
2. **Per-cell terms**: prey, roost, foraging, commuting, predation, disturbance.
   Roost quality is cavity-bearing stems per hectare against a reference of six,
   because roost switching every day or two means a colony needs many options,
   not one good tree. Foraging is a *hump* in edge fraction rather than a ramp —
   solid forest and bare paddock are both poor and the mosaic between them is
   where this bat feeds.
3. **Combined indices**, geometric rather than additive: a cell with roosts and
   no food is no more use than a cell with food and nowhere to sleep. A roost one
   cell away still counts, at a discount. Both indices are then discounted for
   predation and for the chance the roost habitat is gone within a planning
   horizon, which tenure mostly decides.

Predation carries the New Zealand mechanism explicitly: a beech mast feeds a
rodent irruption, the stoats follow a season later, and that is what is behind
most recorded colony collapses. Control regimes remove a share of the risk and,
except behind a fence, decay over about three years as rats come back.

Nothing is mandatory. Whatever a region's manifest managed to ingest is used and
the rest is estimated from what is there — and an estimate is written back only
where nothing was ingested, so a real survey is never overwritten by a guess.

The structural tables in `src/ingest/nz_tables.odin` that map LCDB classes onto
canopy cover, height, emergent height and stand age are **priors, not
measurements**. A polygon labelled "Indigenous Forest" is somewhere between a
stunted subalpine stand and forty-metre rimu. They exist so the model has
something defensible to run on before anyone has flown lidar; ingest a real
canopy height model and it takes precedence.

Occurrence records are observations, not a survey design. A cell with no record
is a cell nobody has listened in, which is why the manifests carry
`bat.survey_effort` alongside `bat.records`.
