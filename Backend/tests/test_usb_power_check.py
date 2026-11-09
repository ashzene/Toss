"""Pure tests only: no device, network, or window calls."""
import contextlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import usb_power_check as check


class PowerCheckTests(unittest.TestCase):
    def test_only_a_real_boolean_counts(self):
        self.assertIs(check.external_connected({"ExternalConnected": True}), True)
        self.assertIs(check.external_connected({"ExternalConnected": False}), False)
        self.assertIsNone(check.external_connected({"ExternalConnected": 1}))
        self.assertIsNone(check.external_connected({}))
        self.assertIsNone(check.external_connected(None))

    def test_an_unreachable_device_reports_null_and_exits_cleanly(self):
        async def fails(_state):
            raise ConnectionError("unreachable")
        output = io.StringIO()
        with mock.patch.object(check, "read_power", fails), mock.patch.object(check.threading, "Timer") as timer, \
                contextlib.redirect_stdout(output):
            self.assertEqual(check.main(["--state-dir", "unused"]), 0)
        self.assertEqual(json.loads(output.getvalue()), {"external_connected": None})
        self.assertTrue(timer.return_value.daemon)
        timer.return_value.start.assert_called_once()


if __name__ == "__main__":
    unittest.main()
