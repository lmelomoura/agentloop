"""config/lib/docker-sweep.sh reclaims a compose project's IMAGES, not only its
containers, volumes and networks.

Every agent run of a project that builds its services (`build:` in compose)
leaves one image per service tagged `<project>-<service>:latest`. They are not
dangling, so `dk_prune_global` never takes them, and the build-cache ceiling
cannot evict the layers they still reference. Observed 2026-10-08: 164 images
from 15 finished Revenue Copilot runs and 40.7 GB of build cache against a
20 GiB ceiling.

The library runs against test/fake-docker, which answers from a JSON state file
and records every removal, so these tests assert on what was DESTROYED.

config/lib/ is personal configuration and is not shipped (see .gitignore), so
on a checkout without the library -- CI among them -- the module is skipped.
"""

import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "config" / "lib" / "docker-sweep.sh"
FAKE = REPO / "test" / "fake-docker"

pytestmark = pytest.mark.skipif(
    not LIB.is_file(), reason="config/lib/docker-sweep.sh is not installed here")

OLD = "2026-01-01 00:00:00 +0000 UTC"


def young():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S +0000 UTC")


def img(iid, repo, project, created=OLD, tag="latest", builder=""):
    return {"id": iid, "repo": repo, "tag": tag, "project": project,
            "created": created, "builder": builder}


def classic(iid, repo, created=OLD):
    """An image compose's classic builder made: it carries
    com.docker.compose.image.builder=classic and NO project label."""
    return img(iid, repo, "", created=created, builder="classic")


@pytest.fixture
def dock(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "docker").symlink_to(FAKE)
    state = tmp_path / "state.json"

    class Dock:
        def __init__(self):
            self.state = {"containers": [], "images": [], "volumes": [],
                          "networks": [], "log": []}

        def run(self, script, **env):
            state.write_text(json.dumps(self.state))
            e = dict(os.environ)
            e.update({"PATH": "%s:%s" % (bin_dir, os.environ["PATH"]),
                      "FAKE_DOCKER_STATE": str(state)})
            for k in ("DK_DRY_RUN", "DK_IMAGE_PROJECT_RE", "AL_LIVE_WORKTREES", "AL_CANONICALS",
                      "DK_ORPHAN_NAME_GLOB", "DK_PROTECTED_NAMES",
                      "AL_SWEEP_GRACE_SECONDS"):
                e.pop(k, None)
            e.update({k: str(v) for k, v in env.items()})
            p = subprocess.run(
                ["bash", "-c", 'source "$1"; ' + script, "_", str(LIB)],
                capture_output=True, text=True, env=e, cwd=tmp_path)
            self.state = json.loads(state.read_text())
            return p

        def images(self):
            return sorted("%s:%s" % (i["repo"], i["tag"]) for i in self.state["images"])

        def removed_images(self):
            return sorted(x[len("rm image "):] for x in self.state["log"]
                          if x.startswith("rm image "))

    d = Dock()
    d.tmp = tmp_path
    return d


# ------------------------------------------------------------- dk_stack_down

def test_stack_down_removes_the_projects_labelled_images(dock):
    dock.state["containers"] = [
        {"id": "c1", "project": "rc-run1", "workdir": "/gone", "created": OLD,
         "image": "i1"}]
    dock.state["images"] = [
        img("i1", "rc-run1-api", "rc-run1"),
        img("i2", "rc-run1-tools", "rc-run1"),
        img("i3", "rc-run2-api", "rc-run2"),
        img("i4", "postgres", "")]
    p = dock.run("dk_stack_down rc-run1")
    assert p.returncode == 0, p.stderr
    assert dock.removed_images() == ["rc-run1-api:latest", "rc-run1-tools:latest"]
    assert dock.images() == ["postgres:latest", "rc-run2-api:latest"]


