#!/usr/bin/env python3
"""
Build a GeoTIFF for a New Zealand region out of web map tiles.

The engine reads GeoTIFF. Almost every New Zealand imagery source publishes web
map tiles. This bridges the two: it works out which tiles cover a region, pulls
them, stitches them, and writes one uncompressed GeoTIFF in EPSG:3857 -- which
is exactly the projection the tiles were cut in, so no resampling happens here
and none of the detail is lost before ltb resamples onto its own hex grid.

    tools/nz-tiles.py aerial --lat -38.45 --lon 175.65 --span-km 6 \
        --zoom 16 --out data/nz/pureora-aerial.tif

    tools/nz-tiles.py dem --lat -38.45 --lon 175.65 --span-km 25 \
        --zoom 12 --out data/nz/pureora-dem.tif

Sources
  aerial   LINZ Basemaps aerial photography, 0.05-0.5 m over most of the
           country. Needs a free API key from basemaps.linz.govt.nz; put it in
           LINZ_API_KEY or pass --api-key. Crown copyright, CC BY 4.0.
  dem      AWS Terrain Tiles, which over New Zealand are the LINZ 8 m DEM
           reprojected. No key needed.

Only the standard library is used, so this runs on a bare Python: PNG is
inflated and unfiltered here, and the GeoTIFF writer emits the plain
strip-per-image layout the engine's reader takes.
"""

import argparse
import math
import os
import struct
import sys
import time
import urllib.error
import urllib.request
import zlib

# Half the circumference of the Web Mercator square, in metres.
R = 20037508.342789244

SOURCES = {
    "aerial": {
        "url": "https://basemaps.linz.govt.nz/v1/tiles/aerial/EPSG:3857/{z}/{x}/{y}.png?api={key}",
        "format": "png",
        "tile_px": 256,
        "bands": 3,
        "dtype": "u1",
        "needs_key": True,
        "zoom": 16,  # about 1 m/px at New Zealand latitudes
        "nodata": None,
        "credit": "Imagery (c) LINZ, CC BY 4.0",
    },
    "topo": {
        "url": "https://basemaps.linz.govt.nz/v1/tiles/topographic/EPSG:3857/{z}/{x}/{y}.png?api={key}",
        "format": "png",
        "tile_px": 256,
        "bands": 3,
        "dtype": "u1",
        "needs_key": True,
        "zoom": 14,
        "nodata": None,
        "credit": "Topographic map (c) LINZ, CC BY 4.0",
    },
    "dem": {
        "url": "https://s3.amazonaws.com/elevation-tiles-prod/geotiff/{z}/{x}/{y}.tif",
        "format": "tif",
        "tile_px": 512,
        "bands": 1,
        "dtype": "i2",
        "needs_key": False,
        "zoom": 12,  # about 9 m/px at 38 S, the native LINZ 8 m DEM resolution
        "nodata": -32768,
        "credit": "Elevation from AWS Terrain Tiles, LINZ 8 m DEM under CC BY 4.0",
    },
}

DTYPE_BYTES = {"u1": 1, "i2": 2}


# ---------------------------------------------------------------------------
# Web Mercator tile arithmetic
# ---------------------------------------------------------------------------


def lonlat_to_tile(lon, lat, z):
    """Fractional tile coordinates of a position."""
    n = 2.0 ** z
    x = (lon + 180.0) / 360.0 * n
    lat = max(-85.05112878, min(85.05112878, lat))
    s = math.sin(math.radians(lat))
    y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * n
    return x, y


def tile_span_m(z):
    """Ground width of one tile, in metres."""
    return 2.0 * R / (2.0 ** z)


def tile_origin_m(z, x, y):
    """North-west corner of a tile in EPSG:3857 metres."""
    s = tile_span_m(z)
    return -R + x * s, R - y * s


def tiles_for_region(lat, lon, span_km, z):
    """Inclusive tile index range covering a square centred on lat/lon."""
    # A degree of latitude is 110.574 km; longitude shrinks with the cosine.
    dlat = span_km / 110.574
    dlon = span_km / (111.320 * max(0.2, math.cos(math.radians(lat))))
    x0, y0 = lonlat_to_tile(lon - dlon, lat + dlat, z)  # north-west
    x1, y1 = lonlat_to_tile(lon + dlon, lat - dlat, z)  # south-east
    return int(math.floor(x0)), int(math.floor(y0)), int(math.floor(x1)), int(math.floor(y1))


# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------


def fetch(url, attempts=4, timeout=60):
    """GET with a few retries. Returns None for a 404, which tiles legitimately are."""
    last = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "ltb-nz-tiles/1.0"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (403, 404):
                return None
            last = e
        except Exception as e:  # noqa: BLE001 - any transport failure is retryable
            last = e
        time.sleep(2 ** attempt)
    raise SystemExit(f"could not fetch {url}: {last}")


