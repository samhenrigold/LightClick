# Repair the stock fallback catalog; legacy controls use the isolated renderer.
import hashlib,json,os,plistlib,shutil,subprocess,sys,tempfile
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave experiment root required')
base='/System/Library/CoreServices/SystemAppearance.bundle/Contents'
seal=plistlib.readPlistFromString(subprocess.check_output(['/usr/bin/plutil','-convert','xml1','-o','-',base+'/_CodeSignature/CodeResources']))
expected=seal['files2']['Resources/SystemAppearance.car']['hash2'].data
source=sys.argv[1];data=open(source,'rb').read()
if hashlib.sha256(data).digest()!=expected:raise RuntimeError('Catalog does not match the signed resource for this Mojave build')
target=base+'/Resources/SystemAppearance.car'
if hashlib.sha256(open(target,'rb').read()).digest()==expected:print(json.dumps({'nativeCatalogAlreadyValid':True}));sys.exit(0)
work=tempfile.mkdtemp(prefix='NativeCatalogRepair-',dir='/Library/Application Support/MavericksAppearance')
shutil.copyfile(target,work+'/PreviousSystemAppearance.car')
next_file=target+'.mavericks-native-next';shutil.copyfile(source,next_file);os.chmod(next_file,0644);os.rename(next_file,target)
assert hashlib.sha256(open(target,'rb').read()).digest()==expected
print(json.dumps({'nativeCatalogRestored':True,'sha256':expected.encode('hex'),'backup':work}))