def test_stack_down_removes_an_untagged_labelled_image_by_id(dock):
    dock.state["images"] = [img("abc123", "<none>", "rc-run1", tag="<none>")]
    dock.run("dk_stack_down rc-run1")
    assert dock.removed_images() == ["abc123"]


def test_stack_down_keeps_and_reports_an_image_another_container_uses(dock):
    # A container of ANOTHER project runs on an image built by rc-run1: the
    # removal is refused, never forced, and said out loud.
    dock.state["containers"] = [
        {"id": "c9", "project": "other", "workdir": "/x", "created": OLD,
         "image": "i1"}]
    dock.state["images"] = [img("i1", "rc-run1-api", "rc-run1"),
                            img("i2", "rc-run1-tools", "rc-run1")]
    p = dock.run("dk_stack_down rc-run1")
    assert dock.removed_images() == ["rc-run1-tools:latest"]
    assert "rc-run1-api:latest" in dock.images()
    assert "rc-run1-api:latest" in p.stdout
    assert "in use" in p.stdout


def test_stack_down_dry_run_reports_images_and_removes_nothing(dock):
    dock.state["containers"] = [
        {"id": "c1", "project": "rc-run1", "workdir": "/gone", "created": OLD}]
    dock.state["images"] = [img("i1", "rc-run1-api", "rc-run1"),
                            img("i2", "rc-run1-tools", "rc-run1"),
                            img("i3", "rc-run2-api", "rc-run2")]
    p = dock.run("dk_stack_down rc-run1", DK_DRY_RUN=1)
    assert "1 containers" in p.stdout
    assert "2 images" in p.stdout
    assert "rc-run1-api:latest" in p.stdout
    assert dock.state["log"] == []
    assert len(dock.state["images"]) == 3


# ------------------------------------------------- dk_sweep, image orphans

def sweep(dock, **env):
    env.setdefault("DK_ORPHAN_NAME_GLOB", "rc-*")
    env.setdefault("DK_PROTECTED_NAMES", "revenue-copilot")
    return dock.run("dk_sweep", **env)


def test_sweep_reclaims_the_images_of_an_old_orphan_matching_the_glob(dock):
    dock.state["images"] = [img("i1", "rc-20261007t175858z-27548-tools",
                                "rc-20261007t175858z-27548"),
                            img("i2", "rc-20261007t175858z-27548-api",
                                "rc-20261007t175858z-27548")]
    p = sweep(dock)
    assert dock.images() == [], p.stdout + p.stderr
    assert "rc-20261007t175858z-27548" in p.stdout


def test_sweep_reclaims_a_projects_untagged_images(dock):
    # A rebuild that moves a tag leaves the old image untagged but still
    # labelled; `docker image ls` without -a does not list it. Observed:
    # 13 such images of one finished run, 1-4 GB each, missed by the sweep.
    dock.state["images"] = [
        img("u1", "<none>", "rc-old", tag="<none>"),
        img("u2", "<none>", "rc-old", tag="<none>")]
    p = sweep(dock)
    assert dock.images() == [], p.stdout + p.stderr
    assert dock.removed_images() == ["u1", "u2"]


def test_sweep_image_pass_honours_dry_run(dock):
    dock.state["images"] = [img("i1", "rc-old-tools", "rc-old")]
    p = sweep(dock, DK_DRY_RUN=1)
    assert "rc-old" in p.stdout
    assert dock.images() == ["rc-old-tools:latest"]
    assert dock.removed_images() == []


def test_sweep_refuses_a_protected_name(dock):
    dock.state["images"] = [img("i1", "revenue-copilot-api", "revenue-copilot")]
    sweep(dock, DK_ORPHAN_NAME_GLOB="*")
    assert dock.images() == ["revenue-copilot-api:latest"]


def test_sweep_refuses_a_name_outside_the_glob(dock):
    dock.state["images"] = [img("i1", "cms-web", "cms")]
    sweep(dock)
    assert dock.images() == ["cms-web:latest"]


