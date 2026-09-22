#!/usr/bin/env python3
"""Repair only the two verified specifier mismatches in daed f045ecd.

Keep the dependency versions and integrity hashes unchanged and let pnpm's
frozen install verify all dependency resolutions after this repair.
"""
import json
import sys
from pathlib import Path
import yaml


def repair(root):
    root = Path(root)
    path = root / "pnpm-lock.yaml"
    text = path.read_text()
    lock = yaml.safe_load(text)
    workspace = yaml.safe_load((root / "pnpm-workspace.yaml").read_text())
    fixes = {(".", "@graphql-codegen/cli"): "6.1.1", ("apps/web", "vite"): "^7.3.1"}
    for (name, package), specifier in fixes.items():
        manifest = json.loads((root / name / "package.json").read_text())
        assert manifest["devDependencies"][package] == "catalog:", (name, package)
        assert workspace["catalog"][package] == specifier, (package, "catalog changed")
        entry = lock["importers"][name]["devDependencies"][package]
        assert entry["specifier"] in (specifier, "catalog:"), (package, "unexpected lock")
        # Fix the importer and add the catalog entry using the already locked
        # version. pnpm catalog entries contain the plain version without peers.
        quoted = "'@graphql-codegen/cli'" if package.startswith("@") else package
        old = f"      {quoted}:\n        specifier: {specifier}\n"
        new = f"      {quoted}:\n        specifier: 'catalog:'\n"
        if entry["specifier"] != "catalog:":
            assert text.count(old) == 1, (package, "ambiguous importer")
            text = text.replace(old, new)
        if package not in lock.get("catalogs", {}).get("default", {}):
            header = "catalogs:\n  default:\n"
            assert text.count(header) == 1
            addition = f"    {quoted}:\n      specifier: {specifier}\n      version: {entry['version'].split('(')[0]}\n"
            text = text.replace(header, header + addition)
    path.write_text(text, encoding="utf-8", newline="\n")
    print("Repaired daed catalog specifiers without changing locked versions")


if __name__ == "__main__":
    repair(sys.argv[1])
