#!/usr/bin/env python3
"""Add Mojave iOSMac loader compatibility and a no-op i386 slice.

The actual appearance implementation remains native macOS x86_64. Unsupported
process platforms keep native rendering instead of failing before application main.
"""
import argparse,struct,subprocess,tempfile
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('library',type=Path);args=p.parse_args()
data=bytearray(args.library.read_bytes());magic,cpu,subtype,kind,count,size,flags,reserved=struct.unpack_from('<8I',data)
if magic!=0xfeedfacf or cpu!=0x1000007:raise RuntimeError('Expected the newly linked x86_64 library')
commands=[];offset=32;first_data=len(data)
for i in range(count):
    cmd,length=struct.unpack_from('<II',data,offset);raw=bytes(data[offset:offset+length])
    if cmd==0x19:
        sections=struct.unpack_from('<I',data,offset+64)[0]
        for index in range(sections):
            fileoff=struct.unpack_from('<I',data,offset+72+index*80+48)[0]
            if fileoff:first_data=min(first_data,fileoff)
    if cmd!=0x1d:commands.append(raw) # Signing happens after metadata preparation, if needed.
    offset+=length
commands.append(struct.pack('<6I',0x32,24,6,0x000c0000,0x000c0000,0))
encoded=b''.join(commands)
if 32+len(encoded)>first_data:raise RuntimeError('Link with sufficient header padding')
struct.pack_into('<II',data,16,len(commands),len(encoded));data[32:32+len(encoded)]=encoded
# An inert i386 dylib needs no imports, exports or initializers. Modern Apple
# linkers no longer emit i386 dylibs; describe the standard Mach-O image directly.
def segment(name,address,fileoff,filesize,prot):return struct.pack('<II16s8I',1,56,name.encode().ljust(16,b'\0'),address,4096,fileoff,filesize,7,prot,0,0)
name=b'@rpath/MavericksAppearance.dylib\0';length=(24+len(name)+3)&~3
identity=struct.pack('<6I',0xd,length,24,0,0,0)+name;identity=identity.ljust(length,b'\0')
small_commands=[segment('__TEXT',0,0,4096,5),segment('__LINKEDIT',4096,4096,16,1),identity,struct.pack('<12I',0x80000022,48,*([0]*10)),struct.pack('<6I',2,24,4096,0,4096,4),struct.pack('<20I',0xb,80,*([0]*18)),struct.pack('<4I',0x24,16,0x000a0900,0x000a0e00)]
small_body=b''.join(small_commands);small=struct.pack('<7I',0xfeedface,7,3,6,len(small_commands),len(small_body),0x85)+small_body
small=small.ljust(4112,b'\0')
with tempfile.TemporaryDirectory(prefix='lcmav-injection-')as work:
    root=Path(work);(root/'x64.dylib').write_bytes(data);(root/'i386.dylib').write_bytes(small)
    subprocess.run(['xcrun','lipo','-create',str(root/'x64.dylib'),str(root/'i386.dylib'),'-output',str(root/'universal.dylib')],check=True)
    args.library.write_bytes((root/'universal.dylib').read_bytes())
print('Prepared macOS/iOSMac x86_64 and inert i386 injection image')
