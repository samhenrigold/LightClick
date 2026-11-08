#!/usr/bin/env python3
"""Check fixture semantics/path refusal/exclusive artifacts; optional actual external DTDs."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--dtd',action='append',default=[]);args=parser.parse_args()
    path=Path(__file__).resolve().parents[1]/'probes/fcp-fixture-xml.py'
    spec=importlib.util.spec_from_file_location('fcp_fixture_xml',path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    clip='/private/var/tmp/VirtualIntelMac.ABC123/Transfer.bin'
    work='/private/var/tmp/LightClickFCPFixture.ABC123'
    data,manifest=module.build_fixture(clip,work)
    root=ET.fromstring(data)
    assert root.attrib=={'version':'1.3'} and [x.tag for x in root]==['project']
    project=root.find('project');assert [x.tag for x in project]==['resources','sequence']
    fmt=project.find('resources/format');asset=project.find('resources/asset');seq=project.find('sequence');video=seq.find('spine/clip/video')
    assert (fmt.get('width'),fmt.get('height'),fmt.get('frameDuration'))==('1920','1080','1/30s')
    assert fmt.get('name')==manifest['project_format_name']=='FFVideoFormat1080p30'
    assert (asset.get('src'),asset.get('hasAudio'),asset.get('duration'))==('file://'+clip,'0','8s')
    assert seq.get('format')==fmt.get('id') and asset.get('format')==fmt.get('id') and video.get('ref')==asset.get('id')
    assert seq.get('duration')==video.get('duration')=='8s'
    assert manifest['expected_input']['frames']==240 and manifest['guest_xml_destination']==work+'/generated.fcpxml'
    assert data==module.build_fixture(clip,work)[0] and b'<!DOCTYPE'not in data
    copied=work+'/input-prores422.mov'
    copied_data,copied_manifest=module.build_fixture(copied,work)
    assert ET.fromstring(copied_data).find('project/resources/asset').get('src')=='file://'+copied
    assert copied_manifest['guest_clip']==copied and copied_manifest['expected_input']==manifest['expected_input']
    for bad in ['/Users/test/movie.mov','/private/var/tmp/VirtualIntelMac.ABC123/../Transfer.bin',clip+'\n',clip.replace('Transfer.bin','input.mov'),'/private/var/tmp/VirtualIntelMac.ABC123/Transfer.bin?x=1',
                '/private/var/tmp/LightClickFCPFixture.OTHER1/input-prores422.mov',
                copied+'/../input-prores422.mov',copied+'\n',work+'/other.mov',work+'/nested/input-prores422.mov']:
        try:module.build_fixture(bad,work)
        except ValueError:pass
        else:raise AssertionError('accepted nonstaged clip')
    for bad in ['/Users/test','/private/var/tmp/LightClickFCPFixture.ABC123/..',work+'\n',work+'/nested']:
        try:module.build_fixture(clip,bad)
        except ValueError:pass
        else:raise AssertionError('accepted nongenerated destination')
    with tempfile.TemporaryDirectory(prefix='lightclick-fcp-xml-test-')as temporary:
        target=Path(temporary)/'fixture.fcpxml';module.publish(target,data)
        try:module.publish(target,b'replace')
        except FileExistsError:pass
        else:raise AssertionError('overwrote evidence')
        assert target.read_bytes()==data
        link=Path(temporary)/'alias';link.symlink_to(target)
        try:module.publish(link,b'replace')
        except FileExistsError:pass
        else:raise AssertionError('followed destination symlink')
    for dtd in args.dtd:
        for xml in (data,copied_data):
            subprocess.run(['/usr/bin/xmllint','--noout','--nonet','--dtdvalid',dtd,'-'],input=xml,timeout=5,check=True)
    print('PASS FCPXML1.3 semantic references/240-frame timeline, strict guest receipt scope, deterministic/exclusive output; DTDs='+str(len(args.dtd)))


if __name__=='__main__':main()
