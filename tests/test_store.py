"""Tests for the SQLite store behind classes, settings and scan history."""

import unittest

from datalink_scanner.store import Store


def roster(*pairs):
    return [{"id": student_id, "name": name} for student_id, name in pairs]


class ClassTests(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)

    def test_round_trip_preserves_roster_order(self):
        # Order matters: the workspace walks the roster in it.
        self.store.save_class("Period 4", roster(("900003", "C"), ("900001", "A")))
        saved = self.store.get_class("Period 4")
        self.assertEqual([s["id"] for s in saved["students"]], ["900003", "900001"])

    def test_saving_again_replaces_the_roster(self):
        self.store.save_class("P4", roster(("900001", "A"), ("900002", "B")))
        self.store.save_class("P4", roster(("900003", "C")))
        self.assertEqual(len(self.store.get_class("P4")["students"]), 1)

    def test_rename_keeps_the_students(self):
        self.store.save_class("Old", roster(("900001", "A")))
        self.store.save_class("New", roster(("900001", "A")), original_name="Old")
        self.assertIsNone(self.store.get_class("Old"))
        self.assertEqual(len(self.store.get_class("New")["students"]), 1)

    def test_duplicate_name_is_rejected(self):
        self.store.save_class("P4", roster(("900001", "A")))
        with self.assertRaises(ValueError):
            self.store.save_class("p4", roster(("900002", "B")))

    def test_rejects_duplicate_student_ids(self):
        with self.assertRaises(ValueError):
            self.store.save_class("P4", roster(("900001", "A"), ("900001", "B")))

    def test_rejects_non_numeric_or_nameless_students(self):
        with self.assertRaises(ValueError):
            self.store.save_class("P4", roster(("abc", "A")))
        with self.assertRaises(ValueError):
            self.store.save_class("P4", roster(("900001", "")))

    def test_rejects_blank_class_name(self):
        with self.assertRaises(ValueError):
            self.store.save_class("   ", roster(("900001", "A")))

    def test_delete_removes_students_too(self):
        self.store.save_class("P4", roster(("900001", "A")))
        self.store.delete_class("P4")
        self.assertEqual(self.store.list_classes(), [])
        with self.store._lock:
            remaining = self.store._connection.execute(
                "SELECT COUNT(*) AS n FROM students"
            ).fetchone()["n"]
        self.assertEqual(remaining, 0)

    def test_classes_are_listed_alphabetically(self):
        for name in ("Zoology", "algebra", "Biology"):
            self.store.save_class(name, [])
        self.assertEqual(
            [item["name"] for item in self.store.list_classes()],
            ["algebra", "Biology", "Zoology"],
        )


class SettingTests(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)

    def test_missing_key_returns_the_default(self):
        self.assertEqual(self.store.get_setting("nope", "fallback"), "fallback")

    def test_set_then_get(self):
        self.store.set_setting("test_name", "Unit 1")
        self.assertEqual(self.store.get_setting("test_name"), "Unit 1")

    def test_set_overwrites(self):
        self.store.set_setting("k", "one")
        self.store.set_setting("k", "two")
        self.assertEqual(self.store.get_setting("k"), "two")


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)

    def scan(self, number, **overrides):
        payload = {
            "number": number,
            "role": "key" if number == 1 else "student",
            "student_id": None if number == 1 else f"90000{number}",
            "student_name": None if number == 1 else f"Student {number}",
            "received_at": "2026-09-16T18:21:52+00:00",
            "answered_count": 30,
            "responses": ["A"] * 30,
        }
        payload.update(overrides)
        return payload

    def test_scans_round_trip_with_responses_intact(self):
        session_id = self.store.create_session("Unit 1", "P4", 30)
        self.store.add_scan(session_id, self.scan(1))
        self.store.add_scan(session_id, self.scan(2))
        scans = self.store.session_scans(session_id)
        self.assertEqual(len(scans), 2)
        self.assertEqual(scans[0]["responses"], ["A"] * 30)
        self.assertEqual(scans[1]["student_id"], "900002")

    def test_listing_counts_scans_and_is_newest_first(self):
        first = self.store.create_session("Older", "", 30)
        self.store.add_scan(first, self.scan(1))
        second = self.store.create_session("Newer", "", 50)
        for number in (1, 2, 3):
            self.store.add_scan(second, self.scan(number))
        listed = self.store.list_sessions()
        self.assertEqual([item["name"] for item in listed], ["Newer", "Older"])
        self.assertEqual(listed[0]["scan_count"], 3)

    def test_deleting_a_session_removes_its_scans(self):
        session_id = self.store.create_session("Gone", "", 30)
        self.store.add_scan(session_id, self.scan(1))
        self.store.delete_session(session_id)
        self.assertEqual(self.store.session_scans(session_id), [])
        self.assertIsNone(self.store.session(session_id))

    def test_update_renames_and_finishes(self):
        session_id = self.store.create_session("", "", 30)
        self.store.update_session(session_id, name="Unit 2", class_name="P5")
        self.store.update_session(session_id, finished=True)
        session = self.store.session(session_id)
        self.assertEqual(session["name"], "Unit 2")
        self.assertEqual(session["class_name"], "P5")
        self.assertIsNotNone(session["ended_at"])

    def test_empty_sessions_are_pruned_but_used_ones_are_kept(self):
        # Connecting to test the scanner should not litter the history.
        empty = self.store.create_session("Just connected", "", 30)
        used = self.store.create_session("Real", "", 30)
        self.store.add_scan(used, self.scan(1))
        self.assertEqual(self.store.prune_empty_sessions(), 1)
        self.assertIsNone(self.store.session(empty))
        self.assertIsNotNone(self.store.session(used))

    def test_demo_flag_survives(self):
        session_id = self.store.create_session("", "", 30)
        self.store.add_scan(session_id, self.scan(1, demo=True))
        self.assertTrue(self.store.session_scans(session_id)[0]["demo"])


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)

    def test_imports_only_unknown_classes(self):
        self.store.save_class("P4", roster(("900001", "Kept")))
        imported = self.store.import_classes(
            [
                {"name": "P4", "students": [{"id": "900002", "name": "Clobber"}]},
                {"name": "P5", "students": [{"id": "900003", "name": "New"}]},
            ]
        )
        self.assertEqual(imported, ["P5"])
        self.assertEqual(self.store.get_class("P4")["students"][0]["name"], "Kept")

    def test_is_idempotent(self):
        payload = [{"name": "P5", "students": [{"id": "900003", "name": "New"}]}]
        self.assertEqual(self.store.import_classes(payload), ["P5"])
        self.assertEqual(self.store.import_classes(payload), [])

    def test_skips_invalid_rosters_without_failing_the_batch(self):
        imported = self.store.import_classes(
            [
                {"name": "Bad", "students": [{"id": "not-a-number", "name": "X"}]},
                {"name": "Good", "students": [{"id": "900004", "name": "Y"}]},
            ]
        )
        self.assertEqual(imported, ["Good"])


if __name__ == "__main__":
    unittest.main()
