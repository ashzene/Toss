"""Synthetic AMFI/lockdown only. No USB inventory, network, devices or UI."""
import asyncio
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import setup_device as setup
import developer_mode as dm
from pymobiledevice3.exceptions import AmfiError, DeviceHasPasscodeSetError, PasswordRequiredError
from pymobiledevice3.services.amfi import AmfiService as RealAmfiService


class FakeClient:
    def __init__(self):
        self.udid = "00008110-001234567890ABCD"
        self.identifier = self.udid
        self.all_values = {"DeviceName": "测试者的 iPhone", "UniqueDeviceID": self.udid,
                           "SerialNumber": "FAKE-SERIAL-123", "PasswordProtected": False}
        self.paired = True
        self.product_type = "iPhone17,3" if hasattr(setup, "select_usb_device") else "iPad14,3"
        self.product_version = "18.7"
        self.status = False
        self.closed = 0
        self.gates = []
        self.probes = 0

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        self.closed += 1

    async def get_developer_mode_status(self):
        return self.status

    async def get_service_connection_attributes(self, name):
        assert name == "com.apple.amfi.lockdown"
        self.probes += 1
        value = self.gates.pop(0) if self.gates else {}
        if isinstance(value, BaseException):
            raise value
        return value


class RedactionTests(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient()

    def test_plain_amfi_reason_and_class_preserved(self):
        self.assertEqual(dm.safe_error(AmfiError("Service temporarily unavailable"), self.client),
                         "AmfiError: Service temporarily unavailable")

    def test_empty_passcode_exception_recovers_exact_known_reply(self):
        self.assertEqual(dm.safe_error(DeviceHasPasscodeSetError(), self.client),
                         "DeviceHasPasscodeSetError: Device has a passcode set")

    def test_names_ids_and_serials_are_redacted_in_plain_and_escaped_forms(self):
        for value in (self.client.all_values["DeviceName"], self.client.udid, "FAKE-SERIAL-123"):
            for text in (value, value.lower(), json.dumps(value)[1:-1]):
                with self.subTest(text=text):
                    result = dm.safe_error(AmfiError("failed for " + text), self.client)
                    self.assertNotIn(text, result)
                    self.assertIn("[redacted]", result)

    def test_unknown_labelled_names_and_udid_formats(self):
        for text in ('DeviceName="Other Person’s iPad"', "device name: Other Person's tablet",
                     "UDID=unknown-opaque-id", "a" * 40, "00008120-0011223344556677",
                     "DEADBEEF-ABCD-1234-5678-112233445566"):
            with self.subTest(text=text):
                result = dm.safe_error(AmfiError(text))
                self.assertIn("[redacted]", result)
                self.assertNotIn("Other Person", result)
                self.assertNotIn("unknown-opaque-id", result)
                self.assertNotIn("0011223344556677", result)

    def test_posix_windows_relative_file_url_and_spaces_in_paths(self):
        for path in ('"/Users/Private Person/Pairing/record.plist"',
                     "'/private/tmp/Private Folder/a.log'", r'"C:\Users\Private Person\record.plist"',
                     r'\\PrivateServer\Pairing\record.plist', "~/PrivateFolder/record.plist",
                     "../PrivateFolder/record.plist", "PrivateFolder/record.plist", '"Private Folder/record.plist"',
                     "file:///Users/PrivatePerson/record.plist", "/Users/Private Person/record.plist"):
            with self.subTest(path=path):
                result = dm.safe_error(AmfiError("denied at " + path + "; service unavailable"))
                self.assertIn("[path]", result)
                self.assertNotIn("Private", result)
                self.assertNotIn("record.plist", result)
                self.assertIn("service unavailable", result)

    def test_redaction_precedes_truncation_and_result_is_one_line(self):
        result = dm.safe_error(AmfiError("/Users/PrivatePerson/" + "x" * 400 + "; unavailable\r\nagain"))
        self.assertNotIn("PrivatePerson", result)
        self.assertNotIn("x" * 5, result)
        self.assertNotIn("\n", result)
        self.assertNotIn("\r", result)
        self.assertEqual(dm.safe_error(AmfiError("中" * 400)), "AmfiError: " + "中" * 189)
        self.assertEqual(len(dm.safe_error(AmfiError("中" * 400))), 200)

    def test_normalized_and_apostrophe_device_names(self):
        from urllib.parse import quote
        for name in ("Alex's iPhone", "Ａｌｅｘ的手机", "Cafe\u0301 iPad", "Ａ"):
            self.client.all_values["DeviceName"] = name
            for form in (name, json.dumps(name)[1:-1], repr(name)[1:-1], quote(name, safe="")):
                with self.subTest(name=name, form=form):
                    self.assertEqual(dm.safe_error(AmfiError("Device " + form), self.client),
                                     "AmfiError: Device [redacted]")

    def test_only_lock_errors_request_unlock(self):
        for error in (PasswordRequiredError(), AmfiError("DeviceLocked"), AmfiError("Device is locked")):
            self.assertTrue(dm.needs_unlock(error))
        for error in (DeviceHasPasscodeSetError(), AmfiError("Service unavailable"), AmfiError("device is unlocked")):
            self.assertFalse(dm.needs_unlock(error))


class EnableFixture:
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name) / "state"
        self.state.mkdir(mode=0o700)
        self.client = FakeClient()
        self.now = 0
        self.sleeps = []
        self.calls = []
        self.outcomes = []
        self.diagnostics = {}
        self.events = []
        self.reveal_error = None
        self.enable_hook = None
        owner = self

        class FakeAMFI:
            def __init__(self, client):
                self.client = client

            async def enable_developer_mode(self, *, enable_post_restart):
                owner.calls.append(("enable", enable_post_restart, owner.now))
                if owner.enable_hook:
                    owner.enable_hook()
                value = owner.outcomes.pop(0) if owner.outcomes else None
                if isinstance(value, BaseException):
                    raise value

            async def reveal_developer_mode_option_in_ui(self):
                owner.calls.append(("reveal", owner.now))
                if owner.reveal_error:
                    raise owner.reveal_error

            async def enable_developer_mode_post_restart(self):
                owner.calls.append(("accept", owner.now))
                owner.client.status = True

        async def sleep(seconds):
            self.sleeps.append(seconds)
            self.now += seconds

        for patcher in (mock.patch("pymobiledevice3.services.amfi.AmfiService", FakeAMFI),
                        mock.patch.object(dm, "time", SimpleNamespace(monotonic=lambda: self.now)),
                        mock.patch.object(dm.asyncio, "sleep", sleep),
                        mock.patch.object(setup, "lockdown_for", mock.AsyncMock(return_value=self.client))):
            patcher.start()
            self.addCleanup(patcher.stop)
        # The fake exposes the same service constant used by the gate probe.
        FakeAMFI.SERVICE_NAME = "com.apple.amfi.lockdown"

    def progress(self, ok, code, **fields):
        self.events.append({"ok": ok, "code": code, **fields})

    async def enable(self, **kwargs):
        return await dm.enable(self.client, progress=self.progress, diagnostics=self.diagnostics,
                               state=self.state, **kwargs)

    def logs(self):
        return [json.loads(line) for line in (self.state.parent / "link-timeline.jsonl").read_text().splitlines()]

