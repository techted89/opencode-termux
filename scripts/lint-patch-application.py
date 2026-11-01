#!/usr/bin/env python3
"""Reject silent patch failures and unverified patch applications.

Scans scripts/*.sh and enforces:

  1. A patch command must not swallow failure (`|| true`, `|| :`, `|| exit 0`).
  2. A patch command must not skip on a context mismatch ("... skipping").
  3. Every application must carry a marker assertion: either the
     `apply_verified_patch` helper's marker argument, or a `grep -q... "marker"`
     within 12 logical lines.
  4. That marker string must occur in the patch file, so a typo cannot pass.
  5. Every patches/**/*.patch must be applied by some script, and at most once
     per script. A deliberate retry carries `# lint:allow-repeat-application`.

Scripts are independent pipelines, so a patch used by two pipelines (for
example the v1 and v2 OpenTUI builders) is not a duplicate. `git apply
--stat/--numstat/--summary/--check` and `patch --dry-run` are inspections, not
applications, and are ignored.

Escape hatches: `# lint:allow-patch-failure` skips the failure-swallow check
for one line; `# lint:allow-repeat-application` allows a second application of
the same patch in a script.
"""

from __future__ import annotations

import os
import pathlib
import re
import shlex
import sys

ROOT = pathlib.Path(os.environ.get("LINT_PATCH_ROOT") or pathlib.Path(__file__).resolve().parent.parent)
SCRIPTS = sorted(ROOT.glob("scripts/*.sh"))
PATCHES = sorted((ROOT / "patches").glob("**/*.patch"))

GIT_APPLY = r"git\b[^|;&]*?\bapply\b"
PATCH_CMD_RE = re.compile(rf"(?:{GIT_APPLY}|git\s+am\b|patch\s+-p\d*\b)")
NON_APPLY_RE = re.compile(r"--(?:stat|numstat|summary|check|dry-run)\b")
SWALLOW_TOKEN_RE = re.compile(r"^\s*(?:true\b|:|/bin/true\b|exit\s+0\b)")
SKIP_RE = re.compile(r"already applied or does not apply cleanly|skipping", re.IGNORECASE)
ALLOW_FAILURE_RE = re.compile(r"lint:allow-patch-failure")
ALLOW_REPEAT_RE = re.compile(r"lint:allow-repeat-application")
PATCH_LITERAL_RE = re.compile(r"patches/[A-Za-z0-9_./+-]+\.patch")
HELPER = "apply_verified_patch"
LOOKAHEAD_SKIP = 5
LOOKAHEAD_MARKER = 12