def test_sweep_refuses_images_without_a_glob(dock):
    dock.state["images"] = [img("i1", "rc-old-tools", "rc-old")]
    dock.run("dk_sweep", DK_PROTECTED_NAMES="revenue-copilot")
    assert dock.images() == ["rc-old-tools:latest"]


def test_sweep_refuses_the_images_of_a_live_run(dock):
    live = dock.tmp / "live.txt"
    live.write_text(
        "/al/data/worktrees/rc-dev-agent/20261008T054537Z-7799\n"
        "/al/data/worktrees/rc-dev-agent/20261008T054537Z-7799/revenue-copilot\n")
    dock.state["images"] = [img("i1", "rc-20261008t054537z-7799-api",
                                "rc-20261008t054537z-7799")]
    sweep(dock, AL_LIVE_WORKTREES=live)
    assert dock.images() == ["rc-20261008t054537z-7799-api:latest"]


def test_sweep_refuses_an_image_younger_than_the_grace_period(dock):
    # The NEWEST image decides: one old image does not license the young one.
    dock.state["images"] = [img("i1", "rc-new-api", "rc-new"),
                            img("i2", "rc-new-tools", "rc-new", created=young())]
    sweep(dock)
    assert dock.images() == ["rc-new-api:latest", "rc-new-tools:latest"]


def test_sweep_refuses_an_image_with_an_unparseable_age(dock):
    dock.state["images"] = [img("i1", "rc-odd-api", "rc-odd", created="yesterday")]
    sweep(dock)
    assert dock.images() == ["rc-odd-api:latest"]


def test_sweep_never_touches_an_unlabelled_image(dock):
    # Named exactly like a run's image, but no compose label: not ours to judge.
    dock.state["images"] = [img("i1", "rc-20261007t175858z-27548-tools", ""),
                            img("i2", "postgres", "")]
    sweep(dock, DK_ORPHAN_NAME_GLOB="*")
    assert dock.images() == ["postgres:latest",
                             "rc-20261007t175858z-27548-tools:latest"]


def test_sweep_leaves_images_of_a_project_that_still_has_containers(dock):
    # A stopped stack between two `make up`s, workdir alive and not a worktree
    # of ours: the container branch declines it, and the image pass must too.
    wd = dock.tmp / "somewhere"
    wd.mkdir()
    dock.state["containers"] = [
        {"id": "c1", "project": "rc-kept", "workdir": str(wd), "created": OLD}]
    dock.state["images"] = [img("i1", "rc-kept-api", "rc-kept")]
    sweep(dock)
    assert dock.images() == ["rc-kept-api:latest"]


# ------------------------------------- images compose's classic builder made

RC_RE = "^rc-([0-9]{8}t[0-9]{6}z-[0-9]+|rc-trial-[a-z][a-z0-9]*-[0-9]+-[0-9]+)"


def test_stack_down_takes_the_classic_builders_images_of_the_project(dock):
    dock.state["images"] = [
        classic("k1", "rc-20261007t220833z-71858-rms"),
        classic("k2", "rc-20261007t220833z-71858-tools"),
        classic("k3", "rc-20261007t220833z-7185-rms"),   # another run
        img("k4", "rc-20261007t220833z-71858-x", ""),    # no compose label
        classic("k5", "rc-php-base")]
    dock.run("dk_stack_down rc-20261007t220833z-71858")
    assert dock.images() == ["rc-20261007t220833z-7185-rms:latest",
                             "rc-20261007t220833z-71858-x:latest",
                             "rc-php-base:latest"]


def test_stack_down_dry_run_counts_the_classic_builders_images(dock):
    dock.state["images"] = [classic("k1", "rc-20261007t220833z-71858-rms")]
    p = dock.run("dk_stack_down rc-20261007t220833z-71858", DK_DRY_RUN=1)
    assert "1 images" in p.stdout
    assert dock.removed_images() == []


