"""PNG8 integration with phone dimensions and isolated dual-device routing.

All frames, pins, connections and capture calls are synthetic and local.
"""
import asyncio
from functools import lru_cache
import hashlib
import io
import json
from pathlib import Path
import random
import struct
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid
import zlib

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture_encoding as encoding
import capture_once as capture
import capture_service as service
import paired_devices as devices
from test_png_mode import chunk, mode, private_fixture, InMemoryConnection, rgb16
from test_two_devices import save_state


@lru_cache(maxsize=8)
def phone_frame(size=(750, 1334), *, color_type=2, alpha=255, noisy=True, black=False):
    width, height = size
    channels = 3 if color_type == 2 else 4
    pixel = (b"\x00\x00" * 3 if black else b"\xab\x00\x40\x00\xf0\x00")
    if channels == 4:
        pixel += bytes((alpha, alpha))
    rng = random.Random(20261102)
    raw = bytearray()
    for _ in range(height):
        row = bytearray(pixel * width)
        if noisy:
            for channel in range(3):
                row[channel * 2 + 1::channels * 2] = rng.randbytes(width)
        raw.extend(b"\x00" + row)
    return (encoding.PNG_SIGNATURE
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 16, color_type, 0, 0, 0))
            + chunk(b"iCCP", b"Test\x00\x00" + zlib.compress(b"synthetic-icc-profile"))
            + chunk(b"cICP", b"\x0c\x0d\x00\x01")
            + chunk(b"IDAT", zlib.compress(raw, level=1 if noisy else 9))
            + chunk(b"IEND", b""))


def metadata_variant(source, *, remove=(), replace=None, extra=()):
    replace = replace or {}
    parts = [encoding.PNG_SIGNATURE]
    for kind, data in encoding.checked_chunks(source):
        if kind == b"IDAT":
            parts.extend(chunk(k, v) for k, v in extra)
        if kind not in remove:
            parts.append(chunk(kind, replace.get(kind, bytes(data))))
    return b"".join(parts)


async def phone_capture(_provider):
    started = time.monotonic()
    return phone_frame(), started, time.monotonic()


async def landscape_capture(_provider):
    started = time.monotonic()
    return phone_frame((1334, 750)), started, time.monotonic()


class PhonePNGTests(unittest.TestCase):
    def test_phone_portrait_and_landscape_modes_keep_pixels_and_profile(self):
        for size in ((750, 1334), (1334, 750)):
            source = phone_frame(size)
            for value in (None, "png8-rle", "original", "unknown-value"):
                with self.subTest(size=size, mode=value), mode(value):
                    timings = {}
                    data, metadata = capture.prepare_png(source, "iPhone", timings=timings)
                    self.assertEqual((metadata["width"], metadata["height"]), size)
                    self.assertEqual(metadata["bit_depth"], 16 if value == "original" else 8)
                    self.assertEqual(timings["png_encoded"], int(value != "original"))
                    self.assertEqual(timings.get("png_mode_warning", 0), int(value == "unknown-value"))
                    with Image.open(io.BytesIO(data)) as image:
                        self.assertEqual(image.getpixel((0, 0)), (0xab, 0x40, 0xf0))
                        self.assertEqual(image.info["icc_profile"], b"synthetic-icc-profile")

    def test_cross_class_frames_rejected_by_encoder_and_original_fallback(self):
        for source, wrong_class in ((phone_frame(), "iPad"), (rgb16(), "iPhone")):
            for frame in (source, metadata_variant(source, remove=(b"iCCP",))):
                for value in (None, "original", "unknown-value"):
                    with self.subTest(device_class=wrong_class, mode=value), mode(value):
                        with self.assertRaisesRegex(capture.CaptureFailure, "^unexpected_dimensions$"):
                            capture.prepare_png(frame, wrong_class)

    def test_unknown_device_class_is_never_inferred_from_pixels(self):
        for device_class in (None, "Watch", "iphone"):
            with mode(None), self.assertRaisesRegex(capture.CaptureFailure, "^unexpected_dimensions$"):
                capture.prepare_png(phone_frame(), device_class)

    def test_unmeasured_color_and_depth_dependent_chunks_stay_original(self):
        source = phone_frame()
        variants = (
            metadata_variant(source, replace={b"cICP": b"\x09\x10\x00\x01"}),
            metadata_variant(source, extra=((b"sBIT", b"\x10\x10\x10"),)),
            metadata_variant(source, remove=(b"iCCP",)),
        )
        for frame in variants:
            with mode(None):
                timings = {}
                data, metadata = capture.prepare_png(frame, "iPhone", timings=timings)
            self.assertIs(data, frame)
            self.assertEqual(metadata["bit_depth"], 16)
            self.assertEqual(timings["png_encoded"], 0)

    def test_rgba_is_not_quantized_and_transparent_frames_still_fail(self):
        with mode(None):
            source = phone_frame(color_type=6)
            self.assertIs(capture.prepare_png(source, "iPhone")[0], source)
            with self.assertRaisesRegex(capture.CaptureFailure, "^invalid_png$"):
                capture.prepare_png(phone_frame(color_type=6, alpha=0), "iPhone")

    def test_encoder_error_returns_validated_original_with_timings(self):
        source, timings = phone_frame(), {}
        with mode(None), mock.patch.object(Image.Image, "save", side_effect=OSError("synthetic")):
            data, metadata = capture.prepare_png(source, "iPhone", timings=timings)
        self.assertIs(data, source)
        self.assertEqual(metadata["sha256"], hashlib.sha256(source).hexdigest())
        self.assertEqual(timings["png_encode_fallback"], 1)
        self.assertEqual(timings["png_encoded"], 0)
        self.assertGreaterEqual(timings["png_encode_ms"], 0)

    def test_encoder_profile_change_falls_back_to_original(self):
        original_save = Image.Image.save
        def changed_profile(image, output, **options):
            options["icc_profile"] = b"changed-synthetic-profile"
            original_save(image, output, **options)
        source, timings = phone_frame(), {}
        with mode(None), mock.patch.object(Image.Image, "save", changed_profile):
            data, _ = capture.prepare_png(source, "iPhone", timings=timings)
        self.assertIs(data, source)
        self.assertEqual(timings["png_encode_fallback"], 1)

    def test_cicp_and_exif_survive_encoding_exactly(self):
        exif = Image.Exif()
        exif[0x010e] = "synthetic-only"
        source = metadata_variant(phone_frame(), extra=((b"eXIf", exif.tobytes()[6:]),))
        with mode(None):
            data, metadata = capture.prepare_png(source, "iPhone")
        self.assertEqual(metadata["bit_depth"], 8)
        def preserved(frame):
            return {k: bytes(v) for k, v in encoding.checked_chunks(frame) if k in (b"cICP", b"eXIf")}
        self.assertEqual(preserved(source), preserved(data))

    def test_damaged_idat_crc_is_rejected_before_encoding(self):
        damaged = bytearray(phone_frame())
        pos = 8
        while damaged[pos + 4:pos + 8] != b"IDAT":
            pos += 12 + struct.unpack_from(">I", damaged, pos)[0]
        size = struct.unpack_from(">I", damaged, pos)[0]
        damaged[pos + 8 + size] ^= 1
        with mode(None), self.assertRaisesRegex(capture.CaptureFailure, "^invalid_png$"):
            capture.prepare_png(bytes(damaged), "iPhone")

    def test_no_size_saving_keeps_original_bytes(self):
        source, timings = phone_frame(noisy=False), {}
        original_save = Image.Image.save
        def larger_valid_output(image, output, **options):
            # Produce a valid but deliberately inefficient candidate; uniform
            # input alone does not guarantee that RGB8 will be larger than RGB16.
            options["compress_level"] = 0
            original_save(image, output, **options)
            self.assertGreater(output.tell(), len(source))
        with mode(None), mock.patch.object(Image.Image, "save", larger_valid_output):
            data, _ = capture.prepare_png(source, "iPhone", timings=timings)
        self.assertIs(data, source)
        self.assertEqual(timings["png_encoded"], 0)
        self.assertNotIn("png_encode_fallback", timings)

    def test_black_frame_is_rejected_before_publication(self):
        with mode(None), self.assertRaisesRegex(capture.CaptureFailure, "^black_frame_rejected$"):
            capture.prepare_png(phone_frame(black=True), "iPhone")


