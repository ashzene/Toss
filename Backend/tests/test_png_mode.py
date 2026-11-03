"""Default PNG8 policy and real receipt paths using synthetic, offline frames."""
import asyncio
import contextlib
from functools import lru_cache
import hashlib
import io
import json
import math
import os
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

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture_once as capture
import capture_service as service
from PIL import Image

MODE_VARIABLE = "TOSS_CAPTURE_PNG_MODE"


@contextlib.contextmanager
def mode(value):
    with mock.patch.dict(os.environ):
        if value is None:
            os.environ.pop(MODE_VARIABLE, None)
        else:
            os.environ[MODE_VARIABLE] = value
        yield


def chunk(kind, payload):
    return (struct.pack(">I", len(payload)) + kind + payload
            + struct.pack(">I", zlib.crc32(kind + payload)))


@lru_cache(maxsize=1)
def rgb16():
    # Independent 16-bit fixture: random low bytes make dropping precision save
    # space; the high bytes, dimensions and ICC must survive unchanged.
    width, height = 1000, 1400
    rng = random.Random(20261030)
    raw = bytearray()
    for _ in range(height):
        row = bytearray(b"\xab\x00\x40\x00\xf0\x00" * width)
        row[1::2] = rng.randbytes(width * 3)
        raw.extend(b"\x00" + row)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 16, 2, 0, 0, 0))
            + chunk(b"iCCP", b"Test\x00\x00" + zlib.compress(b"synthetic-icc-profile"))
            + chunk(b"cICP", b"\x0c\x0d\x00\x01")
            + chunk(b"IDAT", zlib.compress(raw, level=1)) + chunk(b"IEND", b""))


async def synthetic_capture(_provider):
    started = time.monotonic()
    return rgb16(), started, time.monotonic()


def private_fixture(base):
    state, output = base / "state", base / "output"
    state.mkdir(mode=0o700)
    output.mkdir(mode=0o700)
    for name in ("target.json", "strict-remote-pairing.plist"):
        path = state / name
        path.write_text("synthetic-placeholder-not-real-pairing")
        path.chmod(0o600)
    return state, output


class InMemoryConnection:
    async def __aenter__(self):
        return object(), {}

    async def __aexit__(self, *_args):
        pass


