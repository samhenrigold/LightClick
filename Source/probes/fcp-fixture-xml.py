#!/usr/bin/env python3
"""Generate the fixed 8s ProRes fixture's FCPXML1.3; never launches/imports/exports.

Guest paths are validated receipt strings, not host filesystem locations. The caller
must verify the clip hash and guest directory identity before writing/importing XML.
Apple DTDs remain external inspection artifacts; pass --dtd for local validation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

CLIP_SHA256 = '62dfa5b49d5f97d954c420d315c250015d8733f47c59752d002f8b841e650211'
CLIP_BYTES = 58747744


def build_fixture(guest_clip, guest_directory):
    if not isinstance(guest_directory, str) or not re.fullmatch(r'/private/var/tmp/LightClickFCPFixture\.[A-Za-z0-9_-]{6,16}', guest_directory):
        raise ValueError('destination must be a generated private FCP fixture directory')
    if not isinstance(guest_clip, str) or not (
            re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin', guest_clip)
            or guest_clip == guest_directory+'/input-prores422.mov'):
        raise ValueError('clip must be a fixed staging receipt or own copied fixture in the supplied directory')
    root = ET.Element('fcpxml', version='1.3')
    project = ET.SubElement(root, 'project', name='LC-generated-8s')
    resources = ET.SubElement(project, 'resources')
    ET.SubElement(resources, 'format', id='r1', frameDuration='1/30s', width='1920', height='1080', fieldOrder='progressive', paspH='1', paspV='1')
    ET.SubElement(resources, 'asset', id='r2', name='LC-generated-prores422', src='file://'+guest_clip,
                  start='0s', duration='8s', hasVideo='1', hasAudio='0', format='r1')
    sequence = ET.SubElement(project, 'sequence', format='r1', duration='8s', tcStart='0s', tcFormat='NDF')
    spine = ET.SubElement(sequence, 'spine')
    clip = ET.SubElement(spine, 'clip', name='LC-generated-prores422', offset='0s', start='0s', duration='8s', format='r1')
    ET.SubElement(clip, 'video', ref='r2', offset='0s', start='0s', duration='8s')
    data = ET.tostring(root, encoding='utf-8', xml_declaration=True) + b'\n'
    manifest = {'format':'FCPXML1.3', 'guest_xml_destination':guest_directory+'/generated.fcpxml',
                'guest_clip':guest_clip, 'xml_sha256':hashlib.sha256(data).hexdigest(), 'xml_bytes':len(data),
                'expected_input':{'sha256':CLIP_SHA256,'bytes':CLIP_BYTES,'video':'ProRes422 Standard',
                                  'width':1920,'height':1080,'frame_duration':'1/30s','frames':240,'duration':'8s','audio_tracks':0},
                'qualification':'DTD validity only; guest media identity, import, rendering and export require independent qualification.'}
    return data, manifest


def publish(path, data):
    # Never overwrite a prior experiment's evidence, or follow a destination symlink.
    fd = os.open(path, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream: stream.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--guest-clip', required=True)
    parser.add_argument('--guest-directory', required=True)
    parser.add_argument('--output', type=Path, required=True, help='new host XML artifact, not a guest path')
    parser.add_argument('--dtd', type=Path, action='append', default=[], help='inspected external Apple1.3 DTD, never copied to repository')
    args = parser.parse_args()
    data, manifest = build_fixture(args.guest_clip, args.guest_directory)
    # Validate before publishing. No external entities or network lookups in generated XML.
    for dtd in args.dtd:
        checked = subprocess.run(['/usr/bin/xmllint','--noout','--nonet','--dtdvalid',str(dtd),'-'],
                                 input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=False)
        if checked.returncode:
            raise ValueError('external DTD validation failed: '+checked.stderr.decode('utf-8','replace')[:4096])
    manifest['validated_dtd_paths'] = [str(dtd) for dtd in args.dtd]
    publish(args.output, data)
    publish(Path(str(args.output)+'.json'), (json.dumps(manifest,indent=2)+'\n').encode())
    print(json.dumps(manifest,indent=2))


if __name__ == '__main__': main()
