"""Offline generator contract tests; never fetch a changing price list in CI."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("model_prices", Path(__file__).resolve().parents[1] / "update-model-prices.py")
prices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prices)


class ModelPriceGeneratorTests(unittest.TestCase):
    def test_sources_are_scoped_and_first_party_fallback_fills_missing_ids(self):
        models = {"anthropic": {"models": {"model": {"cost": {"input": 2, "output": 10}}}},
                  "bedrock": {"models": {"wrong": {"cost": {"input": 99, "output": 99}}}}}
        lite = {
            "model": {"litellm_provider": "anthropic", "input_cost_per_token": 3e-6,
                      "output_cost_per_token": 12e-6, "cache_creation_input_token_cost_above_1hr": 4e-6},
            "gemini/missing": {"litellm_provider": "gemini", "input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6},
            "hosted/evil": {"litellm_provider": "openai", "input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6},
            "wrong": {"litellm_provider": "bedrock", "input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6},
        }
        entries = prices.build_entries(models, lite)
        self.assertEqual(entries["anthropic/model"][0]["input"], 2)
        self.assertEqual(entries["anthropic/model"][0]["cache_write_1h"], 4)
        self.assertEqual(entries["google/missing"][0]["input"], 1)
        self.assertFalse(any("wrong" in key or "evil" in key for key in entries))

    def test_tiers_override_legacy_threshold_and_get_their_own_hour_rate(self):
        models = {"openai": {"models": {"model": {"cost": {
            "input": 1, "output": 2, "cache_write_1h": 2,
            "context_over_200k": {"input": 100, "output": 200},
            "tiers": [{"tier": {"type": "context", "size": 272000}, "input": 3, "output": 4}],
        }}}}}
        base, tiers = prices.build_entries(models, {})["openai/model"]
        self.assertEqual(list(tiers), [272000])
        self.assertEqual(tiers[272000]["input"], 3)
        self.assertIsNone(tiers[272000]["cache_write_1h"])
        self.assertEqual(base["cache_write_1h"], 2)

    def test_missing_prices_are_not_free_and_explicit_zero_is_preserved(self):
        models = {"openai": {"models": {
            "missing": {"cost": {"input": 1}},
            "free": {"cost": {"input": 0, "output": 0, "cache_write_1h": 0}},
        }}}
        entries = prices.build_entries(models, {"free": {"litellm_provider": "openai",
            "input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6,
            "cache_creation_input_token_cost_above_1hr": 3e-6}})
        self.assertNotIn("openai/missing", entries)
        self.assertEqual(entries["openai/free"][0]["cache_write_1h"], 0)
        with self.assertRaises(ValueError):
            prices.rates({"input": -1})

    def test_generated_bytes_are_independent_of_input_order(self):
        models = {"openai": {"models": {key: {"cost": {"input": 1, "output": 2}} for key in ["z", "a"]}}}
        first = prices.generate(prices.build_entries(models, {}), "2026-10-28", [("source", "https://example.test", '"etag"', "hash")])
        models["openai"]["models"] = dict(reversed(list(models["openai"]["models"].items())))
        second = prices.generate(prices.build_entries(models, {}), "2026-10-28", [("source", "https://example.test", '"etag"', "hash")])
        self.assertEqual(first, second)
        self.assertIn('static let snapshotDate = "2026-10-28"', first)
        self.assertIn("SHA-256: hash", first)


if __name__ == "__main__":
    unittest.main()