class EnableTests(EnableFixture, unittest.IsolatedAsyncioTestCase):
    async def test_success_does_not_reveal_sleep_probe_or_add_failure_fields(self):
        self.assertEqual(await self.enable(), "rebooting")
        self.assertEqual(self.calls, [("enable", False, 0)])
        self.assertEqual((self.sleeps, self.events, self.diagnostics, self.client.probes), ([], [], {}, 0))
        self.assertFalse((self.state.parent / "link-timeline.jsonl").exists())

    async def test_explicit_passcode_immediately_reveals_without_retry(self):
        self.outcomes = [DeviceHasPasscodeSetError()]
        self.assertEqual(await self.enable(), "manual")
        self.assertEqual([call[0] for call in self.calls], ["enable", "reveal"])
        self.assertEqual((self.sleeps, self.client.probes), ([], 0))
        self.assertEqual(self.diagnostics["devmode_passcode"], 1)
        self.assertIn("Device has a passcode set", self.diagnostics["devmode_enable_error"])
        self.assertEqual(self.logs()[0]["devmode_passcode"], 1)

    async def test_locked_waits_for_unlock_then_retries_successfully(self):
        self.outcomes = [PasswordRequiredError("Please unlock"), None]
        self.client.gates = [PasswordRequiredError(), PasswordRequiredError(), {}]
        self.assertEqual(await self.enable(), "rebooting")
        self.assertEqual([call[0] for call in self.calls], ["enable", "enable"])
        self.assertEqual(self.client.probes, 3)
        self.assertEqual(self.sleeps, [1.5, 1.5, 2])
        self.assertEqual(self.events[0]["code"], "unlock_needed")
        self.assertEqual(self.events[0]["devmode_passcode"], 0)

    async def test_amfi_locked_text_also_emits_unlock_needed(self):
        self.outcomes = [AmfiError("Device is locked"), None]
        self.assertEqual(await self.enable(), "rebooting")
        self.assertEqual([event["code"] for event in self.events], ["unlock_needed"])

    async def test_generic_error_with_closed_service_gate_waits_for_unlock(self):
        self.outcomes = [AmfiError("Service unavailable"), None]
        self.client.gates = [PasswordRequiredError(), {}]
        self.assertEqual(await self.enable(), "rebooting")
        self.assertEqual([event["code"] for event in self.events], ["unlock_needed"])
        self.assertEqual(self.sleeps, [1.5, 2])

    async def test_transient_failure_retries_with_no_manual_or_unlock_prompt(self):
        self.outcomes = [AmfiError("Service unavailable"), None]
        self.assertEqual(await self.enable(), "rebooting")
        self.assertEqual(self.events, [])
        self.assertEqual(self.sleeps, [2])
        self.assertEqual(self.diagnostics["devmode_passcode"], 0)

    async def test_persistent_error_has_three_attempts_increasing_delays_then_reveal(self):
        self.outcomes = [AmfiError("busy 1"), AmfiError("busy 2"), AmfiError("busy 3")]
        self.assertEqual(await self.enable(), "manual")
        self.assertEqual(self.calls, [("enable", False, 0), ("enable", False, 2),
                                     ("enable", False, 6), ("reveal", 6)])
        self.assertEqual(self.sleeps, [2, 4])
        self.assertEqual(self.diagnostics, {"devmode_enable_error": "AmfiError: busy 3", "devmode_passcode": 0})
        self.assertEqual([row["devmode_attempt"] for row in self.logs()], [1, 2, 3])

    async def test_passcode_after_transient_stops_remaining_attempts(self):
        self.outcomes = [AmfiError("busy"), DeviceHasPasscodeSetError()]
        self.assertEqual(await self.enable(), "manual")
        self.assertEqual([call[0] for call in self.calls], ["enable", "enable", "reveal"])
        self.assertEqual(self.diagnostics["devmode_passcode"], 1)

    async def test_passcode_flag_false_does_not_hide_actual_amfi_error(self):
        self.outcomes = [AmfiError("AMFI policy refused request")] * 3
        self.assertEqual(await self.enable(), "manual")
        self.assertEqual(self.diagnostics["devmode_passcode"], 0)
        self.assertEqual(self.diagnostics["devmode_enable_error"], "AmfiError: AMFI policy refused request")

    async def test_lock_wait_respects_deadline_without_consuming_enable_attempts(self):
        self.outcomes = [PasswordRequiredError()]
        self.client.gates = [PasswordRequiredError()] * 10
        self.assertEqual(await self.enable(deadline=3), "locked")
        self.assertEqual(self.now, 3)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.events[0]["code"], "unlock_needed")

    async def test_cancellation_propagates_without_fallback(self):
        self.outcomes = [asyncio.CancelledError()]
        with self.assertRaises(asyncio.CancelledError):
            await self.enable()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.diagnostics, {})

    async def test_reveal_error_preserves_original_enable_reason(self):
        self.outcomes = [DeviceHasPasscodeSetError()]
        self.reveal_error = AmfiError("reveal failed with SECRET")
        self.assertEqual(await self.enable(), "manual")
        self.assertNotIn("SECRET", self.diagnostics["devmode_enable_error"])

    async def test_retry_reconnects_and_closes_new_client(self):
        self.outcomes = [ConnectionError("Disconnected"), None]
        replacement = FakeClient()
        reconnect = mock.AsyncMock(return_value=replacement)
        self.assertEqual(await self.enable(reconnect=reconnect), "rebooting")
        reconnect.assert_awaited_once()
        self.assertEqual(replacement.closed, 1)
        self.assertEqual(self.client.closed, 0)

    async def test_reconnect_failures_are_bounded_and_logged(self):
        self.outcomes = [ConnectionError("Disconnected")]
        reconnect = mock.AsyncMock(side_effect=ConnectionError("Still disconnected"))
        self.assertEqual(await self.enable(reconnect=reconnect), "manual")
        self.assertEqual(reconnect.await_count, 2)
        self.assertEqual(len(self.logs()), 3)
        self.assertIn("Still disconnected", self.diagnostics["devmode_enable_error"])

    async def test_log_contains_same_sanitized_reason_and_owner_only_permissions(self):
        self.outcomes = [AmfiError("DeviceName=" + json.dumps(self.client.all_values["DeviceName"]) +
                                   "; " + self.client.udid + "; /Users/Private/path")] * 3
        await self.enable()
        path = self.state.parent / "link-timeline.jsonl"
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        text = path.read_text()
        for secret in (self.client.udid, "Private", json.dumps(self.client.all_values["DeviceName"])[1:-1]):
            self.assertNotIn(secret, text)
        self.assertEqual(self.logs()[-1]["devmode_enable_error"], self.diagnostics["devmode_enable_error"])

    async def test_unwritable_log_does_not_stop_manual_fallback(self):
        (self.state.parent / "link-timeline.jsonl").mkdir()
        self.outcomes = [DeviceHasPasscodeSetError()]
        self.assertEqual(await self.enable(), "manual")

    async def test_real_amfi_reply_mapping_for_passcode_and_other_error(self):
        for reply, passcode, actions in (("Device has a passcode set", 1, [1, 0]),
                                        ("AMFI policy refused request", 0, [1, 1, 1, 0])):
            with self.subTest(reply=reply):
                sent = []

                async def send(request):
                    sent.append(request["action"])
                    return {"Error": reply} if request["action"] == 1 else {"success": True}

                self.client.start_lockdown_service = mock.AsyncMock(
                    return_value=SimpleNamespace(send_recv_plist=send))
                with mock.patch("pymobiledevice3.services.amfi.AmfiService", RealAmfiService):
                    self.assertEqual(await self.enable(), "manual")
                self.assertEqual(sent, actions)
                self.assertEqual(self.diagnostics["devmode_passcode"], passcode)
                self.assertIn(reply, self.diagnostics["devmode_enable_error"])

    async def test_log_remains_bounded_and_preserves_existing_entries(self):
        from link_timeline import append_log
        path = self.state.parent / "link-timeline.jsonl"
        for n in range(305):
            append_log(path, {"synthetic_transfer": n})
        self.outcomes = [DeviceHasPasscodeSetError()]
        await self.enable()
        self.assertEqual(len(self.logs()), 300)
        self.assertEqual(self.logs()[-2]["synthetic_transfer"], 304)
        self.assertEqual(self.logs()[-1]["event"], "devmode_enable_failed")


