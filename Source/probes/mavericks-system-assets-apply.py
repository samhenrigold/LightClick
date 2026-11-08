# Python 2.7 inside the disposable Mojave guest. Source is an attached read-only Mavericks disk.
import hashlib,json,os,plistlib,shutil,subprocess,sys,time
def read_plist(path):
    try:return plistlib.readPlist(path)
    except Exception:return plistlib.readPlistFromString(subprocess.check_output(['/usr/bin/plutil','-convert','xml1','-o','-',path]))
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):
    raise RuntimeError('Requires the Mojave experiment root session')
sources=[]
for name in os.listdir('/Volumes'):
    path='/Volumes/'+name
    version=path+'/System/Library/CoreServices/SystemVersion.plist'
    if not os.path.isfile(version):continue
    info=read_plist(version)
    if info.get('ProductVersion','').startswith('10.9.') and os.statvfs(path).f_flag & 1:
        sources.append(path)
if len(sources)!=1:raise RuntimeError('Requires exactly one read-only Mavericks source volume: '+repr(sources))
source=sources[0]
base='/Library/Application Support/MavericksAppearance'
backup=base+'/SystemAssetBackup-'+str(int(time.time()))
os.makedirs(backup,0700)
image_ext=('.png','.icns','.tif','.tiff','.jpg','.jpeg','.gif','.pdf','.clr')
font_ext=('.ttf','.ttc','.otf','.dfont')
report={'source':source,'backup':backup,'replaced':[],'added':[],'identical':0,'unmatched':0,'semanticIcons':[]}
def digest(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        while True:
            data=f.read(1048576)
            if not data:break
            h.update(data)
    return h.hexdigest()
def install(src,dst,kind):
    if os.path.islink(src) or os.path.islink(dst):return
    relative=dst.lstrip('/')
    if not relative.startswith(('Applications/','System/Library/','Library/Desktop Pictures/')):
        raise RuntimeError('Destination outside system appearance roots')
    if '..' in relative.split('/'):raise RuntimeError('Noncanonical asset path')
    old=os.path.isfile(dst);sha=digest(src)
    if old and digest(dst)==sha:report['identical']+=1;return
    if old:
        saved=backup+'/'+relative
        if not os.path.isdir(os.path.dirname(saved)):os.makedirs(os.path.dirname(saved))
        shutil.copyfile(dst,saved)
    parent=os.path.dirname(dst)
    if not os.path.isdir(parent):os.makedirs(parent)
    next_file=dst+'.mavericks-asset-next'
    shutil.copyfile(src,next_file);os.chmod(next_file,0644);os.rename(next_file,dst)
    if digest(dst)!=sha:raise RuntimeError('Installed asset differs: '+dst)
    row={'path':dst,'kind':kind,'sha256':sha};report['replaced' if old else 'added'].append(row)
    with open(backup+'/journal.jsonl','a') as journal:journal.write(json.dumps(dict(row,replaced=old))+'\n')
def destination_bundle_exists(relative):
    parts=relative.split('/')
    for index,part in enumerate(parts):
        if part.endswith(('.app','.prefPane','.framework','.bundle','.plugin','.menu')):
            if not os.path.isdir('/'+'/'.join(parts[:index+1])):return False
    return True
for prefix in ('Applications','System/Library','Library/Desktop Pictures'):
    for root,dirs,files in os.walk(source+'/'+prefix,followlinks=False):
        dirs[:]=sorted(d for d in dirs if not os.path.islink(root+'/'+d))
        relative=root[len(source)+1:]
        if not destination_bundle_exists(relative):
            report['unmatched']+=len(files);dirs[:]=[];continue
        # Resolve each bundle's declared icon, allowing its filename to change between releases.
        if root.endswith('/Contents') and 'Info.plist' in files:
            target='/'+relative
            if os.path.isfile(target+'/Info.plist'):
                try:
                    old=read_plist(root+'/Info.plist');new=read_plist(target+'/Info.plist')
                    if old.get('CFBundleIdentifier')==new.get('CFBundleIdentifier'):
                        old_name=old.get('CFBundleIconFile');new_name=new.get('CFBundleIconFile')
                        if old_name and new_name and '/' not in old_name and '/' not in new_name:
                            if not os.path.splitext(old_name)[1]:old_name+='.icns'
                            if not os.path.splitext(new_name)[1]:new_name+='.icns'
                            original=root+'/Resources/'+old_name;destination=target+'/Resources/'+new_name
                            if os.path.isfile(original) and original.lower().endswith(image_ext):
                                install(original,destination,'declared bundle icon')
                                report['semanticIcons'].append(destination)
                except Exception:pass
        for name in sorted(files):
            src=root+'/'+name;dst='/'+relative+'/'+name
            if os.path.islink(src):continue
            is_font=name.lower().endswith(font_ext)
            if not (name.lower().endswith(image_ext) or is_font):continue
            # Resource artwork and system fonts only; no executable code, UI archives, documents or user data.
            if '/Resources/' not in src and not relative.startswith(('System/Library/Fonts','Library/Desktop Pictures')):continue
            # Preserve newer character coverage; original font files also remain available in the appearance font catalog.
            if is_font:
                font_dir=base+'/Fonts/Original/'+relative
                if not os.path.isdir(font_dir):os.makedirs(font_dir)
                if not os.path.isfile(font_dir+'/'+name):shutil.copyfile(src,font_dir+'/'+name)
                if name!='LucidaGrande.ttc':continue
            if not os.path.isfile(dst) and not os.path.isdir(os.path.dirname(dst)):
                report['unmatched']+=1;continue
            install(src,dst,'font' if is_font else 'resource artwork')
json.dump(report,open(backup+'/report.json','w'),indent=2)
print(json.dumps({'source':source,'backup':backup,'replaced':len(report['replaced']),'added':len(report['added']),
                  'identical':report['identical'],'unmatched':report['unmatched'],'semanticIcons':len(report['semanticIcons'])}))
