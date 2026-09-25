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
        "--pi-host", default=None,
        help="user@host for tests marked pi_hardware. Default: whatever "
             "tools/pissh targets (UXPLAY_PI_HOST, else the device in "
             "docs/verification-protocol.md), resolved when a test needs it.",
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


@pytest.fixture(scope="session")
def synthetic_client_binary() -> Path:
    """Path to tools/synthetic-client.cpp's binary. Deliberately always
    built from the current UxPlay/ working tree, ignoring --uxplay-ref:
    it's test infrastructure that talks real RTSP/RTP wire protocol to
    whatever server is under test, not part of what a before/after
    comparison varies -- an old --uxplay-ref before this file existed
    still gets driven by the current client, same as a real AirPlay
    client would be unaffected by which uxplay commit it happens to be
    talking to."""
    out = REPO_ROOT / "build" / "uxplay-refs" / "_synthetic-client-current" / "uxplay_debug"
    synth = out.parent / "synthetic-client"
    if not synth.exists():
        subprocess.run(["./tools/build-uxplay.sh", str(out)], cwd=REPO_ROOT, check=True)
    # build-uxplay.sh only asserts this artifact for refs whose tree has the
    # target; this fixture always builds the current tree, which must have it.
    subprocess.run(
        ["./tools/check-build-artifact.sh", str(synth)], cwd=REPO_ROOT, check=True,
    )
    return synth


class TwoProcessRunner:
    """Runs an UNMODIFIED uxplay_binary (zero special test-only flags --
    -threadtest/-ntpresynccheck/-resendstormcheck/-resendrecoverycheck and
    their backing code were removed from uxplay.cpp entirely on this
    branch) and tools/synthetic-client.cpp's binary as two genuinely
    separate OS processes sharing one container's loopback interface --
    not two threads in the server's own address space, which is what the
    old in-process driver did and the whole reason this class exists.

    uxplay_binary always gets `-ble <tmpfile>`: this plain container has
    no avahi/dbus running, so dnssd_register_raop() fails, and
    register_dnssd() failing is normally FATAL (main() tears the whole
    server down) -- `-ble` is a real, pre-existing, non-test-specific
    product flag ("BluetoothLE beacon" discovery) whose failure-tolerance
    branch (`if (ble_filename.empty())`) happens to be exactly what's
    needed here, and its write_bledata() prints the real bound RAOP port
    ("port %u") as a side effect -- used to discover the port
    synthetic-client should connect to, since raop_port is no longer a
    same-process global a test driver can just read directly.
    UX_THREADTEST_DIAG=1 is always set on the server: it only gates the
    RENDER-BUFFER-CALL/DECODED-BUFFER-OUT diagnostic prints
    (renderers/audio_renderer.c's TT_DIAG macro), never changes actual
    server behavior, and different modes need different subsets of it."""

    def __init__(self, uxplay_binary: Path, synthetic_client_binary: Path):
        self.uxplay_binary = uxplay_binary
        self.synthetic_client_binary = synthetic_client_binary
        subprocess.run(
            ["docker", "build", "-q", "-t", "rpi-airplay-buildenv", "-f", "Dockerfile", "."],
            cwd=REPO_ROOT, check=True, capture_output=True,
        )

    def _server_logs(self, name: str) -> str:
        r = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
        return r.stdout + r.stderr

    def _wait_for_port(self, name: str, timeout_s: float) -> int:
        import re
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            m = re.search(r"^port (\d+)$", self._server_logs(name), re.MULTILINE)
            if m:
                return int(m.group(1))
            time.sleep(0.2)
        raise RuntimeError(
            f"uxplay never printed its RAOP port within {timeout_s}s -- container {name} logs:\n"
            f"{self._server_logs(name)}"
        )

    def run(self, mode: str, mode_args: list[str] | None = None,
            server_args: list[str] | None = None, client_timeout_s: float = 10.0,
            settle_s: float = 0.3) -> tuple[str, str]:
        """Starts the server detached, waits for its real RAOP port, runs
        synthetic-client <mode> against it via `docker exec` (a genuinely
        separate process), waits `settle_s` for the server to finish
        logging its side of the last exchange, then tears the container
        down. Returns (server_log, client_log)."""
        name = f"uxplay-pytest-{uuid.uuid4().hex[:8]}"
        beacon_file = f"/tmp/beacon-{uuid.uuid4().hex[:8]}.dat"
        cmd = [
            "docker", "run", "-d", "--name", name,
            "-v", f"{self.uxplay_binary}:/usr/local/bin/uxplay:ro",
            "-v", f"{self.synthetic_client_binary}:/usr/local/bin/synthetic-client:ro",
            "-e", "UX_THREADTEST_DIAG=1",
            "rpi-airplay-buildenv", "stdbuf", "-oL", "-eL", "/usr/local/bin/uxplay",
            "-nohold", "-vs", "0", "-ble", beacon_file,
        ] + (server_args or [])
        subprocess.run(cmd, cwd=REPO_ROOT, check=True, capture_output=True)
        try:
            port = self._wait_for_port(name, timeout_s=5.0)
            client_cmd = [
                "docker", "exec", name, "/usr/local/bin/synthetic-client", mode,
                "--port", str(port),
            ] + (mode_args or [])
            client_proc = subprocess.run(client_cmd, capture_output=True, text=True, timeout=client_timeout_s)
            client_log = client_proc.stdout + client_proc.stderr
            time.sleep(settle_s)
            server_log = self._server_logs(name)
        finally:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        return server_log, client_log


@pytest.fixture(scope="session")
def two_process_runner(uxplay_binary, synthetic_client_binary) -> TwoProcessRunner:
    return TwoProcessRunner(uxplay_binary, synthetic_client_binary)


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


def _pissh_host() -> str:
    """tools/pissh holds the device's address; `-t` prints it without touching
    the network, so asking it here keeps one source for the whole repo (an
    addoption default would have to run at collection time, on every run)."""
    r = subprocess.run(
        ["tools/pissh", "-t"], cwd=REPO_ROOT, capture_output=True, text=True, check=True,
    )
    return r.stdout.strip()


@pytest.fixture(scope="session")
def pi_target(request) -> PiTarget:
    return PiTarget(
        host=request.config.getoption("--pi-host") or _pissh_host(),
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
