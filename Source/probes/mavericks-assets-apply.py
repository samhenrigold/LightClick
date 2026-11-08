# Python 2.7 inside an explicitly disposable Mojave guest, invoked by the appearance runner.
import hashlib,json,os,shutil,sys,tarfile
archive,manifest_path=sys.argv[1:]
manifest=json.load(open(manifest_path))
if not os.uname()[2].startswith('18.') or os.getuid()!=0:raise RuntimeError('Mojave root session required')
work=os.path.dirname(archive)+'/appearance-assets'
os.mkdir(work,0700)
with tarfile.open(archive) as tar:
    for member in tar:
        if not member.isfile() or not member.name.startswith('files/') or not member.name[6:].isdigit():raise RuntimeError('unexpected payload member')
        tar.extract(member,work)
report={'installed':[],'unmatched':[]}
for i,row in enumerate(manifest['files']):
    dst=row['destination'];src=work+'/'+row['payload']
    if not dst.startswith(('/Applications/','/System/Library/CoreServices/','/System/Library/Frameworks/ApplicationServices.framework/','/Library/Application Support/MavericksAppearance/Fonts/','/Library/Desktop Pictures/')):raise RuntimeError('unapproved asset destination')
    if '..' in dst.split('/') or os.path.islink(dst):raise RuntimeError('noncanonical destination')
    if hashlib.sha256(open(src,'rb').read()).hexdigest()!=row['sha256']:raise RuntimeError('payload hash mismatch')
    new=row['kind'] in ('original UI font','wallpaper')
    if not os.path.isfile(dst) and not new:
        report['unmatched'].append(dst);continue
    parent=os.path.dirname(dst)
    if not os.path.isdir(parent):os.makedirs(parent,0755)
    if os.path.isfile(dst):shutil.copyfile(dst,work+'/backup-'+str(i))
    shutil.copyfile(src,dst);os.chmod(dst,0644)
    if hashlib.sha256(open(dst,'rb').read()).hexdigest()!=row['sha256']:raise RuntimeError('installed hash mismatch')
    report['installed'].append(dst)
json.dump(report,open(work+'/report.json','w'),indent=2)
print(json.dumps({'installed':len(report['installed']),'unmatched':len(report['unmatched']),'report':work+'/report.json'}))
