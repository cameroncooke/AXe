"""Offline baseline acceptance and comparison checks. No simulator or model calls."""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import baselines


def result(run_id="first", *, calls=18, seconds=215.1, tokens=6776, tool="axe"):
    contract = {key: "a" * 64 for key in baselines.HASH_FIELDS}
    contract.update({key: key + "-fixed" for key in baselines.TEXT_FIELDS})
    contract.update(screenWidth=402, screenHeight=874)
    return {
        "schema": baselines.RESULT_SCHEMA, "schemaVersion": 1,
        "runId": run_id, "scenario": "weather", "status": "passed",
        "tool": {"name": tool, "version": "1.0", "build": "100", "binarySHA256": "b" * 64},
        "contract": contract,
        "correctness": {"status": "passed", "checks": [{"id": "observed-final-fact", "status": "passed"}]},
        "metrics": {"totalCalls": calls, "elapsedSeconds": seconds, "returnedTextTokens": tokens,
                    "tokenStatus": "measured", "imageCount": 0, "imageBytes": 0},
    }


class BaselineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.registry = self.root / "baselines.json"

    def tearDown(self):
        self.directory.cleanup()

    def save(self, value, name=None):
        file = self.root / ((name or value["runId"]) + ".json")
        file.write_text(json.dumps(value), encoding="utf-8")
        return file

    def accept(self, value):
        return baselines.accept_baseline(self.registry, self.save(value))

    def test_versions_are_recorded_but_do_not_block_comparison(self):
        old, new = result(), result("new", seconds=200, tool="rocketsim")
        new["tool"].update(version="16.8", build="339", binarySHA256="c" * 64, guideSHA256="d" * 64)
        self.assertEqual(baselines.comparison_key(old), baselines.comparison_key(new))
        comparison = baselines.compare_results(new, old)
        self.assertTrue(comparison["comparable"])
        self.assertAlmostEqual(comparison["deltas"]["elapsedSeconds"]["delta"], -15.1)
        self.assertEqual(comparison["candidate"]["tool"]["version"], "16.8")

    def test_changed_contracts_are_not_ranked(self):
        for field in baselines.CONTRACT_FIELDS:
            with self.subTest(field=field):
                old, new = result(), result("new")
                if field in baselines.HASH_FIELDS:
                    new["contract"][field] = "f" * 64
                elif field in ("screenWidth", "screenHeight"):
                    new["contract"][field] = 123
                else:
                    new["contract"][field] = "different"
                report = baselines.compare_results(new, old)
                self.assertFalse(report["comparable"])
                self.assertFalse(report["contractMatches"])
                self.assertEqual(report["deltas"], {})
                self.assertEqual(report["differences"][0]["field"], "contract." + field)

    def test_additional_contract_fields_are_not_ignored(self):
        old, new = result(), result("new")
        new["contract"]["hostModel"] = "different machine"
        self.assertNotEqual(baselines.comparison_key(new), baselines.comparison_key(old))
        self.assertFalse(baselines.compare_results(new, old)["comparable"])

    def test_accept_keeps_one_real_best_run_not_best_metric_composite(self):
        self.assertEqual(self.accept(result())["status"], "promoted")
        self.assertEqual(self.accept(result("fast", seconds=200, tokens=8000))["status"], "promoted")
        self.assertEqual(self.accept(result("small", seconds=210, tokens=1000))["status"], "kept-best")
        self.assertEqual(self.accept(result("few", calls=17, seconds=250, tokens=10000))["status"], "promoted")
        registry = json.loads(self.registry.read_text())
        stored = next(iter(registry["baselines"].values()))["result"]
        self.assertEqual(stored["runId"], "few")
        self.assertEqual(stored["metrics"]["elapsedSeconds"], 250)
        self.assertEqual(stored["metrics"]["returnedTextTokens"], 10000)
        self.assertEqual(len(registry["history"]), 4)
        self.assertEqual(registry["history"][0]["tool"]["version"], "1.0")

    def test_tokens_break_exact_call_time_tie_only(self):
        self.accept(result())
        self.assertEqual(self.accept(result("lower-tokens", tokens=6000))["status"], "promoted")
        self.assertEqual(self.accept(result("equal", tokens=6000))["status"], "kept-best")

    def test_failed_or_unverified_run_never_changes_registry(self):
        self.accept(result())
        previous = self.registry.read_bytes()
        for state in ("failed", "unverified", "blocked"):
            value = result(state, calls=1)
            value["status"] = value["correctness"]["status"] = state
            value["correctness"]["checks"][0]["status"] = state
            with self.assertRaisesRegex(ValueError, "not accepted"):
                self.accept(value)
            self.assertEqual(self.registry.read_bytes(), previous)
            report = baselines.compare_registry(value, self.registry)
            self.assertTrue(report["contractMatches"])
            self.assertFalse(report["comparable"])
            self.assertEqual(report["deltas"], {})

    def test_incomplete_passing_results_cannot_be_baselines(self):
        variants = []
        value = result(); value["correctness"]["checks"] = []; variants.append(value)
        value = result(); value["correctness"]["checks"][0]["status"] = "unverified"; variants.append(value)
        value = result(); value["metrics"]["tokenStatus"] = "unavailable"; variants.append(value)
        value = result(); value["metrics"]["returnedTextTokens"] = None; variants.append(value)
        value = result(); value["tool"]["version"] = None; variants.append(value)
        value = result(); value["contract"].pop("setupPolicy"); variants.append(value)
        value = result(); value["metrics"]["elapsedSeconds"] = float("nan"); variants.append(value)
        value = result(); value["metrics"]["totalCalls"] = True; variants.append(value)
        value = result(); value["schemaVersion"] = True; variants.append(value)
        for index, value in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(ValueError):
                baselines.accept_baseline(self.registry, self.save(value, "bad" + str(index)))
        self.assertFalse(self.registry.exists())

    def test_historical_result_without_matching_setup_is_not_current_baseline(self):
        old = result("old-14-calls", calls=14, seconds=100)
        old["contract"]["setupPolicy"] = "two-setup-calls"
        self.accept(old)
        report = baselines.compare_registry(result(), self.registry)
        self.assertFalse(report["comparable"])
        self.assertEqual(report["otherContracts"][0]["differences"][0]["field"], "contract.setupPolicy")

    def test_competitors_cannot_replace_axe_baseline(self):
        with self.assertRaisesRegex(ValueError, "only AXe"):
            self.accept(result(tool="flowdeck"))
        self.assertFalse(self.registry.exists())

    def test_duplicate_run_is_idempotent_and_changed_run_id_is_rejected(self):
        value = result()
        self.accept(value)
        before = self.registry.read_bytes()
        self.assertEqual(self.accept(value)["status"], "already-recorded")
        self.assertEqual(self.registry.read_bytes(), before)
        value["metrics"]["totalCalls"] -= 1
        with self.assertRaisesRegex(ValueError, "different result bytes"):
            self.accept(value)
        self.assertEqual(self.registry.read_bytes(), before)

    def test_concurrent_accepts_preserve_history_and_best(self):
        files = [self.save(result("parallel-" + str(n), calls=20 - n)) for n in range(4)]
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda file: baselines.accept_baseline(self.registry, file), files))
        registry = json.loads(self.registry.read_text())
        self.assertEqual(len(registry["history"]), 4)
        self.assertEqual(next(iter(registry["baselines"].values()))["result"]["runId"], "parallel-3")

    def test_duplicate_checks_and_changed_registry_are_rejected(self):
        value = result()
        value["correctness"]["checks"] *= 2
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            baselines.validate_result(value)
        self.accept(result())
        data = json.loads(self.registry.read_text())
        next(iter(data["baselines"].values()))["result"]["contract"]["screenWidth"] = 1000
        self.registry.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "Invalid accepted baseline"):
            baselines.compare_registry(result(), self.registry)

    def test_incomplete_blocked_run_is_reported_without_comparison(self):
        value = result()
        value.update(status="blocked", contract={})
        value["correctness"] = {"status": "unverified", "checks": []}
        value["metrics"] = {"tokenStatus": "unavailable"}
        value["tool"]["version"] = None
        report = baselines.compare_registry(value, self.registry)
        self.assertFalse(report["comparable"])
        self.assertIn("Incomplete comparison contract", report["reason"])

    def test_modified_baseline_metrics_are_detected(self):
        self.accept(result())
        data = json.loads(self.registry.read_text())
        next(iter(data["baselines"].values()))["result"]["metrics"]["totalCalls"] = 1
        self.registry.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "Invalid accepted baseline"):
            baselines.compare_registry(result(), self.registry)

    def test_symlink_registry_is_rejected_without_touching_target(self):
        target = self.root / "untouched.json"
        target.write_text("original")
        self.registry.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.accept(result())
        self.assertEqual(target.read_text(), "original")

    def test_retained_report_pointer_is_relative_without_changing_result_or_hashes(self):
        value = result()
        retained = self.root / 'history' / value['runId'] / 'report.json'
        retained.parent.mkdir(parents=True)
        raw = (json.dumps(value, indent=3) + '\n\n').encode()
        retained.write_bytes(raw)
        baselines.accept_baseline(self.registry, retained)
        registry = json.loads(self.registry.read_text())
        entry = next(iter(registry['baselines'].values()))
        self.assertEqual(entry['resultPath'], 'history/first/report.json')
        self.assertEqual(registry['history'][0]['resultPath'], entry['resultPath'])
        self.assertEqual(entry['result'], value)
        self.assertEqual(entry['resultSHA256'], hashlib.sha256(raw).hexdigest())
        self.assertEqual(entry['resultContentSHA256'], hashlib.sha256(baselines._json_bytes(value)).hexdigest())
        self.assertEqual(retained.read_bytes(), raw)

    def test_external_report_pointer_stays_absolute(self):
        source = self.save(result())
        registry_path = self.root / 'separate' / 'baselines.json'
        baselines.accept_baseline(registry_path, source)
        registry = json.loads(registry_path.read_text())
        self.assertEqual(next(iter(registry['baselines'].values()))['resultPath'], str(source.resolve()))
        self.assertEqual(registry['history'][0]['resultPath'], str(source.resolve()))


if __name__ == "__main__":
    unittest.main()
