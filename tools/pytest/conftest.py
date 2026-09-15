"""Shared fixtures for the e2e suite. Every fixture here wraps a pattern
already proven in the bash scripts these tests replace (docker run ...
rpi-airplay-buildenv, sshpass ssh/scp) rather than inventing a new way to
drive uxplay or reach the Pi -- see tools/pytest/README.md and the plan
this suite was built from (docs/bugs/... for the bug each test guards).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import time
import uuid
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SSH_OPTS = [
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "PreferredAuthentications=password",
    "-o", "PubkeyAuthentication=no",
]


def pytest_addoption(parser):
    parser.addoption(
        "--uxplay-ref", default=None,
        help="Build uxplay from this git ref (via a temporary `git worktree` of "
             "the UxPlay submodule) instead of the current working tree. Use this "
             "to demonstrate a bug: run the whole suite once with --uxplay-ref "
             "<parent-of-fix-commit> (expect real failures), then again with no "
             "flag / against HEAD (expect PASS).",
    )
    parser.addoption(
        "--pi-host", default=os.environ.get("UXPLAY_PI_HOST", "root@192.168.1.34"),
        help="user@host for tests marked pi_hardware.",
    )
    parser.addoption(
        "--pi-password", default=os.environ.get("UXPLAY_SSH_PASSWORD", "dietpi"),
        help="SSH password for --pi-host.",
    )
    parser.addoption(
        "--trace-dir", default=str(REPO_ROOT / "build" / "traces"),
        help="Where Perfetto traces get written. Point this at two different "
             "directories across an old-ref run and a current-HEAD run to keep "
             "both sets of evidence side by side.",
    )
    parser.addoption(
        "--extra-uxplay-args", default="",
        help="Extra uxplay_debug CLI args for tests that support it (e.g. "
             "-bt709 for test_resolution_change_gap), space-separated.",
    )


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "pi_hardware: needs the real Pi reachable at --pi-host (skip with -m 'not pi_hardware')"
    )


@pytest.fixture(scope="session")
def trace_dir(request) -> Path:
    d = Path(request.config.getoption("--trace-dir"))
    d.mkdir(parents=True, exist_ok=True)
    return d


@pytest.fixture(scope="session")
def uxplay_binary(request) -> Path:
    """Path to the built uxplay_debug binary under test for this whole
    pytest run. Default: the current UxPlay/ working tree (matches every
    existing bash script's unconditional `make uxplay`). --uxplay-ref
    builds a specific commit instead, via a throwaway `git worktree` so
    the real submodule checkout is never touched. Cached per ref so a
    repeated run (e.g. re-running the same old-ref comparison) doesn't
    rebuild."""
    ref = request.config.getoption("--uxplay-ref")
    tag = ref if ref else "worktree"
    out = REPO_ROOT / "build" / "uxplay-refs" / tag / "uxplay_debug"
    if out.exists():
        return out

    if ref is None:
        subprocess.run(
            ["./tools/build-uxplay.sh", str(out)], cwd=REPO_ROOT, check=True,
        )
        return out

    worktree = REPO_ROOT / "build" / "uxplay-refs" / f"_worktree-{uuid.uuid4().hex[:8]}"
    subprocess.run(
        ["git", "-C", "UxPlay", "worktree", "add", "--detach", str(worktree), ref],
        cwd=REPO_ROOT, check=True,
    )
    try:
        subprocess.run(
            ["./tools/build-uxplay.sh", str(out), str(worktree)], cwd=REPO_ROOT, check=True,
        )
    finally:
        subprocess.run(
            ["git", "-C", "UxPlay", "worktree", "remove", "--force", str(worktree)],
            cwd=REPO_ROOT, check=False,
        )
    return out


class DockerRunner:
    """Runs uxplay_binary inside the shared buildenv container with given
    args/env, capturing combined stdout+stderr to a log file. Mirrors the
    `docker run --rm --name ... -v uxplay_debug:/usr/local/bin/uxplay:ro
    rpi-airplay-buildenv ...` pattern the 3 Docker-only bash scripts used."""

    def __init__(self, binary: Path):
        self.binary = binary
        subprocess.run(
            ["docker", "build", "-q", "-t", "rpi-airplay-buildenv", "-f", "Dockerfile", "."],
            cwd=REPO_ROOT, check=True, capture_output=True,
        )

    def run(self, args: list[str], env: dict | None = None, timeout_s: float = 10.0, log_path: Path | None = None) -> str:
        """Runs uxplay with `args` for up to timeout_s, then force-stops
        the container. Returns the captured log text. A bounded timeout,
        not a wait-for-exit: the driver flags this suite uses
        (-ntpresynccheck, -resendstormcheck, -threadtest N) either run
        the real main_loop() forever or need an explicit kill regardless,
        matching the bash scripts' own sleep-then-kill shape."""
        name = f"uxplay-pytest-{uuid.uuid4().hex[:8]}"
        cmd = ["docker", "run", "--rm", "--name", name,
               "-v", f"{self.binary}:/usr/local/bin/uxplay:ro"]
        for k, v in (env or {}).items():
            cmd += ["-e", f"{k}={v}"]
        cmd += ["rpi-airplay-buildenv", "/usr/local/bin/uxplay"] + args

        log_file = open(log_path, "wb") if log_path else subprocess.PIPE
        proc = subprocess.Popen(cmd, cwd=REPO_ROOT, stdout=log_file, stderr=subprocess.STDOUT)
        try:
            out, _ = proc.communicate(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            subprocess.run(["docker", "kill", name], capture_output=True)
            out, _ = proc.communicate(timeout=10)
        finally:
            if log_path:
                log_file.close()

        if log_path:
            return log_path.read_text(errors="replace")
        return (out or b"").decode(errors="replace")


@pytest.fixture(scope="session")
def docker_runner(uxplay_binary) -> DockerRunner:
    return DockerRunner(uxplay_binary)


class PiTarget:
    """Wraps the sshpass ssh/scp pattern every Pi-hardware bash script
    already used (same SSH_OPTS, same password default)."""

    def __init__(self, host: str, password: str):
        self.host = host
        self.password = password

    def ssh(self, command: str, timeout: float | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["sshpass", "-p", self.password, "ssh", *SSH_OPTS, self.host, command],
            capture_output=True, text=True, timeout=timeout,
        )

    def scp_to(self, local: Path, remote: str) -> None:
        subprocess.run(
            ["sshpass", "-p", self.password, "scp", "-o", "StrictHostKeyChecking=accept-new", str(local), f"{self.host}:{remote}"],
            check=True, capture_output=True,
        )

    def scp_from(self, remote: str, local: Path) -> None:
        subprocess.run(
            ["sshpass", "-p", self.password, "scp", "-o", "StrictHostKeyChecking=accept-new", f"{self.host}:{remote}", str(local)],
            check=True, capture_output=True,
        )

    def ping_once(self) -> bool:
        host_only = self.host.split("@")[-1]
        r = subprocess.run(["ping", "-c", "1", "-t", "1", host_only], capture_output=True)
        return r.returncode == 0

    def wait_reachable(self, timeout_s: float = 90) -> bool:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if self.ping_once():
                return True
            time.sleep(1)
        return False

    def wait_service_active(self, unit: str = "uxplay.service", timeout_s: float = 120) -> bool:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            r = self.ssh(f"systemctl is-active {unit}", timeout=10)
            if r.stdout.strip() == "active":
                return True
            time.sleep(2)
        return False


@pytest.fixture(scope="session")
def pi_target(request) -> PiTarget:
    return PiTarget(
        host=request.config.getoption("--pi-host"),
        password=request.config.getoption("--pi-password"),
    )


@pytest.fixture(scope="function")
def pi_uxplay_deployed(request, pi_target, uxplay_binary):
    """Stops the live service, deploys uxplay_binary to the Pi, and
    restores the live service (with whatever binary was there before)
    when the test finishes -- regardless of pass/fail. Writing straight
    to /usr/local/bin/uxplay_debug can fail with ETXTBSY while the
    service holds it open (seen live this same investigation), so this
    always stops the service first."""
    pi_target.ssh("systemctl stop uxplay.service", timeout=15)
    remote_tmp = f"/tmp/uxplay_debug.{uuid.uuid4().hex[:8]}"
    pi_target.scp_to(uxplay_binary, remote_tmp)
    pi_target.ssh(f"mv {remote_tmp} /usr/local/bin/uxplay_debug && chmod +x /usr/local/bin/uxplay_debug", timeout=15)
    try:
        yield pi_target
    finally:
        pi_target.ssh("systemctl start uxplay.service", timeout=15)


def _require_binaries(*names: str) -> None:
    missing = [n for n in names if shutil.which(n) is None]
    if missing:
        pytest.skip(f"missing required binaries: {', '.join(missing)}")


@pytest.fixture(scope="session", autouse=True)
def _check_host_tools():
    _require_binaries("docker", "sshpass", "ssh", "scp", "git")
