#!/usr/bin/env python3
"""Resolve a component recipe with optional parent inheritance."""

import json
import sys
from pathlib import Path


def fail(message):
    raise ValueError(message)


def apply_entries(entries, overrides, context):
    by_id = {}
    for index, entry in enumerate(entries):
        entry_id = entry.get("id")
        if not entry_id:
            fail(f"{context}[{index}] is missing a stable id")
        if entry_id in by_id:
            fail(f"{context} contains duplicate id {entry_id!r}")
        by_id[entry_id] = entry

    for entry_id, change in overrides.items():
        if entry_id not in by_id:
            fail(f"{context} override refers to unknown id {entry_id!r}")
        if change.get("remove") is True:
            entries.remove(by_id[entry_id])
            continue

        entry = by_id[entry_id]
        entry.update(change.get("set", {}))
        for key in ("assets", "libs"):
            nested = change.get(key)
            if nested:
                entry[key] = apply_entries(entry.get(key, []), nested, f"{context}.{entry_id}.{key}")
    return entries


def resolve(recipe_path, stack=()):
    recipe_path = recipe_path.resolve()
    if recipe_path in stack:
        fail("recipe inheritance cycle: " + " -> ".join(map(str, (*stack, recipe_path))))

    data = json.loads(recipe_path.read_text())
    if len(data) != 1:
        fail(f"{recipe_path} must contain exactly one component key")
    component, body = next(iter(data.items()))
    if isinstance(body, list):
        return component, body
    if not isinstance(body, dict) or "parent" not in body:
        fail(f"{recipe_path} must contain a source array or a parent recipe")

    parent_path = (recipe_path.parent / body["parent"]).resolve()
    parent_component, sources = resolve(parent_path, (*stack, recipe_path))
    if component != parent_component:
        fail(f"component key {component!r} does not match parent key {parent_component!r}")

    sources = json.loads(json.dumps(sources))
    overrides = body.get("overrides", {}).get("sources", {})
    sources = apply_entries(sources, overrides, f"{component}.sources")
    return component, sources


def main():
    if len(sys.argv) != 2:
        fail("usage: resolve_recipe.py RECIPE.json")
    component, sources = resolve(Path(sys.argv[1]))
    json.dump({component: sources}, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"recipe resolution error: {error}", file=sys.stderr)
        sys.exit(1)
