#!/usr/bin/env python3
"""Builds checks.js, each check's GUIDE.md, and CHECKS.md from checks/*/check.json.

Run it from anywhere: python3 tools/build.py. It exits nonzero and lists every problem when a check
does not meet the contract, and writes nothing in that case.
"""

import json
import re
import sys
from pathlib import Path

BUNDLE = Path(__file__).resolve().parent.parent

REQUIRED = [
    "id", "proposal", "proposalTitle", "milestone", "milestoneTitle", "title", "source",
    "status", "goal", "needs", "launch", "setup", "steps", "expected",
]
LISTS = ["needs", "setup", "steps", "expected", "cleanup", "fixtures"]
STATUSES = {"no-record", "partial"}
LAUNCHES = {"isolated", "isolated-persistent", "real", "none"}
NEEDS = {
    "network", "second-display", "physical-mouse", "trackpad", "voiceover", "ssh-host", "docker",
    "web-account", "finder", "keychain", "xcode", "pages",
}
NEED_LABELS = {
    "network": "network access",
    "second-display": "a second display",
    "physical-mouse": "a mouse with back and forward buttons",
    "trackpad": "a trackpad",
    "voiceover": "VoiceOver",
    "ssh-host": "an ssh host",
    "docker": "Docker",
    "web-account": "an account on a real website",
    "finder": "Finder",
    "keychain": "Keychain access",
    "xcode": "the Xcode app",
    "pages": "Pages",
}


def milestone_number(text):
    match = re.match(r"M(\d+)", text)
    return int(match.group(1)) if match else 0


def validate(path, check):
    problems = []
    where = path.relative_to(BUNDLE)

    for key in REQUIRED:
        if key not in check:
            problems.append(f"{where}: missing '{key}'")

    for key in LISTS:
        if key in check and not (
            isinstance(check[key], list) and all(isinstance(x, str) for x in check[key])
        ):
            problems.append(f"{where}: '{key}' must be a list of strings")

    if check.get("id") != path.parent.name:
        problems.append(f"{where}: id '{check.get('id')}' does not match its folder")

    if check.get("status") not in STATUSES:
        problems.append(f"{where}: status '{check.get('status')}' is not one of {sorted(STATUSES)}")

    if check.get("launch") not in LAUNCHES:
        problems.append(f"{where}: launch '{check.get('launch')}' is not one of {sorted(LAUNCHES)}")

    for need in check.get("needs", []):
        if need not in NEEDS:
            problems.append(f"{where}: need '{need}' is not in the vocabulary")

    for fixture in check.get("fixtures", []):
        if not (BUNDLE / fixture).exists():
            problems.append(f"{where}: fixture '{fixture}' does not exist")

    for key in ("steps", "expected"):
        if key in check and not check[key]:
            problems.append(f"{where}: '{key}' is empty")

    return problems


def numbered(items):
    return "\n".join(f"{i}. {item}" for i, item in enumerate(items, 1))


def bulleted(items):
    return "\n".join(f"- [ ] {item}" for item in items)


def guide(check):
    needs = check["needs"]
    needs_text = ", ".join(NEED_LABELS[n] for n in needs) if needs else "nothing beyond a Mac"
    status = (
        "Partly checked before. See the notes."
        if check["status"] == "partial"
        else "No record of this check being done."
    )

    parts = [
        f"# {check['title']}",
        "",
        f"{check['proposal']} {check['milestone']}: {check['milestoneTitle']}. {status}",
        "",
        f"Check id: `{check['id']}`. Source: {check['source']}.",
        "",
        "## Goal",
        "",
        check["goal"],
        "",
        "## Needs",
        "",
        needs_text[0].upper() + needs_text[1:] + ".",
        "",
        "## Setup",
        "",
        numbered(check["setup"]) if check["setup"] else "None.",
        "",
        "## Steps",
        "",
        numbered(check["steps"]),
        "",
        "## Expected",
        "",
        bulleted(check["expected"]),
    ]

    if check.get("cleanup"):
        parts += ["", "## Cleanup", "", numbered(check["cleanup"])]

    if check.get("notes"):
        parts += ["", "## Notes", "", check["notes"]]

    parts += [
        "",
        "## Verdict",
        "",
        "Record it in the runner, `index.html`: Pass, Pass with changes, Fail, or Couldn't run. A fail names the step.",
        "",
    ]

    return "\n".join(parts)


def index(checks):
    lines = ["# Hand checks", "", "Generated from `checks/*/check.json` by `tools/build.py`.", ""]
    proposal = None

    for check in checks:
        if check["proposal"] != proposal:
            proposal = check["proposal"]
            lines += [f"## {proposal}: {check['proposalTitle']}", ""]

        lines.append(
            f"- {check['milestone']}: [{check['title']}](checks/{check['id']}/GUIDE.md)"
            + (" (partly checked)" if check["status"] == "partial" else "")
        )

        next_index = checks.index(check) + 1
        if next_index == len(checks) or checks[next_index]["proposal"] != proposal:
            lines.append("")

    return "\n".join(lines)


def main():
    paths = sorted((BUNDLE / "checks").glob("*/check.json"))
    checks = []
    problems = []

    for path in paths:
        try:
            check = json.loads(path.read_text())
        except json.JSONDecodeError as error:
            problems.append(f"{path.relative_to(BUNDLE)}: not valid JSON: {error}")
            continue

        problems += validate(path, check)
        checks.append((path, check))

    ids = [c["id"] for _, c in checks if "id" in c]
    for duplicate in sorted({i for i in ids if ids.count(i) > 1}):
        problems.append(f"duplicate id '{duplicate}'")

    if problems:
        print("\n".join(problems), file=sys.stderr)
        print(f"\n{len(problems)} problems. Nothing was written.", file=sys.stderr)
        return 1

    ordered = sorted(
        (c for _, c in checks),
        key=lambda c: (c["proposal"], milestone_number(c["milestone"]), c["id"]),
    )

    for check in ordered:
        (BUNDLE / "checks" / check["id"] / "GUIDE.md").write_text(guide(check))

    (BUNDLE / "checks.js").write_text(
        "// Generated by tools/build.py from checks/*/check.json. Do not edit.\n"
        "window.UHC_CHECKS = " + json.dumps(ordered, indent=1, ensure_ascii=False) + ";\n"
    )
    (BUNDLE / "CHECKS.md").write_text(index(ordered))

    print(f"Built {len(ordered)} checks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
