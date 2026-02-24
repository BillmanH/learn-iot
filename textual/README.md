# AIO Manager

A terminal UI (TUI) for installing Azure IoT Operations on an edge device.
Built with [Textual](https://textual.textualize.io/) and runs on the Windows management machine.

> **This is an installation helper, not a monitoring tool.**
> It orchestrates the four scripts in the repo into a single guided workflow so you never have to remember which script to run next or cross-reference outputs by hand.

---

## What it does

The AIO installation workflow spans two machines (the edge device and the Windows management machine) and four separate scripts. AIO Manager puts a TUI on top of it so everything is visible in one place.



### The three panels

| Panel | What it does |
|---|---|
| **Config** | Loads `config/aio_config.json`, shows every field with its description and validation status (OK / MISSING / ON / OFF) across four tabs: Azure, Cluster, Deployment, Tools. Opens the file in your editor, reloads live. If the file doesn't exist it offers to create a blank or default template. |
| **Edge** | Runs seven read-only checks against your local `az` session and `kubectl` to verify that `installer.sh` and `arc_enable.ps1` have already been run successfully on the edge device. No SSH required — it uses the kubeconfig path from your config file. Failing checks include a `FIX:` line in the log. |
| **Azure Setup** | Streams output from `External-Configurator.ps1` and `grant_entra_id_roles.ps1`. Each Azure resource (Key Vault, Storage Account, Schema Registry, IoT Operations, Role Assignments) has a live step indicator (○ → ⟳ → ✓ / ✗). Pre-populates already-deployed resources from `config/deployment_summary.json` so re-runs don't restart from zero. |

### The log pane

Every action from all three panels writes to the scrollable log at the bottom. It is also written to `aio_manager.log` in the repo root so you can open it in any text editor and freely copy `az` CLI commands — Ctrl+C in a Windows terminal intercepts too early to be useful.

---

## Running (requires Python / uv)

```powershell
# From the repo root
uv sync --extra ui
uv run --extra ui textual/aio_manager.py
```

Requires Python 3.12+ and [uv](https://docs.astral.sh/uv/). Textual needs a real terminal that supports 256 colors — Windows Terminal or PowerShell 7 work well.

---

## Running the pre-built executable

No Python, no uv, no dependencies required.

```powershell
# From the repo root
.\aio-manager.exe
```

`aio-manager.exe` is included at the repo root. It looks for `config/aio_config.json` and `external_configuration/` relative to its own location, so run it from the repo root (or a directory containing those folders).

---

## Building the executable yourself

```powershell
# From the repo root — requires uv sync --extra ui to have been run first
uv run --extra ui pyinstaller --distpath . textual/aio_manager.spec
```

Output: `aio-manager.exe` in the repo root (~12 MB, single file, no installer needed).

The spec file is at [textual/aio_manager.spec](aio_manager.spec). Key settings:
- `--onefile` — everything embedded in one exe
- `console=True` — Textual requires a real console, windowed mode will not work
- `collect_data_files("textual")` — bundles Textual's built-in themes and widget assets
- All local subpackages (`screens/`, `panels/`, `workers/`, `models/`) listed as hidden imports

Build artefacts (`build/`, `dist/`) are in `.gitignore` — only the final exe at the repo root is committed.

---

## Prerequisites for the checks and scripts

The app shells out to existing tools — it does not re-implement them. These must be on your `PATH`:

| Tool | Used for |
|---|---|
| `az` (Azure CLI) | Arc connectivity checks and Azure resource deployment |
| `kubectl` | Edge verification checks (pod status, CRDs, RBAC) |
| `pwsh` (PowerShell 7) | Running `External-Configurator.ps1` and `grant_entra_id_roles.ps1` |

The `kubeconfig_path` field in `config/aio_config.json` tells the app where your kubeconfig lives (typically the file copied from the edge device after `arc_enable.ps1` runs).

---

## Source layout

```
textual/
├── aio_manager.py          Entry point — App class, worker crash handler
├── aio_manager.spec        PyInstaller build spec
├── PLAN.md                 Original design and phase tracking doc
├── models/
│   ├── state.py            Central reactive state (AppState, StepState, etc.)
│   └── config_loader.py    Loads aio_config.json, maps comments to field descriptions
├── screens/
│   ├── main_screen.py      Single-screen layout, log helpers, button routing
│   ├── create_config_modal.py  First-run modal: create blank or default config
│   └── oid_input_modal.py  Prompt for Object ID before granting Entra ID permissions
├── panels/
│   ├── config_panel.py     Config tabbed DataTable, validate/reload/open buttons
│   ├── edge_panel.py       Seven step-rows + Check Edge Deployment button
│   └── azure_panel.py      Five step-rows + Build Azure / Grant Entra ID buttons
├── workers/
│   ├── check_worker.py     Async edge check functions (az CLI + kubectl)
│   ├── ps_worker.py        Async PowerShell script runner (streams output line by line)
│   └── azure_build_worker.py  Orchestrates External-Configurator.ps1 and parses output
└── styles/
    └── app.tcss            Textual CSS (not used in the frozen exe — embedded in main_screen.py)
```
