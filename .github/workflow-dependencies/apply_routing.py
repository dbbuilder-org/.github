#!/usr/bin/env python3
"""
Adds a repo's routing to project-drag.yml and linear-drag.yml by cloning the
existing "dbbuilder-org/billboard" entries as templates and substituting IDs,
rather than hand-authoring new YAML/bash — guarantees matching indentation
and structure. Mirrors deploy/New-LinearStatusSync.ps1's approach exactly
(that script predates this workflow; keep both in sync if the template
shape in project-drag.yml or linear-drag.yml ever changes).

Idempotent: skips (prints a message, doesn't error) if the repo/field is
already registered in either file.
"""
import argparse
import re
import sys
from pathlib import Path


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--project-drag-file", required=True)
    p.add_argument("--linear-drag-file", required=True)
    p.add_argument("--repo", required=True, help="owner/repo, e.g. dbbuilder-org/billboard")
    p.add_argument("--job-slug", required=True, help="safe job-key suffix, e.g. billboard")
    p.add_argument("--project-id", required=True)
    p.add_argument("--field-id", required=True)
    for name in ("state-backlog", "state-todo", "state-in-progress", "state-blocked",
                 "state-in-review", "state-done", "state-canceled", "state-duplicate"):
        p.add_argument(f"--{name}", default="")
    for name in ("opt-backlog", "opt-todo", "opt-in-progress", "opt-blocked",
                 "opt-in-review", "opt-done", "opt-canceled"):
        p.add_argument(f"--{name}", default="")
    return p.parse_args()


def read_preserving_newlines(path):
    # Path.read_text() normalizes CRLF -> LF (universal newlines); these
    # files are checked in with CRLF, so that would turn a small routing
    # change into a spurious whole-file diff. newline='' passes line
    # endings through untouched.
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def write_preserving_newlines(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def clone_and_substitute(text, pattern, subs, label):
    match = re.search(pattern, text, re.M | re.S)
    if not match:
        print(f"::error::Could not find a template to clone for {label}", file=sys.stderr)
        sys.exit(1)
    template = match.group(0)
    new_block = template
    for old, new in subs:
        new_block = re.sub(old, new, new_block)
    return template, new_block


def update_project_drag(args):
    path = Path(args.project_drag_file)
    text = read_preserving_newlines(path)

    if args.field_id in text:
        print("project-drag.yml: already routed — skipping")
        return

    template, new_job = clone_and_substitute(
        text,
        r"^  handle-drag-issue-boards:.*?\n(?=  \S|\Z)",
        [
            (r"handle-drag-issue-boards:", f"handle-drag-issue-boards-{args.job_slug}:"),
            (r"PVTSSF_lADODmqj9M4Be0uqzhZMFd8", args.field_id),
            (r'STATE_BACKLOG: "[^"]*"', f'STATE_BACKLOG: "{args.state_backlog}"'),
            (r'STATE_TODO: "[^"]*"', f'STATE_TODO: "{args.state_todo}"'),
            (r'STATE_IN_PROGRESS: "[^"]*"', f'STATE_IN_PROGRESS: "{args.state_in_progress}"'),
            (r'STATE_BLOCKED: "[^"]*"', f'STATE_BLOCKED: "{args.state_blocked}"'),
            (r'STATE_IN_REVIEW: "[^"]*"', f'STATE_IN_REVIEW: "{args.state_in_review}"'),
            (r'STATE_DONE: "[^"]*"', f'STATE_DONE: "{args.state_done}"'),
            (r'STATE_CANCELED: "[^"]*"', f'STATE_CANCELED: "{args.state_canceled}"'),
            (r'STATE_DUPLICATE: "[^"]*"', f'STATE_DUPLICATE: "{args.state_duplicate}"'),
        ],
        "project-drag.yml's handle-drag-issue-boards job",
    )
    write_preserving_newlines(path, text + "\n" + new_job)
    print(f"project-drag.yml: added job handle-drag-issue-boards-{args.job_slug}")


def update_linear_drag(args):
    path = Path(args.linear_drag_file)
    text = read_preserving_newlines(path)

    if f"{args.repo})" in text:
        print("linear-drag.yml: already registered — skipping")
        return

    match = re.search(r"^(\s+)dbbuilder-org/billboard\)\n(.*?\n\1  ;;\n)", text, re.M | re.S)
    if not match:
        print("::error::Could not find the 'dbbuilder-org/billboard)' case arm to clone in linear-drag.yml",
              file=sys.stderr)
        sys.exit(1)
    indent = match.group(1)
    template = f"{indent}dbbuilder-org/billboard)\n{match.group(2)}"

    new_arm = template
    for old, new in [
        (re.escape("dbbuilder-org/billboard"), args.repo),
        (r"PVT_kwDODmqj9M4Be0uq", args.project_id),
        (r"PVTSSF_lADODmqj9M4Be0uqzhZMFd8", args.field_id),
        (r'OPT_BACKLOG="[^"]*"', f'OPT_BACKLOG="{args.opt_backlog}"'),
        (r'OPT_TODO="[^"]*"', f'OPT_TODO="{args.opt_todo}"'),
        (r'OPT_IN_PROGRESS="[^"]*"', f'OPT_IN_PROGRESS="{args.opt_in_progress}"'),
        (r'OPT_IN_REVIEW="[^"]*"', f'OPT_IN_REVIEW="{args.opt_in_review}"'),
        (r'OPT_BLOCKED="[^"]*"', f'OPT_BLOCKED="{args.opt_blocked}"'),
        (r'OPT_DONE="[^"]*"', f'OPT_DONE="{args.opt_done}"'),
        (r'OPT_CANCELED="[^"]*"', f'OPT_CANCELED="{args.opt_canceled}"'),
    ]:
        new_arm = re.sub(old, new, new_arm)

    # Insert the new arm right before the cloned template arm, so the `*)`
    # catch-all at the bottom of the case block stays last.
    updated = text.replace(template, new_arm + template)
    write_preserving_newlines(path, updated)
    print(f"linear-drag.yml: added case arm for {args.repo}")


def main():
    args = parse_args()
    update_project_drag(args)
    update_linear_drag(args)


if __name__ == "__main__":
    main()
