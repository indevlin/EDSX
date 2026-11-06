# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller spec for EDSX.
#
# `version` must land at the top of the bundle, the same relative position
# it occupies next to edsx.py in a checkout: edsx.py reads it at import
# time, from sys._MEIPASS when frozen. Without it the binary reports its
# version as "unknown".

import os
from pathlib import Path

block_cipher = None

# SPECPATH is injected into the spec's namespace by PyInstaller.
ROOT = Path(SPECPATH).resolve().parent  # noqa: F821

analysis = Analysis(
    ["../edsx.py"],
    pathex=[],
    binaries=[],
    datas=[(str(ROOT / "version"), ".")],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        "tkinter",
        "unittest",
        "pydoc_data",
        "test",
        "lib2to3",
        "sqlite3",
        "xml",
        "email.test",
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(analysis.pure, analysis.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    analysis.scripts,
    analysis.binaries,
    analysis.zipfiles,
    analysis.datas,
    [],
    name="EDSX",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    # A command-line tool must keep its console on Windows.
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
