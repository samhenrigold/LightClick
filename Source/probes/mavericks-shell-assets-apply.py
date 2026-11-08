# Python 2.7, root inside the disposable Mojave desktop experiment.
import hashlib,json,os,plistlib,shutil,sys,tarfile,time
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):
    raise RuntimeError('Requires the Mojave clone root session')
archive,manifest=sys.argv[1:]
base='/Library/Application Support/MavericksAppearance'
work=base+'/ShellAssetBackup-'+str(int(time.time()))
os.mkdir(work,0700)
with tarfile.open(archive) as tar:
    for member in tar:
        if not member.isfile() or not member.name.startswith('icons/') or '..' in member.name.split('/'):
            raise RuntimeError('Unexpected icon payload')
        tar.extract(member,work)
report={'installed':[],'unmatched':[]}
for index,row in enumerate(json.load(open(manifest))['icons']):
    app=row['app'];payload=work+'/'+row['payload']
    if not app.startswith('/Applications/') or '..' in app.split('/'):
        raise RuntimeError('Unapproved application')
    if not os.path.isdir(app):report['unmatched'].append(app);continue
    info=plistlib.readPlist(app+'/Contents/Info.plist')
    if info.get('CFBundleIdentifier')!=row['bundleID']:
        report['unmatched'].append(app+': bundle identity differs');continue
    name=info.get('CFBundleIconFile')
    if not name:report['unmatched'].append(app+': no declared icon file');continue
    if not os.path.splitext(name)[1]:name+='.icns'
    if '/' in name or not name.endswith('.icns'):raise RuntimeError('Unexpected declared icon path')
    destination=app+'/Contents/Resources/'+name
    if os.path.islink(destination):raise RuntimeError('Icon destination is a link')
    if hashlib.sha256(open(payload,'rb').read()).hexdigest()!=row['sha256']:raise RuntimeError('Payload hash differs')
    if os.path.isfile(destination):shutil.copyfile(destination,work+'/backup-'+str(index)+'.icns')
    shutil.copyfile(payload,destination);os.chmod(destination,0644)
    if hashlib.sha256(open(destination,'rb').read()).hexdigest()!=row['sha256']:raise RuntimeError('Installed icon hash differs')
    os.utime(app,None)
    report['installed'].append({'app':app,'icon':destination,'sha256':row['sha256']})
json.dump(report,open(work+'/report.json','w'),indent=2)
print(json.dumps(report))
