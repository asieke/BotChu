#!/usr/bin/env python3
"""Generate the offline Swift price table. Python standard library only.

Network refresh: scripts/update-model-prices.py --date YYYY-MM-DD
Reproduce saved inputs: add --models-dev FILE --litellm FILE (and optional ETags).
The date is explicit so identical inputs always produce identical output. Source content
hashes are recorded even when a local snapshot has no HTTP ETag. No runtime fetch exists.
"""
import argparse
from datetime import date
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
from urllib.request import Request, urlopen

MODELS_URL = "https://models.dev/api.json"
LITELLM_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
SAIL_URL = "https://docs.sailresearch.com/pricing"
SAIL_VERIFIED = "2026-10-29"
# Hand-maintained USD/MTok (input, cached input, output), by completion window.
# Sail guarantees a 30-minute write in its input price; no separate write surcharge.
SAIL_FLEX = {
    "moonshotai/Kimi-K3": ("0.70", "0.10", "6"),
    "zai-org/GLM-5.3": ("0.40", "0.08", "1.80"),
    "zai-org/GLM-5.3-Flash": ("0.05", "0.01", "0.18"),
    "deepseek-ai/DeepSeek-V4.1-Flash-1017": ("0.05", "0.004", "0.15"),
    "deepseek-ai/DeepSeek-V4.1-Flash": ("0.05", "0.004", "0.15"),
    "deepseek-ai/DeepSeek-V4-Pro-0813": ("0.46", "0.02", "1.39"),
    "deepseek-ai/DeepSeek-V4-Flash-0731": ("0.05", "0.01", "0.09"),
    "moonshotai/Kimi-K2.6": ("0.35", "0.10", "2"),
    "google/gemma-4-31B-it": ("0.06", "0.02", "0.30"),
    "nvidia/Gemma-4-31B-IT-NVFP4": ("0.07", "0.04", "0.20"),
    "google/gemma-4-12B-it": ("0.05", "0.02", "1"),
    "Qwen/Qwen3.6-35B-A3B": ("0.05", "0.02", "0.40"),
}
SAIL_ASAP = {
    "moonshotai/Kimi-K3": ("1.50", "0.20", "10.00"),
    "zai-org/GLM-5.3": ("0.98", "0.18", "3.08"),
    "zai-org/GLM-5.3-Flash": ("0.11", "0.02", "0.35"),
    "deepseek-ai/DeepSeek-V4.1-Flash-1017": ("0.09", "0.006", "0.30"),
    "deepseek-ai/DeepSeek-V4-Pro-0813": ("0.92", "0.04", "2.77"),
    "deepseek-ai/DeepSeek-V4-Flash-0731": ("0.09", "0.02", "0.18"),
    "google/gemma-4-31B-it": ("0.40", "0.20", "0.60"),
    "nvidia/Gemma-4-31B-IT-NVFP4": ("0.14", "0.07", "0.40"),
    "google/gemma-4-12B-it": ("0.30", "0.15", "2.00"),
}
SAIL_BALANCED = {
    "moonshotai/Kimi-K3": ("1.20", "0.15", "8.00"),
    "zai-org/GLM-5.3": ("0.50", "0.12", "2.50"),
    "zai-org/GLM-5.3-Flash": ("0.08", "0.02", "0.28"),
    "deepseek-ai/DeepSeek-V4.1-Flash-1017": ("0.07", "0.005", "0.22"),
    "deepseek-ai/DeepSeek-V4-Pro-0813": ("0.74", "0.03", "2.22"),
    "deepseek-ai/DeepSeek-V4-Flash-0731": ("0.07", "0.02", "0.14"),
    "google/gemma-4-31B-it": ("0.12", "0.08", "0.60"),
    "nvidia/Gemma-4-31B-IT-NVFP4": ("0.11", "0.06", "0.32"),
    "google/gemma-4-12B-it": ("0.10", "0.07", "2.00"),
}
FIELDS = ("input", "output", "cache_read", "cache_write", "cache_write_1h")
LITE_FIELDS = ("input_cost_per_token", "output_cost_per_token", "cache_read_input_token_cost",
               "cache_creation_input_token_cost", "cache_creation_input_token_cost_above_1hr")


def read_source(path, url, etag):
    if path:
        data = Path(path).read_bytes()
    else:
        with urlopen(Request(url, headers={"User-Agent": "BotChu-price-generator"}), timeout=60) as response:
            data = response.read()
            etag = response.headers.get("ETag", "")
    return json.loads(data, parse_float=Decimal), etag, hashlib.sha256(data).hexdigest()


def rate(value):
    if value is None:
        return None
    if isinstance(value, bool):
        raise ValueError("Boolean token rate")
    value = Decimal(str(value))
    if not value.is_finite() or value < 0:
        raise ValueError(f"Invalid token rate: {value}")
    return value


def rates(cost):
    return {key: rate(cost.get(key)) for key in FIELDS}


def complete(cost):
    return cost.get("input") is not None and cost.get("output") is not None


def lite_rates(entry, suffix=""):
    return {key: None if entry.get(field + suffix) is None else rate(entry[field + suffix]) * 1_000_000
            for key, field in zip(FIELDS, LITE_FIELDS)}


