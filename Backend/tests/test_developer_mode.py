"""Synthetic AMFI/lockdown only. No USB inventory, network, devices or UI."""
import asyncio
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
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
        for name in ("Ashley's iPhone", "Ａｓｈｌｅｙ的手机", "Cafe\u0301 iPad", "Ａ"):
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
        self.reveal_hook = None
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
                if owner.reveal_hook:
                    owner.reveal_hook()
                if owner.reveal_error:
                    raise owner.reveal_error

            async def enable_developer_mode_post_restart(self):
                owner.calls.append(("accept", owner.now))
                owner.client.status = True

        real_sleep = asyncio.sleep

        async def sleep(seconds):
            self.sleeps.append(seconds)
            self.now += seconds
            await real_sleep(0)

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


class RevealTests(EnableFixture, unittest.IsolatedAsyncioTestCase):
    async def test_return_value_and_changed_errors_only(self):
        failures = dm.RevealFailures()
        self.assertTrue(await dm.reveal(self.client, state=self.state, failures=failures))
        for message in ["one", "one", "two", "two"]:
            self.reveal_error = AmfiError(message)
            self.assertFalse(await dm.reveal(self.client, state=self.state, failures=failures))
        self.assertEqual([line["devmode_reveal_error"] for line in self.logs()], ["AmfiError: one", "AmfiError: two"])
        self.assertEqual(self.diagnostics, {})

    async def test_first_answer_is_logged_once_per_run(self):
        repeater = dm.RevealRepeater(self.state)
        for _ in range(2):
            self.assertTrue(await repeater.first(self.client))
        self.assertEqual([line["event"] for line in self.logs()], ["devmode_reveal_ok"])

    async def test_slow_reveal_never_blocks_tick_or_overlaps_and_is_cancelled(self):
        repeater = dm.RevealRepeater(self.state)
        gate = asyncio.Event()
        async def blocked():
            await gate.wait()
        # Use a blocked reconnect instead, to exercise the entire timeout scope.
        factory = mock.AsyncMock(side_effect=blocked)
        repeater.tick(factory)
        await asyncio.sleep(0)
        first = repeater.task
        for _ in range(5):
            self.now += 3
            repeater.tick(factory)
            self.assertIs(repeater.task, first)
        await repeater.close()
        self.assertTrue(first.cancelled())
        self.assertEqual(factory.await_count, 1)

    async def test_request_timeout_is_logged_and_retries(self):
        repeater = dm.RevealRepeater(self.state)
        async def blocked():
            await asyncio.Event().wait()
        with mock.patch.object(dm, "REQUEST_TIMEOUT", 0.005):
            repeater.tick(blocked)
            await repeater.task
        self.assertIn("TimeoutError", self.logs()[-1]["devmode_reveal_error"])
        self.now = 3
        repeater.tick(mock.AsyncMock(return_value=self.client))
        await repeater.task
        self.assertEqual([call[0] for call in self.calls], ["reveal"])
        await repeater.close()


