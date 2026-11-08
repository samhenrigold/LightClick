#!/usr/bin/env python3
"""Extract the stock fallback catalog from a read-only Mojave Base System."""
import argparse,hashlib,json,os,plistlib,shutil
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('volume',type=Path);args=p.parse_args();root=args.volume.resolve(strict=True)
if not os.statvfs(root).f_flag&os.ST_RDONLY:raise SystemExit('Read-only Mojave source required')
version=plistlib.loads((root/'System/Library/CoreServices/SystemVersion.plist').read_bytes())
if not version.get('ProductVersion','').startswith('10.14.'):raise SystemExit('Mojave Base System required')
bundle=root/'System/Library/CoreServices/SystemAppearance.bundle/Contents';source=bundle/'Resources/SystemAppearance.car';data=source.read_bytes()
seal=plistlib.loads((bundle/'_CodeSignature/CodeResources').read_bytes());digest=hashlib.sha256(data).digest()
if digest!=seal['files2']['Resources/SystemAppearance.car']['hash2']:raise SystemExit('Original catalog does not match signed resource')
out=Path(__file__).resolve().parents[1]/'Build/mavericks-appearance/assets';out.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,out/'native-mojave-SystemAppearance.car')
(out/'native-mojave-catalog.json').write_text(json.dumps({'source':str(source),'version':version,'sha256':digest.hex()},indent=2)+'\n')
print(out/'native-mojave-SystemAppearance.car')
