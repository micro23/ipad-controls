#!/usr/bin/env python3
"""Build a credential-free macOS app using Apple's Swift command-line tools."""
from pathlib import Path
import os, platform, plistlib, shutil, subprocess
root=Path(__file__).resolve().parents[1]
app=root/'dist/iPad Controls.app'
resources=app/'Contents/Resources'; binary=app/'Contents/MacOS'
resources.mkdir(parents=True,exist_ok=True);binary.mkdir(exist_ok=True)
# Copy only the bridge, never a developer's existing app/resources or configuration.
shutil.copyfile(root/'src/bridge.py',resources/'bridge.py')
subprocess.run(['swiftc','-O','-target',platform.machine()+'-apple-macos13.0','-module-cache-path',str(root/'build/module-cache'),'-debug-prefix-map',str(root)+'=/src','-framework','Cocoa','-framework','CoreGraphics','src/App.swift','-o',str(binary/'iPad Controls')],cwd=root,check=True)
info={'CFBundleExecutable':'iPad Controls','CFBundleIdentifier':'org.ipadcontrols.mac','CFBundleName':'iPad Controls','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1','NSHighResolutionCapable':True,'LSMinimumSystemVersion':'13.0'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
print(app)