def lite_models(data):
    result = {}
    for model, entry in sorted(data.items()):
        provider = {"anthropic": "anthropic", "openai": "openai", "gemini": "google"}.get(entry.get("litellm_provider"))
        if not provider or entry.get("mode", "chat") not in ("chat", "completion"):
            continue
        # Reject hosted/region deployments even if their metadata names a first-party provider.
        prefix = "gemini" if provider == "google" else provider
        model = model.removeprefix(prefix + "/")
        if "/" in model:
            continue
        base = lite_rates(entry)
        if not complete(base):
            continue
        tiers = {}
        for field in entry:
            match = re.fullmatch(r"input_cost_per_token_above_(\d+)k_tokens", field)
            if match:
                threshold = int(match[1]) * 1000
                tier = {**base, **{k: v for k, v in lite_rates(entry, f"_above_{match[1]}k_tokens").items() if v is not None}}
                # The base 1h rate does not apply above a context threshold.
                tier["cache_write_1h"] = lite_rates(entry, f"_above_{match[1]}k_tokens")["cache_write_1h"]
                tiers[threshold] = tier
        result[provider + "/" + model] = (base, tiers)
    return result


def build_entries(models, litellm):
    fallback = lite_models(litellm)
    result = {}
    for provider in ("anthropic", "openai", "google", "openrouter"):
        for model, entry in sorted(models.get(provider, {}).get("models", {}).items()):
            if "text" not in entry.get("modalities", {}).get("output", ["text"]):
                continue
            cost = entry.get("cost", {})
            base = rates(cost)
            if not complete(base):
                continue
            key = provider + "/" + model
            supplement, supplement_tiers = fallback.get(key, ({}, {}))
            if base["cache_write_1h"] is None:
                base["cache_write_1h"] = supplement.get("cache_write_1h")
            tiers = {}
            source_tiers = cost.get("tiers", [])
            # Legacy models.dev snapshots have only this field. Explicit tiers take precedence:
            # the legacy field's name can be misleading for the actual 272k threshold.
            if not source_tiers and "context_over_200k" in cost:
                source_tiers = [{**cost["context_over_200k"], "tier": {"type": "context", "size": 200000}}]
            for tier in source_tiers:
                spec = tier.get("tier", {})
                if spec.get("type") != "context":
                    continue
                threshold = spec["size"]
                if not isinstance(threshold, int) or threshold < 0:
                    raise ValueError(f"Invalid context threshold for {key}")
                merged = {**base, **{k: v for k, v in rates(tier).items() if v is not None}}
                merged["cache_write_1h"] = rate(tier.get("cache_write_1h"))
                if merged["cache_write_1h"] is None:
                    merged["cache_write_1h"] = supplement_tiers.get(threshold, {}).get("cache_write_1h")
                tiers[threshold] = merged
            result[key] = (base, tiers)
    for key, value in fallback.items():
        result.setdefault(key, value)
    for source, table in [("sail", SAIL_FLEX), ("sail-asap", SAIL_ASAP), ("sail-balanced", SAIL_BALANCED)]:
        for model, (input_price, cache_price, output_price) in table.items():
            result[source + "/" + model] = (rates({"input": input_price, "output": output_price,
                                                 "cache_read": cache_price, "cache_write": input_price}), {})
    return result


def swift_rates(values):
    def number(value):
        return "nil" if value is None else format(value.normalize(), "f")
    return ".init(" + ", ".join(number(values[key]) for key in FIELDS) + ")"


def generate(entries, snapshot_date, sources):
    lines = ["// Generated by scripts/update-model-prices.py; do not edit.",
             f"// Snapshot: {snapshot_date}. Rates are USD per million tokens."]
    for name, url, etag, digest in sources:
        lines += [f"// {name}: {url}", f"// ETag: {json.dumps(etag or 'unavailable')} SHA-256: {digest}"]
    lines += [f"// Sail completion windows: {SAIL_URL} (manually verified {SAIL_VERIFIED}).", "", "enum ModelPrices {",
              f'    static let snapshotDate = "{snapshot_date}"', "    static let entries: [String: ModelPrice] = ["]
    for key, (base, tiers) in sorted(entries.items()):
        literal = ".init(" + swift_rates(base)
        if tiers:
            literal += ", tiers: [" + ", ".join(f".init(aboveInput: {size}, rates: {swift_rates(values)})" for size, values in sorted(tiers.items())) + "]"
        lines.append(f"        {json.dumps(key)}: {literal}),")
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--date", required=True, type=lambda value: date.fromisoformat(value).isoformat())
    parser.add_argument("--models-dev", type=Path)
    parser.add_argument("--litellm", type=Path)
    parser.add_argument("--models-dev-etag", default="")
    parser.add_argument("--litellm-etag", default="")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "macOS/Sources/BotChuCore/ModelPrices.generated.swift")
    args = parser.parse_args()
    models, models_etag, models_hash = read_source(args.models_dev, MODELS_URL, args.models_dev_etag)
    lite, lite_etag, lite_hash = read_source(args.litellm, LITELLM_URL, args.litellm_etag)
    entries = build_entries(models, lite)
    if not entries:
        raise ValueError("Source lists contain no supported token prices")
    sources = [("models.dev", MODELS_URL, models_etag, models_hash), ("LiteLLM", LITELLM_URL, lite_etag, lite_hash)]
    args.output.write_text(generate(entries, args.date, sources))
    print(f"Wrote {len(entries)} prices to {args.output}")


if __name__ == "__main__":
    main()