def test_sweep_finds_a_classic_only_project_by_the_declared_name(dock):
    dock.state["images"] = [
        classic("k1", "rc-20261007t220833z-71858-rms"),
        classic("k2", "rc-rc-trial-rc-15-1960-api"),
        classic("k5", "rc-php-base"),
        classic("k6", "rc-tools", created=OLD)]
    p = sweep(dock, DK_IMAGE_PROJECT_RE=RC_RE)
    assert dock.images() == ["rc-php-base:latest", "rc-tools:latest"], p.stdout


def test_sweep_leaves_classic_images_without_a_declared_name(dock):
    dock.state["images"] = [classic("k1", "rc-20261007t220833z-71858-rms")]
    sweep(dock)
    assert dock.images() == ["rc-20261007t220833z-71858-rms:latest"]


def test_sweep_refuses_young_or_live_classic_images(dock):
    live = dock.tmp / "live.txt"
    live.write_text("/al/data/worktrees/rc-dev-agent/20261008T054537Z-7799\n")
    dock.state["images"] = [
        classic("k1", "rc-20261008t054537z-7799-rms"),
        classic("k2", "rc-20261008t060000z-1-rms", created=young())]
    sweep(dock, DK_IMAGE_PROJECT_RE=RC_RE, AL_LIVE_WORKTREES=live)
    assert len(dock.images()) == 2


# ------------------------------------------------- dk_down_prefixed (trials)

def test_down_prefixed_takes_the_trial_stacks_of_one_ticket(dock):
    dock.state["containers"] = [
        {"id": "c1", "project": "rc-rc-trial-rc-15-1960", "workdir": "/gone/trial",
         "created": young(), "image": "i1"}]
    dock.state["images"] = [
        img("i1", "rc-rc-trial-rc-15-1960-api", "rc-rc-trial-rc-15-1960", young()),
        img("i2", "rc-rc-trial-rc-15-2201-api", "rc-rc-trial-rc-15-2201", young()),
        img("i3", "rc-rc-trial-rc-150-7-api", "rc-rc-trial-rc-150-7", young()),
        img("i4", "rc-rc-trial-rc-1-5-api", "rc-rc-trial-rc-1-5", young())]
    p = dock.run("dk_down_prefixed rc-rc-trial-rc-15-")
    assert p.returncode == 0, p.stderr
    assert dock.images() == ["rc-rc-trial-rc-1-5-api:latest",
                             "rc-rc-trial-rc-150-7-api:latest"]
    assert dock.state["containers"] == []


def test_down_prefixed_spares_a_trial_whose_tree_still_exists(dock):
    tree = dock.tmp / "rc-trial-rc-15-3000"
    tree.mkdir()
    dock.state["containers"] = [
        {"id": "c1", "project": "rc-rc-trial-rc-15-3000", "workdir": str(tree),
         "created": young(), "image": "i1"}]
    dock.state["images"] = [
        img("i1", "rc-rc-trial-rc-15-3000-api", "rc-rc-trial-rc-15-3000", young())]
    p = dock.run("dk_down_prefixed rc-rc-trial-rc-15-")
    assert dock.images() == ["rc-rc-trial-rc-15-3000-api:latest"]
    assert len(dock.state["containers"]) == 1
    assert "rc-rc-trial-rc-15-3000" in p.stdout


def test_down_prefixed_finds_classic_trial_images(dock):
    dock.state["images"] = [classic("k1", "rc-rc-trial-rc-15-1960-api", young())]
    dock.run("dk_down_prefixed rc-rc-trial-rc-15-", DK_IMAGE_PROJECT_RE=RC_RE)
    assert dock.images() == []


def test_down_prefixed_refuses_an_empty_or_protected_prefix(dock):
    dock.state["images"] = [img("i1", "revenue-copilot-api", "revenue-copilot")]
    dock.run("dk_down_prefixed ''")
    dock.run("dk_down_prefixed revenue-copilot",
             DK_PROTECTED_NAMES="revenue-copilot")
    assert dock.images() == ["revenue-copilot-api:latest"]
