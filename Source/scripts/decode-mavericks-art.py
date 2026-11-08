#!/usr/bin/env python3
"""Decode original Mavericks ArtFile/ArtFile200 images for renderer research.
Uses the published container layout (alexzielenski/artFileTool) with independently validated premultiplied BGRA.
Only writes generated PNG/JSON files beneath the supplied original-assets directory; never patches an OS.
"""
import hashlib,json,struct,sys,zlib
from pathlib import Path
root=Path(sys.argv[1]).resolve();out=root/'decoded-art';out.mkdir(exist_ok=True)
def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
def png(path,blob,width,height):
    rgba=bytearray(len(blob))
    for i in range(0,len(blob),4):
        alpha=blob[i+3];rgba[i+3]=alpha
        if alpha:
            for target,offset in ((0,2),(1,1),(2,0)):
                if blob[i+offset]>alpha:raise ValueError('Unexpected non-premultiplied sample')
                rgba[i+target]=min(255,(blob[i+offset]*255+alpha//2)//alpha)
    scan=b''.join(b'\0'+rgba[y*width*4:(y+1)*width*4] for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'sRGB',b'\0')+chunk(b'IDAT',zlib.compress(scan))+chunk(b'IEND',b''))
def decode(path):
    data=path.read_bytes();count,depth,tag_count,tag_offset,names_offset,file_offset,bitmap_offset=struct.unpack_from('<HHIIIII',data)
    if depth!=8 or not count or count>10000:raise ValueError('Unexpected ArtFile header')
    tags={}
    for i in range(tag_count):
        offset,index=struct.unpack_from('<II',data,tag_offset+i*8);start=names_offset+offset
        tags[index]=data[start:data.index(b'\0',start)].decode('ascii')
    for index in range(count):
        at=file_offset+index*12;offset=bitmap_offset+struct.unpack_from('<I',data,at)[0]
        names=[tags[tag] for tag in data[at+4:at+12] if tag in tags]
        rows,columns=struct.unpack_from('<HH',data,offset)
        if not 1<=rows<=3 or not 1<=columns<=3:raise ValueError('Invalid slice layout')
        row_heights=struct.unpack_from('<HHH',data,offset+30)[:rows];column_widths=struct.unpack_from('<HHH',data,offset+36)[:columns]
        width,height=sum(column_widths),sum(row_heights);length=width*height*4;blob=data[offset+44:offset+44+length]
        if not width or not height or len(blob)!=length:raise ValueError('Invalid bitmap bounds')
        yield {'index':index,'tags':names,'width':width,'height':height,'rows':list(row_heights),'columns':list(column_widths)},blob
records=[];by_tags={}
for row,blob in decode(root/'ArtFile.bin'):
    row['file']='%04d.png'%row['index'];png(out/row['file'],blob,row['width'],row['height']);records.append(row);by_tags[tuple(row['tags'])]=row
retina=[]
for row,blob in decode(root/'ArtFile200.bin'):
    base=by_tags.get(tuple(row['tags']))
    if not base or row['width']!=base['width']*2 or row['height']!=base['height']*2:continue
    name=base['file'].replace('.png','@2x.png');png(out/name,blob,row['width'],row['height']);retina.append({'base':base['file'],'retina':name,'retina_index':row['index']})
(out/'manifest.json').write_text(json.dumps(records,indent=2));(out/'retina-manifest.json').write_text(json.dumps(retina,indent=2))
(out/'provenance.json').write_text(json.dumps({'alpha':'premultiplied BGRA converted to straight RGBA PNG','sources':{name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in ('ArtFile.bin','ArtFile200.bin')}},indent=2))
print(len(records),'base images;',len(retina),'matched Retina renditions')
# SArtFile carries auxiliary artwork and PDF/vector representations. Validate the same alpha invariant.
shared=(root/'SArtFile.bin').read_bytes();version,count,base=struct.unpack_from('<HHI',shared)
if version!=2 or count>10000:raise ValueError('Unsupported shared-art header')
shared_out=root/'decoded-sart';shared_out.mkdir(exist_ok=True);shared_records=[]
for index in range(count):
    at=struct.unpack_from('<I',shared,8+index*4)[0];kind,representations=struct.unpack_from('<HH',shared,at)
    for rep in range(representations):
        width,height,length,offset=struct.unpack_from('<HHII',shared,at+4+rep*12);blob=shared[base+offset:base+offset+length]
        if len(blob)!=length:raise ValueError('Invalid shared-art bounds')
        row={'index':index,'representation':rep,'kind':kind,'width':width,'height':height}
        if blob.startswith(b'%PDF'):
            name='%03d-%d.pdf'%(index,rep);(shared_out/name).write_bytes(blob)
        elif width and height and length==width*height*4:
            name='%03d-%d.png'%(index,rep);png(shared_out/name,blob,width,height)
        else:raise ValueError('Unknown shared-art representation')
        row['file']=name;shared_records.append(row)
(shared_out/'manifest.json').write_text(json.dumps(shared_records,indent=2));print(len(shared_records),'shared-art representations')
