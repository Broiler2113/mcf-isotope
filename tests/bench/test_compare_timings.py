import copy
import unittest

from compare_timings import compare


class TimingComparisonTests(unittest.TestCase):
    def setUp(self):
        self.baseline = {"machine": {"cpu": "test", "os": "test"}, "scenes": {
            "giant": {"config": {"units": 200}, "runs": [
                {"sig": "unchanged", "t_fog": 100.0, "t_ai": 500.0},
                {"sig": "unchanged", "t_fog": 110.0, "t_ai": 510.0},
            ]}}}

    def test_relative_warning(self):
        current = copy.deepcopy(self.baseline)
        for run in current["scenes"]["giant"]["runs"]:
            run["t_fog"] *= 2
        warnings = compare(self.baseline, current)
        self.assertEqual(len(warnings), 1)
        self.assertIn("t_fog", warnings[0])

    def test_same_machine_and_workload_required(self):
        for key in ("machine", "config", "sig"):
            current = copy.deepcopy(self.baseline)
            if key == "machine":
                current["machine"]["cpu"] = "another machine"
            elif key == "config":
                current["scenes"]["giant"]["config"]["units"] = 12
            else:
                current["scenes"]["giant"]["runs"][0]["sig"] = "changed"
            with self.assertRaises(ValueError):
                compare(self.baseline, current)

    def test_stable_timings(self):
        self.assertEqual(compare(self.baseline, self.baseline), [])


if __name__ == "__main__":
    unittest.main()
