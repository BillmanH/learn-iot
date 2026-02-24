"""
Async PowerShell script runner — ps_worker.py

Streams merged stdout+stderr line-by-line to a caller-supplied callback so the
TUI can display live script output without blocking the event loop.

Created for Phase 4: Azure Setup Panel.
"""

from __future__ import annotations

import asyncio
import pathlib
import shutil
import sys
from typing import Callable


async def run_powershell(
    script_path: str | pathlib.Path,
    args: list[str],
    on_line: Callable[[str], None],
) -> int:
    """
    Run a PowerShell script and stream every output line to on_line.

    Parameters
    ----------
    script_path : path to the .ps1 file
    args        : extra arguments passed after -File <script>
    on_line     : callback invoked with each decoded output line (no trailing newline)

    Returns     : exit code — 0 means success, non-zero or -1 means failure.

    Implementation notes
    --------------------
    * Prefers pwsh.exe (PowerShell 7) over powershell.exe (Windows PowerShell 5.1).
    * stderr is merged into stdout so a single callback sees all output.
    * Runs from the script's own directory so relative paths inside the script
      (e.g. ../config/aio_config.json) resolve correctly.
    * -NonInteractive suppresses any Read-Host prompts that would block forever.
    """
    pwsh = (
        shutil.which("pwsh")
        or shutil.which("pwsh.exe")
        or shutil.which("powershell")
        or shutil.which("powershell.exe")
    )
    if pwsh is None:
        on_line("[ERROR] PowerShell not found on PATH (tried: pwsh, pwsh.exe, powershell, powershell.exe).")
        return -1

    script_path = pathlib.Path(script_path).resolve()
    cmd: list[str] = [
        pwsh,
        "-ExecutionPolicy", "Bypass",
        "-NonInteractive",
        "-File", str(script_path),
        *args,
    ]

    try:
        import subprocess as _sp
        _flags = _sp.CREATE_NEW_PROCESS_GROUP if sys.platform == "win32" else 0
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,   # merge stderr so we see all output
            cwd=str(script_path.parent),
            creationflags=_flags,
        )
        assert proc.stdout is not None
        async for raw in proc.stdout:
            on_line(raw.decode("utf-8", errors="replace").rstrip())
        await proc.wait()
        return proc.returncode if proc.returncode is not None else 0
    except Exception as exc:
        on_line(f"[ERROR] Failed to launch PowerShell process: {exc}")
        return -1