class ParentWatchTests(unittest.TestCase):
    PARENT = ("import subprocess, sys; p = subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]], "
              "stdout=subprocess.PIPE, text=True); print(p.stdout.readline().strip(), flush=True)")

    def assert_child_ends_with_parent(self, child):
        """Real processes: the parent exits once the child has printed its pid."""
        backend = str(Path(setup.__file__).parent)
        result = subprocess.run([sys.executable, "-c", self.PARENT, child, backend], capture_output=True, text=True, timeout=30)
        pid = int(result.stdout.strip())
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        os.kill(pid, signal.SIGKILL)
        self.fail("setup process outlived its parent")

    def test_setup_process_ends_with_its_parent(self):
        self.assert_child_ends_with_parent(
            "import os, sys, time; sys.path.insert(0, sys.argv[1]); import setup_device as s; "
            "s.exit_with_parent(poll_seconds=0.05); print(os.getpid(), flush=True); time.sleep(30)")

    def test_setup_process_ends_if_parent_left_before_the_watch_started(self):
        self.assert_child_ends_with_parent(
            "import os, sys, time; sys.path.insert(0, sys.argv[1]); import setup_device as s; "
            "print(os.getpid(), flush=True); time.sleep(1); s.exit_with_parent(poll_seconds=0.05); time.sleep(30)")


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
        self.assertEqual([call[0] for call in self.calls], ["enable", "reveal"])
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

    async def test_auto_enable_runs_once_reveal_repeats_and_timeout_keeps_diagnostics(self):
        self.outcomes = [AmfiError("Busy")] * 3
        with contextlib.redirect_stdout(self.output):
            self.assertEqual(await setup.auto(self.state), "setup_timeout")
        self.assertEqual([call[0] for call in self.calls].count("enable"), 3)
        reveals = [call[1] for call in self.calls if call[0] == "reveal"]
        self.assertGreaterEqual(len(reveals), 2)
        # The first reveal is awaited inside enable; the repeats run every 3 s after it.
        self.assertLessEqual(reveals[1] - reveals[0], 4.5)
        self.assertTrue(all(b - a == 3 for a, b in zip(reveals[1:], reveals[2:])))
        self.assertEqual([line["code"] for line in self.lines()], ["developer_mode_needed", "setup_timeout"])
        self.assertEqual(self.lines()[-1]["devmode_enable_error"], "AmfiError: Busy")

    async def test_auto_guide_says_look_only_after_the_first_reveal_answered(self):
        self.outcomes = [DeviceHasPasscodeSetError()]
        seen = []
        self.reveal_hook = lambda: seen.append(self.output.getvalue())
        with contextlib.redirect_stdout(self.output):
            await setup.auto(self.state)
        self.assertNotIn("developer_mode_needed", seen[0])
        self.assertIn("developer_mode_needed", self.output.getvalue())

    async def test_auto_permanently_locked_stops_at_setup_deadline(self):
        self.outcomes = [PasswordRequiredError()]
        self.client.gates = [PasswordRequiredError()] * 30
        with contextlib.redirect_stdout(self.output):
            self.assertEqual(await setup.auto(self.state), "setup_timeout")
        self.assertEqual([line["code"] for line in self.lines()], ["unlock_needed", "setup_timeout"])
        self.assertEqual(len(self.calls), 1)

    async def run_manual_reconnect(self, absence, *, enabled_after=None, accept_success=False,
                                   locked_after_return=0):
        self.outcomes = [DeviceHasPasscodeSetError()]
        disappeared = 1.5
        returned = disappeared + absence
        observations = []
        emitter = setup.Emitter()
        def progress(ok, code, **fields):
            observations.append((self.now, code))
            emitter(ok, code, **fields)
        async def devices(_):
            return [] if disappeared <= self.now < returned else [self.entry]
        async def connect(*_):
            if returned <= self.now < returned + locked_after_return:
                raise ConnectionError("locked")
            if enabled_after is not None and self.now >= returned + enabled_after:
                self.client.status = True
            return self.client
        setup.usb_ipads.side_effect = devices
        setup.lockdown_for.side_effect = connect
        with mock.patch.object(setup, "emit", progress), \
             mock.patch.object(setup, "try_accept_developer_mode", mock.AsyncMock(return_value=accept_success)) as accept, \
             mock.patch.object(setup, "AUTO_LIMIT_SECONDS", returned + 99), contextlib.redirect_stdout(self.output):
            result = await setup.auto(self.state)
        return returned, observations, accept.await_count, result

    async def test_three_second_replug_never_confirms_and_keeps_revealing(self):
        returned, events, accepts, _ = await self.run_manual_reconnect(3)
        self.assertEqual(accepts, 0)
        self.assertNotIn("developer_mode_confirm", [code for _, code in events])
        self.assertIn((returned, "developer_mode_needed"), events)
        self.assertTrue(any(call[0] == "reveal" and call[1] >= returned for call in self.calls))

    async def test_thirty_second_restart_holds_confirm_for_ninety_seconds(self):
        returned, events, accepts, _ = await self.run_manual_reconnect(30)
        self.assertEqual(accepts, 5)
        waiting = [(t, code) for t, code in events if returned <= t < returned + 90]
        self.assertTrue(waiting)
        self.assertTrue(all(code == "developer_mode_confirm" for _, code in waiting))
        self.assertIn((returned + 90, "developer_mode_needed"), events)
        reveals = [call[1] for call in self.calls if call[0] == "reveal"]
        self.assertTrue(any(returned <= t < returned + 90 for t in reveals))
        self.assertTrue(any(t >= returned + 90 for t in reveals))

    async def test_accept_success_without_status_change_does_not_shorten_confirm(self):
        returned, events, accepts, _ = await self.run_manual_reconnect(30, accept_success=True)
        self.assertEqual(accepts, 5)
        self.assertFalse(any(code == "developer_mode_needed" and returned <= t < returned + 90
                             for t, code in events))
        self.assertIn((returned + 90, "developer_mode_needed"), events)

    async def test_developer_mode_enabled_during_confirm_finishes_pairing(self):
        returned, events, accepts, result = await self.run_manual_reconnect(30, enabled_after=21)
        self.assertEqual(result, "ready")
        self.assertEqual(accepts, 5)
        self.assertIn((returned + 21, "ready"), events)
        setup.finish_pairing.assert_awaited_once()
        self.assertFalse(any(code == "developer_mode_needed" and t >= returned for t, code in events))

    async def test_exact_fifteen_seconds_counts_as_restart(self):
        returned, events, accepts, _ = await self.run_manual_reconnect(15)
        self.assertEqual(accepts, 5)
        self.assertIn((returned, "developer_mode_confirm"), events)

    async def test_confirm_deadline_starts_at_usb_return_before_unlock(self):
        returned, events, accepts, _ = await self.run_manual_reconnect(30, locked_after_return=30)
        self.assertEqual(accepts, 5)
        self.assertIn((returned + 30, "developer_mode_confirm"), events)
        self.assertIn((returned + 90, "developer_mode_needed"), events)

    async def test_reveal_failure_is_redacted_deduplicated_and_enable_reason_kept(self):
        self.outcomes = [DeviceHasPasscodeSetError()]
        self.reveal_error = AmfiError("failed " + self.client.udid + "; DeviceName=" + json.dumps(self.client.all_values["DeviceName"]))
        with contextlib.redirect_stdout(self.output):
            await setup.auto(self.state)
        failures = [line for line in self.logs() if line["event"] == "devmode_reveal_failed"]
        self.assertEqual(len(failures), 1)
        self.assertNotIn(self.client.udid, failures[0]["devmode_reveal_error"])
        self.assertNotIn(self.client.all_values["DeviceName"], failures[0]["devmode_reveal_error"])
        self.assertIn("DeviceHasPasscodeSetError", self.lines()[-1]["devmode_enable_error"])

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
