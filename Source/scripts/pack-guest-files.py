#!/usr/bin/env python3
"""Move a packaged app's guest files into Runtime/GuestFiles.tar.xz and sign the app again."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--signing-identity', required=True)
args = parser.parse_args()
source = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(source/'scripts'))
from signing_options import host_options
runtime = args.app/'Contents/Resources/Runtime'
subprocess.run(['/usr/bin/tar', '--no-xattrs', '--no-mac-metadata', '-cJf', str(runtime/'GuestFiles.tar.xz'),
                '-C', str(runtime), 'OpenGLGuests', 'GuestTools'], check=True, env={'COPYFILE_DISABLE': '1'})
shutil.rmtree(runtime/'OpenGLGuests')
shutil.rmtree(runtime/'GuestTools')
subprocess.run(['/usr/bin/codesign', '--force', '--sign', args.signing_identity, *host_options(args.signing_identity),
                '--entitlements', str(source/'support/App.entitlements'), str(args.app)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
