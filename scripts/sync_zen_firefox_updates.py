#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""Bring Firefox version bumps and security fixes from Zen onto this fork.

Reads zen-browser/desktop, selects only those updates, and pushes the result
to this repository's origin. It refuses to push if origin is the Zen repo.
"""

import argparse
import json
import os
import re
import subprocess
import sys

ZEN_FETCH_URL = "https://github.com/zen-browser/desktop.git"
ZEN_DEV = "refs/remotes/zen-upstream/dev"
ZEN_STABLE = "refs/remotes/zen-upstream/stable"
FORBIDDEN_PUSH_MARKERS = ("zen-browser/desktop",)

FIREFOX_MESSAGE = re.compile(
    r"update to firefox|sync upstream firefox|firefox\s+[`'\"]?\d+\.\d+",
    re.IGNORECASE,
)
SECURITY_MESSAGE = re.compile(
    r"\b(security|secfix|advisory|CVE-\d{4}-\d+)\b",
    re.IGNORECASE,
)


def run(args, check=True, capture=False):
  result = subprocess.run(
      args,
      check=check,
      text=True,
      stdout=subprocess.PIPE if capture else None,
      stderr=subprocess.PIPE if capture else None,
  )
  return result


def git(*args, check=True, capture=False):
  command = ["git"]
  name = os.environ.get("GIT_COMMITTER_NAME")
  email = os.environ.get("GIT_COMMITTER_EMAIL")
  if name and email:
    command += ["-c", f"user.name={name}", "-c", f"user.email={email}"]
  return run([*command, *args], check=check, capture=capture)


def origin_push_url():
  return git("remote", "get-url", "--push", "origin", capture=True).stdout.strip()


def assert_origin_is_not_zen():
  url = origin_push_url().lower()
  for marker in FORBIDDEN_PUSH_MARKERS:
    if marker in url:
      raise SystemExit(
          f"Refusing to push. origin is {url}, which is the Zen Browser repository."
      )


def fetch_zen():
  git(
      "fetch",
      "--no-tags",
      ZEN_FETCH_URL,
      f"+refs/heads/dev:{ZEN_DEV}",
      f"+refs/heads/stable:{ZEN_STABLE}",
  )


def commit_list(base, tip):
  result = git(
      "log",
      "--reverse",
      "--format=%H",
      f"{base}..{tip}",
      capture=True,
      check=False,
  )
  if result.returncode != 0:
    return []
  return [line for line in result.stdout.splitlines() if line]


def commit_message(sha):
  return git("log", "-1", "--format=%B", sha, capture=True).stdout


def commit_subject(sha):
  return git("log", "-1", "--format=%s", sha, capture=True).stdout.strip()


def commit_time(sha):
  return int(git("log", "-1", "--format=%ct", sha, capture=True).stdout.strip())


def surfer_version(sha):
  result = git("show", f"{sha}:surfer.json", capture=True, check=False)
  if result.returncode != 0:
    return None
  try:
    version = json.loads(result.stdout).get("version", {})
  except json.JSONDecodeError:
    return None
  return (
      version.get("version"),
      version.get("candidate"),
      version.get("candidateBuild"),
  )


def changes_firefox_version(sha):
  parent = git("rev-parse", "--verify", f"{sha}^", capture=True, check=False)
  if parent.returncode != 0:
    return surfer_version(sha) is not None
  return surfer_version(sha) != surfer_version(parent.stdout.strip())


def is_relevant(sha):
  message = commit_message(sha)
  if FIREFOX_MESSAGE.search(message) or SECURITY_MESSAGE.search(message):
    return True
  return changes_firefox_version(sha)


def relevant_commits(base):
  seen = set()
  found = []
  for tip in (ZEN_DEV, ZEN_STABLE):
    for sha in commit_list(base, tip):
      if sha in seen or not is_relevant(sha):
        continue
      seen.add(sha)
      found.append(sha)
  found.sort(key=commit_time)
  return found


def current_branch():
  return git("branch", "--show-current", capture=True).stdout.strip()


def cherry_pick(commits):
  applied = []
  for sha in commits:
    result = git("cherry-pick", "-x", sha, check=False)
    if result.returncode != 0:
      git("cherry-pick", "--abort", check=False)
      return applied, sha
  return applied, None


def push(refspec):
  assert_origin_is_not_zen()
  git("push", "origin", refspec)


def open_pull_request(head, base, title, body):
  repo = origin_push_url()
  result = run(
      [
          "gh",
          "pr",
          "create",
          "--repo",
          repo,
          "--base",
          base,
          "--head",
          head,
          "--title",
          title,
          "--body",
          body,
      ],
      check=False,
  )
  if result.returncode != 0:
    print(result.stderr or result.stdout)
    raise SystemExit(result.returncode)


def describe(commits):
  lines = []
  for sha in commits:
    lines.append(f"- {sha[:10]} {commit_subject(sha)}")
  return "\n".join(lines)


def main():
  parser = argparse.ArgumentParser()
  parser.add_argument(
      "--push",
      action="store_true",
      help="Push a clean update to origin. Never pushes to Zen.",
  )
  args = parser.parse_args()

  if args.push:
    assert_origin_is_not_zen()

  fetch_zen()
  base = git("rev-parse", "HEAD", capture=True).stdout.strip()
  branch = current_branch()
  if not branch:
    raise SystemExit("Check out the mine branch before running this.")

  commits = relevant_commits("HEAD")
  if not commits:
    print("No new Zen Firefox or security updates.")
    return

  print("Zen updates to apply:")
  print(describe(commits))
  if not args.push:
    print("Dry run only. Re-run with --push to update origin.")
    return

  applied, failed = cherry_pick(commits)
  if failed and not applied:
    raise SystemExit(
        f"Could not cherry-pick {failed[:10]} {commit_subject(failed)}"
    )

  if failed:
    update_branch = f"automation/zen-sync-{applied[-1][:8]}"
    git("branch", "-f", update_branch, "HEAD")
    git("reset", "--hard", base)
    push(f"{update_branch}:{update_branch}")
    open_pull_request(
        update_branch,
        branch,
        "Apply Zen Firefox and security updates",
        "\n".join([
            "Cherry-pick stopped because a later Zen commit conflicted.",
            "",
            "Applied:",
            describe(applied),
            "",
            f"Blocked on `{failed[:10]}` {commit_subject(failed)}.",
            "",
            "This pull request targets this fork only.",
        ]),
    )
    return

  version = surfer_version("HEAD")
  label = version[0] if version else "updates"
  print(f"Pushing Firefox {label} updates to origin/{branch}.")
  push(f"HEAD:{branch}")


if __name__ == "__main__":
  try:
    main()
  except subprocess.CalledProcessError as error:
    if error.stderr:
      print(error.stderr, file=sys.stderr)
    raise SystemExit(error.returncode) from error