class PNGModeTests(unittest.TestCase):
    def assert_metadata(self, data, metadata):
        self.assertEqual(metadata, {
            "width": 1000, "height": 1400, "bit_depth": data[24],
            "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})

    def test_default_enables_png8_rle(self):
        source, timings = rgb16(), {"existing_timing": 42}
        with mode(None):
            data, metadata = capture.prepare_png(source, timings=timings)
        with mode("png8-rle"):
            explicit, explicit_metadata = capture.prepare_png(source)
        self.assertEqual((data, metadata), (explicit, explicit_metadata))
        self.assertEqual(data[24], 8)
        self.assertLess(len(data), len(source))
        self.assert_metadata(data, metadata)
        self.assertEqual(timings["png_encoded"], 1)
        self.assertEqual(timings["png_input_bytes"], len(source))
        self.assertEqual(timings["png_output_bytes"], len(data))
        self.assertEqual(timings["existing_timing"], 42)
        self.assertNotIn("png_mode_warning", timings)
        with Image.open(io.BytesIO(data)) as image:
            self.assertEqual(image.getpixel((0, 0)), (0xab, 0x40, 0xf0))
            self.assertEqual(image.info["icc_profile"], b"synthetic-icc-profile")

    def test_original_disables_reencoding(self):
        source, timings = rgb16(), {}
        with mode("original"), mock.patch("capture_encoding.prepare_png8") as encoder:
            data, metadata = capture.prepare_png(source, timings=timings)
        encoder.assert_not_called()
        self.assertIs(data, source)
        self.assertEqual(data[24], 16)
        self.assert_metadata(data, metadata)
        self.assertEqual(timings["png_encoded"], 0)
        self.assertNotIn("png_encode_ms", timings)
        self.assertNotIn("png_mode_warning", timings)

    def test_unknown_values_fall_back_to_default_with_numeric_warning(self):
        with mode(None):
            expected = capture.prepare_png(rgb16())
        for value in ("unknown-value", "", "PNG8-RLE", "original ", "SECRET\ntext"):
            with self.subTest(value=value), mode(value):
                timings = {}
                self.assertEqual(capture.prepare_png(rgb16(), timings=timings), expected)
                self.assertEqual(timings["png_mode_warning"], 1)
                self.assertEqual(timings["png_encoded"], 1)
                self.assertTrue(all(type(v) in (int, float) and math.isfinite(v) and v >= 0
                                    for v in timings.values()))
        # A bad setting must not bypass normal image validation.
        with mode("unknown-value"):
            timings = {}
            with self.assertRaises(capture.CaptureFailure) as error:
                capture.prepare_png(b"not a PNG", timings=timings)
            self.assertEqual(str(error.exception), "invalid_png")
            self.assertEqual(timings["png_mode_warning"], 1)

    def test_8bit_input_passes_through_in_every_mode(self):
        output = io.BytesIO()
        Image.new("RGB", (1000, 1400), "white").save(output, format="PNG")
        source = output.getvalue()
        for value in (None, "original", "png8-rle", "unknown-value"):
            with self.subTest(mode=value), mode(value):
                timings = {}
                with mock.patch("capture_encoding.prepare_png8") as encoder:
                    data, metadata = capture.prepare_png(source, timings=timings)
                encoder.assert_not_called()
                self.assertIs(data, source)
                self.assert_metadata(data, metadata)
                self.assertEqual(timings["png_encoded"], 0)
                self.assertEqual(timings.get("png_mode_warning", 0), int(value == "unknown-value"))


class PNGReceiptTests(unittest.TestCase):
    def assert_receipt(self, result, output, value):
        self.assertTrue(result["ok"], result)
        data = output.read_bytes()
        self.assertEqual(result["bytes"], len(data))
        self.assertEqual(result["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(result["bit_depth"], 16 if value == "original" else 8)
        timings = result["timings_ms"]
        self.assertEqual(timings["png_output_bytes"], len(data))
        self.assertEqual(timings["png_encoded"], int(value != "original"))
        self.assertEqual(timings.get("png_mode_warning", 0), int(value == "unknown-value"))
        self.assertTrue(all(type(v) in (int, float) and math.isfinite(v) and v >= 0
                            for v in timings.values()))

    def test_one_shot_publishes_mode_timings_and_final_receipt(self):
        for value in (None, "original", "unknown-value"):
            with self.subTest(mode=value), mode(value), tempfile.TemporaryDirectory() as folder:
                state, output = private_fixture(Path(folder))
                target = output / "frame.png"
                result = capture.run_request(state, target, str(uuid.uuid4()), 8,
                                             capture=synthetic_capture)
                self.assert_receipt(result, target, value)

    def test_persistent_worker_publishes_mode_timings_and_final_receipt(self):
        async def run(value):
            with tempfile.TemporaryDirectory() as folder:
                state, output = private_fixture(Path(folder))
                worker = service.CaptureService(state, output,
                    connection_factory=lambda _: InMemoryConnection(), capture=synthetic_capture)
                target = output / "frame.png"
                receipts = []
                async def emit(receipt):
                    receipts.append(receipt)
                request = {"action": "capture", "request_id": str(uuid.uuid4()),
                           "output_file": str(target), "timeout": 8}
                try:
                    await worker.accept(json.dumps(request).encode(), emit)
                    if worker.active is not None:
                        await worker.active
                    self.assertEqual(len(receipts), 1)
                    self.assert_receipt(receipts[0], target, value)
                finally:
                    await worker.shutdown()
        for value in (None, "original", "unknown-value"):
            with self.subTest(mode=value), mode(value):
                asyncio.run(run(value))


if __name__ == "__main__":
    unittest.main()