class PhonePNGReceiptTests(unittest.TestCase):
    def assert_receipt(self, result, target, value, size):
        self.assertTrue(result["ok"], result)
        data = target.read_bytes()
        self.assertEqual((result["width"], result["height"]), size)
        self.assertEqual(result["bit_depth"], 16 if value == "original" else 8)
        self.assertEqual(result["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(result["bytes"], len(data))
        timings = result["timings_ms"]
        self.assertEqual(timings["png_output_bytes"], len(data))
        self.assertEqual(timings["png_encoded"], int(value != "original"))
        self.assertEqual(timings.get("png_mode_warning", 0), int(value == "unknown-value"))
        self.assertGreaterEqual(timings["png_prepare_ms"], 0)

    def test_phone_one_shot_publishes_mode_and_timings_in_both_orientations(self):
        for value in (None, "original", "unknown-value"):
            for callback, size in ((phone_capture, (750, 1334)), (landscape_capture, (1334, 750))):
                with self.subTest(mode=value, size=size), mode(value), tempfile.TemporaryDirectory() as folder:
                    state, output = private_fixture(Path(folder))
                    (state / "target.json").write_text(json.dumps({"model": "iPhone17,3", "device_hash": "synthetic"}))
                    target = output / "frame.png"
                    result = capture.run_request(state, target, str(uuid.uuid4()), 8, capture=callback)
                    self.assert_receipt(result, target, value, size)

    def test_dual_device_workers_keep_class_routing_and_receipt_timings(self):
        async def run(value, transport):
            with tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                (root / "devices").mkdir(mode=0o700)
                output = root / "output"
                output.mkdir(mode=0o700)
                for kind in devices.CLASSES:
                    save_state(devices.device_directory(root, kind), kind)
                    devices.register_device(root, kind)
                before = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
                for kind in devices.CLASSES:
                    frame = phone_frame() if kind == "iPhone" else rgb16()
                    async def synthetic(_provider):
                        started = time.monotonic()
                        return frame, started, time.monotonic()
                    worker = service.CaptureService(root, output, device_class=kind, transport=transport,
                        connection_factory=lambda _: InMemoryConnection(), capture=synthetic)
                    target = output / (kind + ".png")
                    receipts = []
                    async def emit(receipt):
                        receipts.append(receipt)
                    try:
                        await worker.accept(json.dumps({"action": "capture", "request_id": str(uuid.uuid4()),
                            "output_file": str(target), "timeout": 8, "device_class": kind}).encode(), emit)
                        if worker.active is not None:
                            await worker.active
                        self.assertEqual(len(receipts), 1)
                        self.assert_receipt(receipts[0], target, value, (750, 1334) if kind == "iPhone" else (1000, 1400))
                        self.assertEqual(receipts[0]["transport"], "authenticated_" + transport)
                    finally:
                        await worker.shutdown()
                self.assertEqual(before, {p: p.read_bytes() for p in before})
        for value in (None, "original", "unknown-value"):
            for transport in ("usb", "wifi"):
                with self.subTest(mode=value, transport=transport), mode(value):
                    asyncio.run(run(value, transport))


if __name__ == "__main__":
    unittest.main()