class SetupIntegrationTests(EnableFixture, unittest.IsolatedAsyncioTestCase):
    """Run actual auto/next/Emitter with fake USB, lockdown and AMFI edges."""
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.output = io.StringIO()
        self.entry = (self.client.udid, self.client.product_type, self.client.product_version, True)
        if hasattr(setup, "select_usb_device"):
            self.entry += ("iPhone",)
        for patcher in (mock.patch.object(setup, "emit", setup.Emitter()),
                        mock.patch.object(setup, "use_private_cache"),
                        mock.patch.object(setup, "usb_ipads", mock.AsyncMock(return_value=[self.entry])),
                        mock.patch.object(setup, "finish_pairing", mock.AsyncMock(return_value="ready")),
                        mock.patch.object(setup, "time", SimpleNamespace(monotonic=lambda: self.now)),
                        mock.patch.object(setup, "AUTO_LIMIT_SECONDS", 12)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def lines(self):
        return [json.loads(line) for line in self.output.getvalue().splitlines()]

    async def test_next_passcode_returns_existing_code_plus_new_fields(self):
        self.outcomes = [DeviceHasPasscodeSetError()]
        with contextlib.redirect_stdout(self.output):
            self.assertEqual(await setup.next_step(self.state), "developer_mode_needed")
        line = self.lines()[-1]
        self.assertEqual((line["schema_version"], line["ok"], line["final"], line["devmode_passcode"]), (1, False, True, 1))
        self.assertEqual(line["model"], self.client.product_type)
        self.assertEqual(line["ipados"], "18.7")

    async def test_next_persistent_failure_emits_reason_and_no_passcode_claim(self):
        self.outcomes = [AmfiError("AMFI busy")] * 3
        with contextlib.redirect_stdout(self.output):
            self.assertEqual(await setup.next_step(self.state), "developer_mode_needed")
        self.assertEqual(self.lines()[-1]["devmode_passcode"], 0)
        self.assertEqual(self.lines()[-1]["devmode_enable_error"], "AmfiError: AMFI busy")
        self.assertEqual(setup.lockdown_for.await_count, 3)

    async def test_next_success_keeps_existing_auto_result(self):
        with contextlib.redirect_stdout(self.output):
            self.assertEqual(await setup.next_step(self.state), "developer_mode_auto")
        self.assertNotIn("devmode_enable_error", self.lines()[-1])

    async def test_auto_reboot_then_post_restart_confirmation_then_ready(self):
        setup.usb_ipads.side_effect = [[self.entry], [], [self.entry], [self.entry]]
        with contextlib.redirect_stdout(self.output):
            self.assertEqual(await setup.auto(self.state), "ready")
        self.assertEqual([call[0] for call in self.calls], ["enable", "accept"])
        self.assertEqual([line["code"] for line in self.lines()],
                         ["developer_mode_auto", "ipad_restarting", "ready"])
        self.assertEqual([line["final"] for line in self.lines()], [False, False, True])

    async def test_auto_unlock_retry_then_reboot_confirm_and_keep_reason_in_final(self):
        self.outcomes = [PasswordRequiredError("Device locked"), None]
        self.client.gates = [PasswordRequiredError(), {}]
        setup.usb_ipads.side_effect = [[self.entry], [], [self.entry], [self.entry]]
        with contextlib.redirect_stdout(self.output):
            self.assertEqual(await setup.auto(self.state), "ready")
        self.assertEqual([line["code"] for line in self.lines()],
                         ["unlock_needed", "developer_mode_auto", "ipad_restarting", "ready"])
        self.assertEqual(self.lines()[-1]["devmode_passcode"], 0)
        self.assertIn("PasswordRequiredError", self.lines()[-1]["devmode_enable_error"])

    async def test_auto_manual_fallback_runs_once_and_timeout_keeps_diagnostics(self):
        self.outcomes = [AmfiError("Busy")] * 3
        with contextlib.redirect_stdout(self.output):
            self.assertEqual(await setup.auto(self.state), "setup_timeout")
        self.assertEqual([call[0] for call in self.calls], ["enable", "enable", "enable", "reveal"])
        self.assertEqual([line["code"] for line in self.lines()], ["developer_mode_needed", "setup_timeout"])
        self.assertEqual(self.lines()[-1]["devmode_enable_error"], "AmfiError: Busy")

    async def test_auto_permanently_locked_stops_at_setup_deadline(self):
        self.outcomes = [PasswordRequiredError()]
        self.client.gates = [PasswordRequiredError()] * 30
        with contextlib.redirect_stdout(self.output):
            self.assertEqual(await setup.auto(self.state), "setup_timeout")
        self.assertEqual([line["code"] for line in self.lines()], ["unlock_needed", "setup_timeout"])
        self.assertEqual(len(self.calls), 1)

    async def test_emitter_bounds_fields_deduplicates_and_keeps_final(self):
        emitter = setup.Emitter()
        with contextlib.redirect_stdout(self.output):
            for _ in range(2):
                emitter(False, "developer_mode_needed", final=False, devmode_passcode=0,
                        devmode_enable_error="AmfiError: Busy", udid="SECRET")
            emitter(False, "developer_mode_needed", devmode_passcode=0, devmode_enable_error="AmfiError: Busy")
            emitter(False, "developer_mode_needed", devmode_passcode=True, devmode_enable_error="x" * 201)
        self.assertEqual(len(self.lines()), 3)
        self.assertNotIn("SECRET", self.output.getvalue())
        self.assertNotIn("devmode_passcode", self.lines()[-1])
        self.assertNotIn("devmode_enable_error", self.lines()[-1])


if __name__ == "__main__":
    unittest.main()