# ---------------------------------------------------------------------------
# PNG
# ---------------------------------------------------------------------------


def decode_png(data):
    """Decode an 8-bit non-interlaced PNG to (width, height, RGB bytes)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    idat = []
    palette = None
    width = height = depth = color = 0
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        tag = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        pos += 12 + length  # 4 length, 4 tag, length body, 4 crc
        if tag == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or interlace != 0:
                raise ValueError(f"unsupported PNG: depth {depth}, interlace {interlace}")
        elif tag == b"PLTE":
            palette = body
        elif tag == b"IDAT":
            idat.append(body)
        elif tag == b"IEND":
            break
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    raw = zlib.decompress(b"".join(idat))
    stride = width * channels
    out = bytearray(width * height * channels)
    prev = bytearray(stride)
    src = 0
    for row in range(height):
        ftype = raw[src]
        src += 1
        line = bytearray(raw[src : src + stride])
        src += stride
        unfilter_row(ftype, line, prev, channels)
        out[row * stride : (row + 1) * stride] = line
        prev = line
    return width, height, to_rgb(out, width * height, color, channels, palette)


def unfilter_row(ftype, line, prev, bpp):
    """Undo one PNG scanline filter in place."""
    if ftype == 0:
        return
    n = len(line)
    if ftype == 1:  # Sub
        for i in range(bpp, n):
            line[i] = (line[i] + line[i - bpp]) & 0xFF
    elif ftype == 2:  # Up
        for i in range(n):
            line[i] = (line[i] + prev[i]) & 0xFF
    elif ftype == 3:  # Average
        for i in range(n):
            left = line[i - bpp] if i >= bpp else 0
            line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
    elif ftype == 4:  # Paeth
        for i in range(n):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = (line[i] + pred) & 0xFF
    else:
        raise ValueError(f"unknown PNG filter {ftype}")


def to_rgb(buf, pixels, color, channels, palette):
    """Flatten any of the 8-bit PNG colour types to packed RGB."""
    if color == 2:
        return bytes(buf)
    out = bytearray(pixels * 3)
    if color == 3:
        if palette is None:
            raise ValueError("indexed PNG with no palette")
        for i in range(pixels):
            j = buf[i] * 3
            out[i * 3 : i * 3 + 3] = palette[j : j + 3]
    elif color in (0, 4):
        for i in range(pixels):
            g = buf[i * channels]
            out[i * 3] = out[i * 3 + 1] = out[i * 3 + 2] = g
    elif color == 6:
        for i in range(pixels):
            out[i * 3 : i * 3 + 3] = buf[i * 4 : i * 4 + 3]
    return bytes(out)


# ---------------------------------------------------------------------------
# TIFF, enough of it to read a terrain tile
# ---------------------------------------------------------------------------


def decode_tiff(data):
    """
    Decode a single-band 16-bit GeoTIFF tile to (width, height, samples, origin, pixel_size).

    Handles the layout the terrain tiles actually use: little-endian, tiled,
    Deflate with horizontal differencing. Samples come back as a list of ints.
    """
    if data[:2] == b"II":
        en = "<"
    elif data[:2] == b"MM":
        en = ">"
    else:
        raise ValueError("not a TIFF")
    (ifd,) = struct.unpack(en + "I", data[4:8])
    (count,) = struct.unpack(en + "H", data[ifd : ifd + 2])

    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 11: 4, 12: 8}
    codes = {1: "B", 2: "B", 3: "H", 4: "I", 6: "b", 8: "h", 9: "i", 11: "f", 12: "d"}
    tags = {}
    for i in range(count):
        e = ifd + 2 + i * 12
        tag, typ, n = struct.unpack(en + "HHI", data[e : e + 8])
        total = sizes.get(typ, 1) * n
        if total <= 4:
            payload = data[e + 8 : e + 8 + total]
        else:
            (off,) = struct.unpack(en + "I", data[e + 8 : e + 12])
            payload = data[off : off + total]
        if typ in codes:
            tags[tag] = struct.unpack(en + str(n) + codes[typ], payload)
        else:
            tags[tag] = payload

    def one(tag, default=None):
        v = tags.get(tag)
        return default if v is None else v[0]

    width, height = one(256), one(257)
    bits = one(258, 8)
    compression = one(259, 1)
    predictor = one(317, 1)
    fmt = one(339, 1)
    if one(277, 1) != 1:
        raise ValueError("expected a single-band tile")
    if bits != 16:
        raise ValueError(f"expected 16-bit samples, got {bits}")

    if 322 in tags:
        bw, bh = one(322), one(323)
        offsets, counts = tags[324], tags[325]
    else:
        bw, bh = width, one(278, height)
        offsets, counts = tags[273], tags[279]

    code = "h" if fmt == 2 else "H"
    samples = [0] * (width * height)
    across = (width + bw - 1) // bw
    for index, (off, cnt) in enumerate(zip(offsets, counts)):
        block = data[off : off + cnt]
        if compression in (8, 32946):
            block = zlib.decompress(block)
        elif compression != 1:
            raise ValueError(f"unsupported compression {compression}")
        tx, ty = index % across, index // across
        row_bytes = bw * 2
        for row in range(bh):
            y = ty * bh + row
            if y >= height:
                break
            line = bytearray(block[row * row_bytes : (row + 1) * row_bytes])
            if len(line) < row_bytes:
                break
            if predictor == 2:
                undo_predictor16(line, en)
            vals = struct.unpack(en + str(bw) + code, bytes(line))
            for col in range(min(bw, width - tx * bw)):
                samples[y * width + tx * bw + col] = vals[col]

    scale = tags.get(33550)
    tie = tags.get(33922)
    if not scale or not tie:
        raise ValueError("tile has no georeferencing")
    origin = (tie[3], tie[4])
    return width, height, samples, origin, scale[0]


def undo_predictor16(line, en):
    """Horizontal differencing over 16-bit samples, in place."""
    n = len(line) // 2
    vals = list(struct.unpack(en + str(n) + "H", bytes(line)))
    for i in range(1, n):
        vals[i] = (vals[i] + vals[i - 1]) & 0xFFFF
    line[:] = struct.pack(en + str(n) + "H", *vals)


# ---------------------------------------------------------------------------
# GeoTIFF writing
# ---------------------------------------------------------------------------


def write_geotiff(path, width, height, bands, dtype, data, origin_x, origin_y, pixel_size, nodata=None):
    """
    Write one uncompressed strip-per-image GeoTIFF in EPSG:3857.

    Deliberately the dullest layout in the format: one strip, chunky pixel
    interleave, little-endian. It is bigger on disk than a compressed tile and
    every reader in the world takes it without argument.
    """
    esz = DTYPE_BYTES[dtype]
    sample_format = 2 if dtype.startswith("i") else 1
    photometric = 2 if bands == 3 else 1

    geo_keys = [1, 1, 0, 3, 1024, 0, 1, 1, 1025, 0, 1, 1, 3072, 0, 1, 3857]
    extra = bytearray()

    def stash(payload):
        """Append an out-of-line value, returning its offset placeholder index."""
        off = len(extra)
        extra.extend(payload)
        if len(extra) % 2:  # TIFF values start on a word boundary
            extra.append(0)
        return off

    entries = []  # (tag, type, count, inline_bytes or ('extra', offset))

    def add(tag, typ, values, packer):
        payload = struct.pack("<" + str(len(values)) + packer, *values)
        if len(payload) <= 4:
            entries.append((tag, typ, len(values), payload.ljust(4, b"\x00")))
        else:
            entries.append((tag, typ, len(values), ("extra", stash(payload))))

    add(256, 4, [width], "I")
    add(257, 4, [height], "I")
    add(258, 3, [esz * 8] * bands, "H")
    add(259, 3, [1], "H")  # no compression
    add(262, 3, [photometric], "H")
    entries.append((273, 4, 1, ("data", 0)))  # StripOffsets, patched below
    add(277, 3, [bands], "H")
    add(278, 4, [height], "I")  # one strip for the whole image
    add(279, 4, [width * height * bands * esz], "I")
    add(284, 3, [1], "H")  # chunky
    add(339, 3, [sample_format] * bands, "H")
    add(33550, 12, [pixel_size, pixel_size, 0.0], "d")
    add(33922, 12, [0.0, 0.0, 0.0, origin_x, origin_y, 0.0], "d")
    add(34735, 3, geo_keys, "H")
    if nodata is not None:
        text = (str(nodata) + "\x00").encode("ascii")
        entries.append((42113, 2, len(text), ("extra", stash(text))))

    entries.sort(key=lambda e: e[0])

    ifd_offset = 8
    ifd_size = 2 + 12 * len(entries) + 4
    extra_offset = ifd_offset + ifd_size
    data_offset = extra_offset + len(extra)

    out = bytearray()
    out.extend(struct.pack("<2sHI", b"II", 42, ifd_offset))
    out.extend(struct.pack("<H", len(entries)))
    for tag, typ, count, value in entries:
        if isinstance(value, tuple):
            where, off = value
            base = data_offset if where == "data" else extra_offset
            value = struct.pack("<I", base + off)
        out.extend(struct.pack("<HHI", tag, typ, count) + value)
    out.extend(struct.pack("<I", 0))  # no next IFD
    out.extend(extra)
    out.extend(data)

    with open(path, "wb") as f:
        f.write(bytes(out))
    return len(out)


# ---------------------------------------------------------------------------
# Mosaicking
# ---------------------------------------------------------------------------


def build(source, name, lat, lon, span_km, zoom, out_path, api_key):
    tile_px = source["tile_px"]
    bands = source["bands"]
    dtype = source["dtype"]
    esz = DTYPE_BYTES[dtype]

    x0, y0, x1, y1 = tiles_for_region(lat, lon, span_km, zoom)
    across, down = x1 - x0 + 1, y1 - y0 + 1
    width, height = across * tile_px, down * tile_px
    pixel_size = tile_span_m(zoom) / tile_px
    origin_x, origin_y = tile_origin_m(zoom, x0, y0)

    total = across * down
    megabytes = width * height * bands * esz / 1e6
    print(
        f"{name}: z{zoom}, {across}x{down} tiles, {width}x{height} px, "
        f"{pixel_size:.2f} m/px, {megabytes:.0f} MB"
    )
    if total > 4096:
        raise SystemExit(
            f"that is {total} tiles. Lower --zoom or --span-km; the engine "
            f"resamples onto hexes anyway, so more pixels than cells is wasted work."
        )

    # Fill with the nodata sentinel where there is one, so a missing tile reads
    # as missing rather than as sea level.
    if source["nodata"] is not None and dtype == "i2":
        blank = struct.pack("<h", source["nodata"]) * (width * height)
        buf = bytearray(blank)
    else:
        buf = bytearray(width * height * bands * esz)

    fetched = 0
    for ty in range(down):
        for tx in range(across):
            z, x, y = zoom, x0 + tx, y0 + ty
            url = source["url"].format(z=z, x=x, y=y, key=api_key or "")
            body = fetch(url)
            if body is None:
                continue
            if source["format"] == "png":
                tw, th, rgb = decode_png(body)
                paste_bytes(buf, width, rgb, tw, th, 3, tx * tile_px, ty * tile_px)
            else:
                tw, th, samples, _, _ = decode_tiff(body)
                paste_i16(buf, width, samples, tw, th, tx * tile_px, ty * tile_px)
            fetched += 1
        done = (ty + 1) * across
        print(f"  {done}/{total} tiles", end="\r", flush=True)
    print(f"  {fetched}/{total} tiles fetched      ")

    if fetched == 0:
        raise SystemExit(
            "no tiles came back. For LINZ sources check that LINZ_API_KEY is set "
            "and still valid; for the DEM check the region is on land."
        )

    size = write_geotiff(
        out_path, width, height, bands, dtype, bytes(buf),
        origin_x, origin_y, pixel_size, source["nodata"],
    )
    print(f"wrote {out_path} ({size / 1e6:.1f} MB) -- {source['credit']}")


def paste_bytes(buf, mosaic_w, tile, tw, th, bands, dx, dy):
    """Copy an RGB tile into the mosaic."""
    row_bytes = tw * bands
    for row in range(th):
        dst = ((dy + row) * mosaic_w + dx) * bands
        buf[dst : dst + row_bytes] = tile[row * row_bytes : (row + 1) * row_bytes]


def paste_i16(buf, mosaic_w, samples, tw, th, dx, dy):
    """Copy a 16-bit single-band tile into the mosaic."""
    for row in range(th):
        packed = struct.pack("<" + str(tw) + "h", *samples[row * tw : (row + 1) * tw])
        dst = ((dy + row) * mosaic_w + dx) * 2
        buf[dst : dst + tw * 2] = packed


# ---------------------------------------------------------------------------


def main():
    p = argparse.ArgumentParser(
        description="Build a GeoTIFF for a New Zealand region from web map tiles.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("source", choices=sorted(SOURCES), help="which tile service to pull from")
    p.add_argument("--lat", type=float, required=True, help="centre latitude")
    p.add_argument("--lon", type=float, required=True, help="centre longitude")
    p.add_argument("--span-km", type=float, default=6.0, help="half-width of the region in km")
    p.add_argument("--zoom", type=int, default=None, help="tile zoom level (default per source)")
    p.add_argument("--out", required=True, help="GeoTIFF to write")
    p.add_argument("--api-key", default=None, help="LINZ Basemaps API key (or set LINZ_API_KEY)")
    args = p.parse_args()

    source = SOURCES[args.source]
    zoom = args.zoom if args.zoom is not None else source["zoom"]
    key = args.api_key or os.environ.get("LINZ_API_KEY")
    if source["needs_key"] and not key:
        raise SystemExit(
            f"{args.source} needs a LINZ Basemaps API key. Get a free one at\n"
            f"  https://basemaps.linz.govt.nz/\n"
            f"then set LINZ_API_KEY, or pass --api-key."
        )

    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)
    build(source, args.source, args.lat, args.lon, args.span_km, zoom, args.out, key)


if __name__ == "__main__":
    sys.exit(main())
