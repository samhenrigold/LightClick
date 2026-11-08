#!/usr/bin/env python3
"""Parallel appearance spike, explicitly authorized by the user. Cloned app/domain, machine ID, home, TMPDIR,
ports and diagnostics; never acquires/deletes the other experiment's global lease. No original guest writes.
Usage: mavericks-appearance-try.py APP MACHINE [--reference | --final] (reference skips asset installation; use Mavericks).
"""
import base64, hashlib, json, os, plistlib, shutil, struct, subprocess, sys, time, uuid
from pathlib import Path
SOURCE=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(SOURCE/'scripts'))
from clone_lease import launch_clone, stop_owned, process_identity
ASSET_SHA256="3ad4f97797b44dd1d13030d9c90e09012542a4530610c934fee9227a52a2538c"
asset=SOURCE/"Build/mavericks-appearance/SystemAppearance.car"
if not asset.is_file() or hashlib.sha256(asset.read_bytes()).hexdigest()!=ASSET_SHA256:
    raise SystemExit("Missing/mismatched experiment asset: download https://raw.githubusercontent.com/MoonPadUSer/macOSMavericksTheme/master/SystemAppearance.car to "+str(asset)+"; expected SHA256 "+ASSET_SHA256)
app,machine=map(lambda s:Path(s).resolve(),sys.argv[1:3])
reference='--reference' in sys.argv
root=SOURCE/'Build/mavericks-appearance'/('reference-' if reference else 'run-')/str(uuid.uuid4())
root.mkdir(parents=True)
subprocess.run(['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9','-fno-objc-arc','-Wno-deprecated-declarations','-framework','Cocoa','-framework','QuartzCore',str(SOURCE/'probes/mavericks-appearance.m'),'-o',str(root/'fixture')],check=True)
if '--sdk109' in sys.argv:
    data=bytearray((root/'fixture').read_bytes()); at=32
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        command,size=struct.unpack_from('<II',data,at)
        if command==0x24: struct.pack_into('<I',data,at+12,0x000a0900)
        at+=size
    (root/'fixture').write_bytes(data)
subprocess.run(['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9','-fno-objc-arc','-Wno-deprecated-declarations','-framework','Cocoa','-framework','QuartzCore','-framework','CoreText','-dynamiclib',str(SOURCE/'compat/MavericksAppearance/MavericksAppearance.m'),'-o',str(root/'MavericksAppearance.dylib')],check=True)
shutil.copyfile(SOURCE/'probes/mavericks-appearance.m',root/'fixture-source.m')
shutil.copyfile(SOURCE/'compat/MavericksAppearance/MavericksAppearance.m',root/'library-source.m')
localapp=root/'Appearance Experiment.app' ; seed=root/'seed.vintelmac'
for a,b in ((app,localapp),(machine,seed)):subprocess.run(['cp','-c','-R',str(a),str(b)],check=True)
info=localapp/'Contents/Info.plist'; d=plistlib.loads(info.read_bytes()); d['CFBundleIdentifier']='research.lightclick.appearance.'+root.name; info.write_bytes(plistlib.dumps(d))
subprocess.run(['codesign','--force','--sign','-','--preserve-metadata=entitlements',str(localapp)],check=True)
p=seed/'Machine.plist';d=plistlib.loads(p.read_bytes());d.update(Identifier=str(uuid.uuid4()).upper(),CPUCount=2,MemoryMiB=4096,
    RetinaEnabled=False,DisplayMode="space",ClipboardEnabled=False,SSHEnabled=False,ScreenSharingEnabled=False,FileSharingEnabled=False,AudioEnabled=False)
p.write_bytes(plistlib.dumps(d))
(root/'tmp').mkdir();os.environ['TMPDIR']=str(root/'tmp')+'/'
control_root=root/'control';control_root.mkdir(mode=0o700)
channel=control_root/d['Identifier'].lower();channel.mkdir(mode=0o700)
(root/'control-channel.json').write_text(json.dumps({'directory':str(channel)}))
if '--desktop' in sys.argv:
    shim=root/'ExperimentHost.dylib'
    subprocess.run(['xcrun','clang','-dynamiclib','-framework','Cocoa',str(SOURCE/'compat/MavericksAppearance/ExperimentHost.m'),'-o',str(shim)],check=True)
    os.environ['DYLD_INSERT_LIBRARIES']=str(shim)
    if '--hidden-owner' in sys.argv:os.environ['LC_APPEARANCE_HIDDEN']='1'
process=None; identities={}
def request(command,timeout=180):
    (channel/'Result.json').unlink(missing_ok=True)
    (channel/'Request.tmp').write_text(json.dumps(command));(channel/'Request.tmp').rename(channel/'Request.json')
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if process.poll() is not None:raise RuntimeError('app exited')
        if (channel/'Result.json').exists():return json.loads((channel/'Result.json').read_text())
        time.sleep(.5)
    raise RuntimeError('request deadline; do not retry writes blindly')
def run(exe,args,timeout=180):
    r=request({'Executable':exe,'Arguments':list(map(str,args))},timeout)
    if r.get('ExitCode')!=0:raise RuntimeError(str(r))
    return r.get('Stdout','')
