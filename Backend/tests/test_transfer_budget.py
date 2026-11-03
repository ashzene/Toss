"""Virtual-clock transfer budgets: no sleep, network, devices, or file writes."""
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from capture_timing import TransferBudget


class TransferBudgetTests(unittest.TestCase):
    def test_twelve_mb_at_two_and_three_mb_per_second(self):
        for speed in (2, 3):
            budget = TransferBudget(100)
            total = 12 * 1024 * 1024
            for tick in range(1, 161):
                now = 100 + tick * 0.05
                got = min(total, max(0, now - 100.5) * speed * 1024 * 1024)
                budget.observe(now, got)
                self.assertLess(now, budget.deadline)
                if got == total: break
            self.assertEqual(got, total)
            self.assertLess(now, 108)

    def test_no_first_byte_retains_four_and_a_half_seconds(self):
        budget = TransferBudget(0)
        for tick in range(1, 90): budget.observe(tick * 0.05, 0)
        self.assertEqual(budget.deadline, 4.5)

    def test_stalled_stream_does_not_refresh_on_repeated_progress_messages(self):
        budget = TransferBudget(0)
        budget.observe(4, 1000)
        for tick in range(1, 30): budget.observe(4 + tick * 0.05, 1000)
        self.assertEqual(budget.deadline, 5.2)

    def test_ten_second_stream_cannot_move_eight_second_hard_cap(self):
        budget = TransferBudget(0)
        for tick in range(1, 161): budget.observe(tick * 0.05, tick * 5000)
        self.assertEqual(budget.deadline, 8)

    def test_stale_progress_uses_last_packet_time(self):
        budget = TransferBudget(0)
        budget.observe(4.4, 1000, idle_ms=1500)
        self.assertEqual(budget.deadline, 4.5)

    def test_shared_budget_does_not_reset_for_fallback(self):
        budget = TransferBudget(10, hard=5)
        budget.observe(14.8, 10000)
        self.assertEqual(budget.deadline, 15)

    def test_short_configured_budget_remains_bounded(self):
        budget = TransferBudget(100, normal=0.8, hard=0.8)
        budget.observe(100.7, 40000)
        self.assertEqual(budget.deadline, 100.8)
