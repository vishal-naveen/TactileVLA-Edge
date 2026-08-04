"""Documentation integrity checks.

These run in CI to catch dead internal links and malformed ADRs before they reach `main`.
Docs are reviewed in the same PR as the code they describe, so they are held to the same gate.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Matches [text](target) but not image embeds ![text](target).
MD_LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")

REQUIRED_TOP_LEVEL = (
    "README.md",
    "CONTRIBUTING.md",
    "CHANGELOG.md",
    "COMPATIBILITY.md",
    "LICENSE",
    "LICENSE-hardware",
    ".gitignore",
    ".env.example",
)

REQUIRED_DIRS = ("software", "firmware", "hardware", "docs", "tests")


def markdown_files() -> list[Path]:
    return [p for p in REPO_ROOT.rglob("*.md") if ".git" not in p.parts]


def test_required_top_level_files_exist() -> None:
    missing = [name for name in REQUIRED_TOP_LEVEL if not (REPO_ROOT / name).exists()]
    assert not missing, f"missing top-level files: {missing}"


def test_required_directories_exist() -> None:
    missing = [name for name in REQUIRED_DIRS if not (REPO_ROOT / name).is_dir()]
    assert not missing, f"missing directories: {missing}"


def test_internal_markdown_links_resolve() -> None:
    """Every relative markdown link must point at a file that exists."""
    broken: list[str] = []
    for md in markdown_files():
        for target in MD_LINK.findall(md.read_text(encoding="utf-8")):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            path_part = target.split("#", 1)[0]
            if not path_part:
                continue
            if not (md.parent / path_part).resolve().exists():
                broken.append(f"{md.relative_to(REPO_ROOT)} -> {target}")
    assert not broken, "broken internal links:\n" + "\n".join(broken)


def test_adrs_are_well_formed() -> None:
    """Each ADR needs a status, a date, and the Context/Decision/Consequences sections."""
    adr_dir = REPO_ROOT / "docs" / "adr"
    adrs = sorted(adr_dir.glob("[0-9][0-9][0-9][0-9]-*.md"))
    assert adrs, "no ADRs found"

    problems: list[str] = []
    for adr in adrs:
        text = adr.read_text(encoding="utf-8")
        if "**Status:**" not in text:
            problems.append(f"{adr.name}: no Status")
        if "**Date:**" not in text:
            problems.append(f"{adr.name}: no Date")
        for section in ("## Context", "## Decision", "## Consequences"):
            if section not in text:
                problems.append(f"{adr.name}: missing {section}")
    assert not problems, "malformed ADRs:\n" + "\n".join(problems)


def test_adr_numbers_are_unique() -> None:
    adr_dir = REPO_ROOT / "docs" / "adr"
    numbers = [p.name[:4] for p in adr_dir.glob("[0-9][0-9][0-9][0-9]-*.md")]
    assert len(numbers) == len(set(numbers)), f"duplicate ADR numbers: {numbers}"


def test_env_example_has_no_real_secrets() -> None:
    """`.env.example` is a template: keys may be listed, values must be blank or placeholders."""
    lines = (REPO_ROOT / ".env.example").read_text(encoding="utf-8").splitlines()
    suspicious: list[str] = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key.strip().endswith(("TOKEN", "KEY", "SECRET", "PASSWORD")) and value.strip():
            suspicious.append(key.strip())
    assert not suspicious, f"populated secret values in .env.example: {suspicious}"