def stage(path):
    shutil.copyfile(path,channel/'Transfer.bin'); r=request({'Action':'stage-probe'},900)
    if 'Transfer' not in r:raise RuntimeError(str(r))
    remote=r['Transfer']['Directory']+'/Transfer.bin';run('/bin/chmod',['0755',remote]);return remote
try:
    process,identities,line,clone=launch_clone(SOURCE,[str(localapp),str(seed),str(root/'clone'),'--guest-diagnostics-root',str(control_root),'-VIMAutomaticUpdateChecks','NO','-VIMSkipPowerConfirmation','YES'])
    print(root, line,flush=True)
    end=time.monotonic()+300
    while not channel.is_dir():
        if time.monotonic()>end:raise RuntimeError('diagnostics unavailable')
        time.sleep(1)
    while True:
        r=request({'Executable':'/usr/bin/true','Arguments':[]},40)
        if r.get('ExitCode')==0:break
        if time.monotonic()>end:raise RuntimeError(str(r))
        time.sleep(3)
    request({'Action':'display-mode','Mode':'space'},60)
    if '--desktop' not in sys.argv:
        fixture=stage(root/'fixture')
        library=stage(root/'MavericksAppearance.dylib') if not reference else None
        if not reference and '--assets' in sys.argv:
            payload=stage(SOURCE/'Build/mavericks-appearance/assets/original-assets.tar')
            manifest=stage(SOURCE/'Build/mavericks-appearance/assets/manifest.json')
            script=(SOURCE/'probes/mavericks-assets-apply.py').read_text()
            applied=run('/usr/bin/python',['-c',script,payload,manifest],900)
            (root/'asset-install.json').write_text(applied)
            print('original assets',applied,flush=True)
        if not reference and (SOURCE/'Build/mavericks-appearance/assets/render-art.tar').exists():
            render=stage(SOURCE/'Build/mavericks-appearance/assets/render-art.tar')
            run('/bin/mkdir',['-p','/Library/Application Support/MavericksAppearance/Art'])
            run('/usr/bin/tar',['xf',render,'-C','/Library/Application Support/MavericksAppearance/Art'])
    reports=[]
    def capture(name,mode):
        png='/tmp/lc-appearance-'+name+'.png'
        r=run(fixture,[str(mode),png]+([library] if mode and library else []),360);(root/(name+'.json')).write_text(r)
        report=json.loads(r[r.index('{'):]);reports.append(report)
        if name!='warmup' and not (report.get('active') and report.get('keyWindow')):
            raise RuntimeError('Fixture did not become active/key; comparison rejected, see '+str(root/(name+'.json')))
        count=int(run('/usr/bin/stat',['-f','%z',png]))
        if count>4000000:raise RuntimeError('image size cap')
        data=bytearray()
        for offset in range(0,count,12000):
            data.extend(base64.b64decode(run('/usr/bin/python',['-c','import base64,sys; f=open(sys.argv[1],"rb"); f.seek(int(sys.argv[2])); print(base64.b64encode(f.read(12000)))',png,str(offset)])))
        (root/(name+'.png')).write_bytes(data)
        frame=request({'Action':'capture'},40)
        if (channel/'Frame.png').exists(): shutil.copyfile(channel/'Frame.png',root/(name+'-desktop.png'))
        print('captured',name,len(data),'font',report['systemFont'],flush=True)
    if '--desktop' not in sys.argv:
        capture('warmup',0)
        capture('prepared-native' if '--prepared' in sys.argv else 'stock',0)
        if not reference:
            if '--final' not in sys.argv:
                capture('font',1);capture('font-material',2)
            asset=stage(SOURCE/'Build/mavericks-appearance/SystemAppearance.car')
            target='/System/Library/CoreServices/SystemAppearance.bundle/Contents/Resources/SystemAppearance.car'
            run('/bin/cp',[target,target+'.appearance-spike-backup'])
            run('/bin/cp',[asset,target])
            if '--final' not in sys.argv: capture('assets',0)
            capture('combined',2)
        (root/'result.json').write_text(json.dumps({'completed':True,'fixture_sha256':hashlib.sha256((root/'fixture').read_bytes()).hexdigest(),'prepared':'--prepared' in sys.argv,'sdk109':'--sdk109' in sys.argv,'reference':reference,'reports':reports,
            'asset_source':'https://github.com/MoonPadUSer/macOSMavericksTheme','asset_sha256':hashlib.sha256((SOURCE/'Build/mavericks-appearance/SystemAppearance.car').read_bytes()).hexdigest()},indent=2))
    if '--hold' in sys.argv:
        print('HELD',root,'finish by creating Finish in this results directory',flush=True)
        deadline=time.monotonic()+(14400 if '--desktop' in sys.argv else 3600)
        while not (root/'Finish').exists() and time.monotonic()<deadline and process.poll() is None:time.sleep(1)
except BaseException as error:
    (root/'failure.txt').write_text(str(error));raise
finally:
    if process is not None:stop_owned(process,identities)
print('RESULTS',root,flush=True)