def logical_lines(path: pathlib.Path):
    """Yield (line_number, joined_text) with backslash continuations merged."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    index = 0
    while index < len(lines):
        start = index
        text = lines[index]
        while text.rstrip().endswith("\\") and index + 1 < len(lines):
            index += 1
            text = text.rstrip()[:-1] + " " + lines[index].strip()
        yield start + 1, text
        index += 1


def expand(text: str, variables: dict[str, str]) -> str:
    """Substitute simple shell variables, then normalise the repo prefix."""
    for _ in range(2):
        for name in sorted(variables, key=len, reverse=True):
            pattern = r"\$\{" + re.escape(name) + r"\}|\$" + re.escape(name) + r"\b"
            text = re.sub(pattern, lambda _m, value=variables[name]: value, text)
    return text.replace("${REPO_ROOT}", "").replace("$REPO_ROOT", "")


def local_patch(text: str) -> str | None:
    match = PATCH_LITERAL_RE.search(text)
    return match.group(0) if match else None


def grep_marker(text: str) -> str | None:
    """Return the first literal grep pattern on a line, if it is an assertion."""
    index = text.find("grep")
    if index < 0:
        return None
    try:
        parts = shlex.split(text[index:])
    except ValueError:
        return None
    if not parts or parts[0] != "grep":
        return None
    for part in parts[1:]:
        if part.startswith("-") or part in ("||", "&&", "{", "}", "then", "do"):
            continue
        if part.startswith("$"):
            return None
        if "/" in part or part.endswith((".zig", ".cpp", ".cc", ".c", ".h", ".ts", ".js", ".sh")):
            continue
        return part
    return None


def marker_after(logical, position: int) -> tuple[str | None, int | None]:
    for later_no, later in logical[position + 1:position + 1 + LOOKAHEAD_MARKER]:
        if later.lstrip().startswith("#"):
            continue
        marker = grep_marker(later)
        if marker:
            return marker, later_no
    return None, None


def main() -> int:
    errors: list[str] = []
    sites: list[dict] = []
    patch_text = {str(path.relative_to(ROOT)): path.read_text(encoding="utf-8", errors="replace")
                  for path in PATCHES}

    for script in SCRIPTS:
        logical = list(logical_lines(script))
        variables: dict[str, str] = {}
        for _, text in logical:
            match = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", text)
            if not match:
                continue
            name, value = match.group(1), match.group(2).strip()
            if name in {"REPO_ROOT", "SCRIPT_DIR"}:
                continue
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            variables[name] = value

        rel_script = script.relative_to(ROOT)
        for position, (line_no, text) in enumerate(logical):
            if text.lstrip().startswith("#"):
                continue

            helper_at = text.find(HELPER)
            if helper_at >= 0:
                try:
                    parts = shlex.split(text[helper_at:])
                except ValueError:
                    errors.append(f"{rel_script}:{line_no}: malformed {HELPER} arguments")
                    continue
                if len(parts) < 5 or parts[0] != HELPER:
                    continue  # function definition or non-call mention
                patch = local_patch(expand(parts[2], variables))
                if not patch:
                    continue  # downloaded/external patch, not under patches/
                marker = parts[4].strip()
                if not marker:
                    errors.append(f"{rel_script}:{line_no}: {HELPER} has an empty marker")
                    continue
                sites.append({"script": script, "line": line_no, "patch": patch,
                              "marker": marker, "text": text, "line_text": text})
                continue

            # Split on && / || so `git apply --stat ... && git apply ...`
            # is one inspection plus one application, not one skip.
            segments = re.split(r"(\s*(?:&&|\|\|)\s*)", text)
            for index in range(0, len(segments), 2):
                segment = segments[index]
                operator = segments[index + 1].strip() if index + 1 < len(segments) else ""
                following = segments[index + 2] if index + 2 < len(segments) else ""
                if not PATCH_CMD_RE.search(segment):
                    continue
                if NON_APPLY_RE.search(segment):
                    continue  # --stat/--check/--dry-run only inspect
                if ALLOW_FAILURE_RE.search(segment):
                    continue

                if operator == "||" and SWALLOW_TOKEN_RE.match(following):
                    errors.append(
                        f"{rel_script}:{line_no}: patch failure is swallowed by "
                        "`|| true`/`|| :`/`|| exit 0`"
                    )

                window = logical[position + 1:position + 1 + LOOKAHEAD_SKIP]
                for later_no, later in window:
                    if later.lstrip().startswith("#"):
                        continue
                    if SKIP_RE.search(later):
                        errors.append(
                            f"{rel_script}:{line_no}: patch mismatch is skipped instead of failing "
                            f"(near line {later_no})"
                        )
                        break

                patch = local_patch(expand(segment, variables))
                if not patch:
                    continue
                marker, marker_line = marker_after(logical, position)
                if not marker:
                    errors.append(
                        f"{rel_script}:{line_no}: {patch} is applied without a marker assertion "
                        f"(add a grep -q within {LOOKAHEAD_MARKER} lines)"
                    )
                    continue
                sites.append({"script": script, "line": line_no, "patch": patch,
                              "marker": marker, "text": text, "line_text": text})

    # Marker must actually exist in the patch it verifies.
    for site in sites:
        text = patch_text.get(site["patch"])
        if text is None:
            errors.append(f"{site['script'].relative_to(ROOT)}:{site['line']}: patch file {site['patch']} is missing")
        elif site["marker"] not in text:
            errors.append(
                f"{site['script'].relative_to(ROOT)}:{site['line']}: marker {site['marker']!r} "
                f"does not occur in {site['patch']}"
            )

    # At most one application per patch per script, unless explicitly retried.
    groups: dict[tuple[pathlib.Path, str], list[dict]] = {}
    for site in sites:
        groups.setdefault((site["script"], site["patch"]), []).append(site)
    for (script, patch), group in groups.items():
        if len(group) > 1 and not any(ALLOW_REPEAT_RE.search(item["line_text"]) for item in group):
            lines = ", ".join(str(item["line"]) for item in group)
            errors.append(
                f"{script.relative_to(ROOT)}: {patch} is applied {len(group)} times (lines {lines}); "
                "use # lint:allow-repeat-application for a deliberate retry"
            )

    # Every repository patch must be applied somewhere.
    referenced = {site["patch"] for site in sites}
    for patch in PATCHES:
        rel = str(patch.relative_to(ROOT))
        if rel not in referenced:
            errors.append(f"{rel}: orphan patch, never applied by any script")

    if errors:
        for error in errors:
            print(f"ERROR {error}", file=sys.stderr)
        print(
            f"\n{len(errors)} patch-application error(s). Each patches/**/*.patch needs one "
            "application per script and a marker assertion whose text is in the patch.",
            file=sys.stderr,
        )
        return 1

    print(
        f"lint-patch-application: OK ({len(SCRIPTS)} scripts, {len(sites)} applications, "
        f"{len(PATCHES)} patches)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
