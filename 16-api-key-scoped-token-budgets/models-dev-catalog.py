#!/usr/bin/env python3
"""Convert the models.dev pricing feed into an AgentGateway model cost catalog.

The v1.5.0 image ships /base-costs.json, but it is a curated subset — it has
gpt-4.1 and gpt-4.1-mini and no gpt-4.1-nano, so a USD budget on this demo's
model charged 0.00 forever. Layering a models.dev-derived catalog on top of the
shipped one fills those gaps.

Source is https://models.dev/api.json (provider-nested, carries `cost`).
NOT https://models.dev/models.json — that feed is the flat canonical model list
and has no pricing at all.

    curl -fsSL https://models.dev/api.json -o api.json
    python3 models-dev-catalog.py api.json > model-catalog.json

Output matches the `Catalog` type in https://agentgateway.dev/schema/config:

    providers.<agw provider>.models.<model id>.rates.{input,output,cacheRead,
        cacheWrite,reasoning,inputAudio,outputAudio}   # Money, per 1M tokens
    providers.<agw provider>.models.<model id>.tiers[].{contextOver,rates}

Rates are strings (schema type `Money`). Two things the gateway rejects, and
that a naive float-to-string conversion walks straight into:

  * more than 6 fractional digits — models.dev carries IEEE-754 noise such as
    0.049999999999999996, so every rate is rounded to 6 places;
  * scientific notation — "1E-7" is not a decimal, so Decimal formatting with
    "f" is used rather than str()/repr().

One invalid rate rejects the whole file, and with it every other catalog entry:
"model catalog load failed; will load when the files become valid".
"""
import json
import sys
from decimal import ROUND_HALF_UP, Decimal

# models.dev provider id -> provider key AgentGateway looks a model up under.
# Keys are the ones the shipped /base-costs.json uses; a provider absent from
# that list is dropped, because the gateway would never query it.
PROVIDERS = {
    "openai": "openai",
    "anthropic": "anthropic",
    "azure": "azure",
    "google": "gcp.gemini",
    "google-vertex": "gcp.vertex_ai",
    "amazon-bedrock": "aws.bedrock",
    "github-copilot": "copilot",
    "fireworks-ai": "fireworks",
    "togetherai": "togetherai",
    "openrouter": "openrouter",
    "groq": "groq",
    "deepseek": "deepseek",
    "mistral": "mistral",
    "cohere": "cohere",
    "xai": "xai",
    "cerebras": "cerebras",
    "baseten": "baseten",
    "deepinfra": "deepinfra",
    "huggingface": "huggingface",
}

# models.dev cost key -> AgentGateway Rates field.
RATES = {
    "input": "input",
    "output": "output",
    "cache_read": "cacheRead",
    "cache_write": "cacheWrite",
    "reasoning": "reasoning",
    "input_audio": "inputAudio",
    "output_audio": "outputAudio",
}


# Largest precision the gateway's Money parser accepts.
QUANTUM = Decimal("0.000001")


def money(value):
    """models.dev number -> a Money string: plain decimal, <= 6 places."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    exact = Decimal(str(value))
    rounded = exact.quantize(QUANTUM, rounding=ROUND_HALF_UP)
    # A price too small to express at 6 places would otherwise read as free,
    # which silently zeroes a USD budget. Floor it at one quantum instead.
    if rounded == 0 and exact > 0:
        rounded = QUANTUM
    text = format(rounded, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def rates(cost):
    out = {}
    for src, dst in RATES.items():
        m = money(cost.get(src))
        if m is not None:
            out[dst] = m
    return out


def tiers(cost):
    """models.dev cost.tiers[] -> AgentGateway tiers[]; context tiers only."""
    out = []
    for tier in cost.get("tiers") or []:
        if not isinstance(tier, dict):
            continue
        spec = tier.get("tier") or {}
        if spec.get("type") != "context":
            continue
        size = spec.get("size")
        tier_rates = rates(tier)
        if isinstance(size, int) and tier_rates:
            out.append({"contextOver": size, "rates": tier_rates})
    out.sort(key=lambda t: t["contextOver"])
    return out


def convert(feed):
    providers, models = {}, 0
    for md_id, agw_id in PROVIDERS.items():
        provider = feed.get(md_id)
        if not isinstance(provider, dict):
            continue
        entries = {}
        for model_id, model in (provider.get("models") or {}).items():
            cost = model.get("cost")
            if not isinstance(cost, dict):
                continue
            base = rates(cost)
            if not base:
                continue
            entry = {"rates": base}
            tiered = tiers(cost)
            if tiered:
                entry["tiers"] = tiered
            entries[model_id] = entry
        if entries:
            providers[agw_id] = {"models": entries}
            models += len(entries)
    return {"providers": providers}, models


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as handle:
        feed = json.load(handle)
    if not isinstance(feed, dict) or "openai" not in feed:
        print(
            "error: %s does not look like https://models.dev/api.json "
            "(expected a provider-keyed object)" % argv[1],
            file=sys.stderr,
        )
        return 1
    catalog, models = convert(feed)
    if not models:
        print("error: no priced models found in %s" % argv[1], file=sys.stderr)
        return 1
    json.dump(catalog, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    print(
        "models.dev catalog: %d providers, %d priced models"
        % (len(catalog["providers"]), models),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
