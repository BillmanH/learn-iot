# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller spec for AIO Manager
# Build from the REPO ROOT with:
#   uv run --extra ui pyinstaller --distpath . textual/aio_manager.spec
# Output: aio-manager.exe  (placed at the repo root, tracked in git)
#
# The exe lives at the repo root alongside config/ and external_configuration/
# so it auto-locates aio_config.json and the PowerShell scripts when run.

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

# Collect Textual's built-in CSS / widget assets
textual_datas = collect_data_files("textual")

# Rich ships Unicode data as package data files (e.g. unicode17-0-0) which
# cannot be collected as normal Python modules due to hyphens in the name.
rich_datas = collect_data_files("rich", include_py_files=True)

# Collect ALL Textual and Rich submodules — avoids whack-a-mole with private modules
textual_hiddenimports = collect_submodules("textual")
rich_hiddenimports = collect_submodules("rich")

a = Analysis(
    # Entry point — path relative to this spec file (i.e. textual/)
    ["aio_manager.py"],

    # Add the textual/ subfolder to sys.path so local package imports resolve:
    #   from models.state import AppState
    #   from screens.main_screen import MainScreen  etc.
    pathex=["."],

    binaries=[],

    # Bundle Textual and Rich package data (themes, bundled CSS, Unicode tables)
    datas=textual_datas + rich_datas,

    # Local subpackages — PyInstaller won't always auto-detect these because
    # they are imported via dynamic sys.path manipulation in aio_manager.py.
    hiddenimports=textual_hiddenimports + rich_hiddenimports + [
        "screens",
        "screens.main_screen",
        "screens.create_config_modal",
        "screens.oid_input_modal",
        "panels",
        "panels.edge_panel",
        "panels.azure_panel",
        "panels.config_panel",
        "workers",
        "workers.azure_build_worker",
        "workers.check_worker",
        "workers.ps_worker",
        "models",
        "models.state",
        "models.config_loader",
    ],

    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    # Embed everything into the single exe (equivalent to --onefile)
    a.binaries,
    a.datas,
    [],
    name="aio-manager",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    # Textual REQUIRES a real console — do NOT set console=False
    console=True,
    disable_windowed_traceback=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
