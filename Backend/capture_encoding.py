"""Default PNG8 RLE preparation; no transport, device, or filesystem access.

Pillow drops RGB16 low bytes during decode. This reduces precision, not gamut:
retain the original ICC profile and color signalling, with no resize/conversion.
Unknown layouts stay byte-for-byte unchanged after the caller's usual checks.
"""
from __future__ import annotations

import io
import struct
import time
import zlib

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
COLOR_CHUNKS = frozenset({b"cICP", b"gAMA", b"cHRM", b"sRGB"})
SUPPORTED_CHUNKS = COLOR_CHUNKS | {b"IHDR", b"IDAT", b"IEND", b"iCCP", b"eXIf"}


def checked_chunks(data):
    """Check every chunk CRC, bounds and exact IEND before transcoding.

    Image.load() alone does not check IDAT CRCs. Never wash a damaged input
    through an encoder and validate only the newly generated output.
    """
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("invalid PNG signature")
    view, pos, found_idat = memoryview(data), 8, False
    chunks = []
    while pos + 12 <= len(data):
        size = struct.unpack_from(">I", view, pos)[0]
        end = pos + 12 + size
        if end > len(data):
            raise ValueError("truncated PNG chunk")
        kind = data[pos + 4:pos + 8]
        payload = view[pos + 8:pos + 8 + size]
        expected = struct.unpack_from(">I", view, pos + 8 + size)[0]
        if zlib.crc32(view[pos + 4:pos + 8 + size]) & 0xffffffff != expected:
            raise ValueError("PNG CRC mismatch")
        if not chunks and (kind != b"IHDR" or size != 13):
            raise ValueError("missing PNG IHDR")
        if chunks and kind == b"IHDR":
            raise ValueError("duplicate PNG IHDR")
        chunks.append((kind, payload))
        if kind == b"IDAT":
            found_idat = True
        if kind == b"IEND":
            if size or end != len(data) or not found_idat:
                raise ValueError("invalid PNG ending")
            return chunks
        pos = end
    raise ValueError("missing PNG IEND")


def prepare_png8(data, *, original_prepare, check_pixels, dimensions_ok, failure, timings):
    """One decode for supported RGB16 frames; otherwise original validation.

    Limit transcoding to opaque RGB, with a supplied ICC profile and known
    metadata. In particular do not truncate alpha or copy bit-depth-dependent
    tRNS, sBIT, bKGD or HDR signalling into an 8-bit frame.
    """
    from PIL import Image, PngImagePlugin
    import hashlib

    try:
        chunks = checked_chunks(data)
    except Exception:
        raise failure("invalid_png") from None
    counts = {}
    for kind, _ in chunks:
        counts[kind] = counts.get(kind, 0) + 1
    supported = (data[24:26] == b"\x10\x02"
                 and all(kind in SUPPORTED_CHUNKS for kind in counts)
                 and all(count == 1 for kind, count in counts.items() if kind != b"IDAT")
                 and not (b"sRGB" in counts and b"iCCP" in counts))
    # This measured Display P3 signal is SDR. Unmeasured HDR signals stay intact.
    for kind, payload in chunks:
        if kind == b"cICP" and bytes(payload) != b"\x0c\x0d\x00\x01":
            supported = False
    if not supported:
        return original_prepare(data)
    try:
        with Image.open(io.BytesIO(data)) as image:
            if (image.format != "PNG" or image.mode != "RGB"
                    or getattr(image, "n_frames", 1) != 1
                    or not image.info.get("icc_profile")):
                return original_prepare(data)
            if not dimensions_ok(image.size):
                raise failure("unexpected_dimensions")
            image.load()
            check_pixels(image)
            width, height = image.size
            info = PngImagePlugin.PngInfo()
            for kind, payload in chunks:
                if kind in COLOR_CHUNKS:
                    info.add(kind, bytes(payload))
            options = {"icc_profile": image.info["icc_profile"], "pnginfo": info,
                       "compress_level": 1, "compress_type": zlib.Z_RLE}
            if image.info.get("exif"):
                options["exif"] = image.info["exif"]
            encode_started = time.perf_counter()
            try:
                output = io.BytesIO()
                image.save(output, format="PNG", **options)
                candidate = output.getvalue()
                encoded_chunks = checked_chunks(candidate)
                preserved = COLOR_CHUNKS | {b"eXIf"}
                before = [(kind, bytes(payload)) for kind, payload in chunks if kind in preserved]
                after = [(kind, bytes(payload)) for kind, payload in encoded_chunks if kind in preserved]
                if sorted(before) != sorted(after) or candidate[24:26] != b"\x08\x02":
                    raise ValueError("PNG color metadata changed")
                # Header/metadata read only: no second pixel decode.
                with Image.open(io.BytesIO(candidate)) as encoded:
                    if (encoded.size != image.size or encoded.mode != image.mode
                            or encoded.info.get("icc_profile") != image.info["icc_profile"]):
                        raise ValueError("PNG profile or dimensions changed")
                if len(candidate) < len(data):
                    data = candidate
                    timings["png_encoded"] = 1
            except Exception:
                # The original has already passed CRC, decode and pixel checks.
                # An encoder failure must not lose this valid fresh screenshot.
                timings["png_encode_fallback"] = 1
            finally:
                timings["png_encode_ms"] = (time.perf_counter() - encode_started) * 1000
    except failure:
        raise
    except Exception:
        raise failure("invalid_png") from None
    return data, {"width": width, "height": height, "bit_depth": data[24],
                  "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
