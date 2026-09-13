# bin/security/branchgit.py
"""The two questions the ledger cannot answer about a branch, asked of git.

A finding fixed on `main` stays open on `develop` until `develop` is analysed
again -- correctly, since until it carries the fix the hole is there. What the
ledger cannot say is whether it carries the fix already: that is a fact about
git history, and this module is the only place the security area asks git
about it.

Every answer here is True, False or NONE, and None is not a soft False. It
means "could not say": no repository at that path, no such branch, a commit
git does not know, git missing, git slow. A reader that renders None as False
tells the operator a fix is absent when nobody looked, which is the one thing
this whole area exists to never do.
"""
import subprocess

TIMEOUT = 2.0


def _git(repo_path, args, timeout):
    """One git call as a list, never a shell string; `-C`, never chdir -- the
    server is one process and cannot change directory under another request.
    Returns (rc, stdout) or None when git could not be run to completion."""
    try:
        p = subprocess.run(["git", "-C", str(repo_path), *args],
                           capture_output=True, text=True, timeout=timeout,
                           check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.returncode, p.stdout.strip()


def head_of(repo_path, branch, timeout=TIMEOUT):
    """The commit at the tip of `branch`, or None.

    `refs/remotes/origin/<branch>` before `refs/heads/<branch>`, the order
    bin/agentloop already uses when it opens an analysis: a local branch left
    behind answers for a remote one that moved on, and the analysis was made
    of what origin had.
    """
    if not branch or branch.startswith("-"):
        return None
    for ref in (f"refs/remotes/origin/{branch}", f"refs/heads/{branch}"):
        out = _git(repo_path, ["rev-parse", "--verify", "--quiet", ref], timeout)
        if out is None:
            return None
        rc, sha = out
        if rc == 0 and sha:
            return sha
    return None


def contains(repo_path, commit, branch_head, timeout=TIMEOUT):
    """Whether `commit` is an ancestor of `branch_head` (a commit being its
    own ancestor): True, False, or None when git could not say.

    `--is-ancestor` exits 0 for yes and 1 for no; anything else -- an unknown
    object, a path that is not a repository -- is neither, and is None here
    rather than the False a naive `rc == 0` would make of it.
    """
    if not commit or not branch_head or commit.startswith("-") or branch_head.startswith("-"):
        return None
    out = _git(repo_path, ["merge-base", "--is-ancestor", commit, branch_head], timeout)
    if out is None:
        return None
    rc, _ = out
    if rc == 0:
        return True
    if rc == 1:
        return False
    return None
