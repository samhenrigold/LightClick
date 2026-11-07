"""One guest-bench clone: fixed app inventory, then native OSA dictionaries for present Numbers/Pages.

Arguments: fresh existing host results directory, already-built fixed-enum OSA helper. Stage helper once, collect serially.
No export API is assumed; no recursive native-mode walk, host UI, input, or Seamless operation.
"""
import hashlib
import json
from pathlib import Path
import re

TARGETS={
    '/Applications/Numbers.app':('numbers','direct'),
    "/Applications/iWork '09/Numbers.app":('numbers','iwork09'),
    '/Applications/Pages.app':('pages','direct'),
    "/Applications/iWork '09/Pages.app":('pages','iwork09')}


def preflight():
    if len(arguments)!=2:
        raise RuntimeError('combined preflight requires fresh results and compiled fixed-enum OSA helper')
    results,helper=map(Path,arguments)
    artifact=results/'iwork-preflight.json'
    if not results.is_dir() or artifact.exists():raise RuntimeError('combined results must be fresh/existing')
    report={'result':'INCONCLUSIVE','phase':'inventory','targets':[],
            'note':'Application/dictionary discovery only; no export API or performance qualification.'}
    def save():artifact.write_text(json.dumps(report,indent=2)+'\n')
    def execute(name,context):
        driver=source/'probes'/name
        exec(compile(driver.read_text(),str(driver),'exec'),context)
    try:
        save()
        inventory_dir=results/'availability';inventory_dir.mkdir()
        execute('keynote-availability-driver.py',dict(globals(),arguments=[str(inventory_dir)]))
        inventory=json.loads((inventory_dir/'keynote-availability.json').read_text())
        if inventory.get('result')!='PASS_INVENTORY':raise RuntimeError('application inventory did not complete')
        selected=[]
        for app in inventory['inventory']['apps']:
            if app.get('path') not in TARGETS or app.get('present') is not True:continue
            if app.get('error'):raise RuntimeError(f'present iWork metadata could not be read: {app}')
            bundle=app.get('bundle',{})
            expected={'path':app['path']}
            for key in ('CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion'):
                if not bundle.get(key):raise RuntimeError(f'present app missing inventoried {key}: {app["path"]}')
                expected[key]=bundle[key]
            selector,location=TARGETS[app['path']]
            selected.append({'selector':selector,'location':location,'expected':expected,'macho':app.get('macho')})
        report['inventory']=str(inventory_dir/'keynote-availability.json')
        if not selected:
            report.update(result='NO_NUMBERS_OR_PAGES',phase='complete');save()
            print(f'Inventory complete; no Numbers/Pages targets; evidence {artifact}',flush=True)
            return
        if not helper.is_file() or not 0<helper.stat().st_size<=4*1024*1024:raise RuntimeError('compiled helper absent/oversize')
        helper_hash=hashlib.sha256(helper.read_bytes()).hexdigest()
        report.update(phase='staging_helper',helper_sha256=helper_hash);save()
        guest=stage(helper)
        if not isinstance(guest,str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin',guest):
            raise ValueError('invalid shared helper staging receipt')
        staged={'path':guest,'sha256':helper_hash}
        report['staged_helper']=staged
        for target in selected:
            directory=results/(target['selector']+'-'+target['location']);directory.mkdir()
            report.update(phase='collecting_'+target['selector']+'_'+target['location']);save()
            execute('keynote-dictionary-driver.py',dict(globals(),arguments=[str(directory),str(helper)],
                    dictionary_target=target,staged_dictionary_helper=staged))
            collected=json.loads((directory/'keynote-dictionary.json').read_text())
            report['targets'].append(dict(target,artifact=str(directory/'keynote-dictionary.json'),
                collection_result=collected.get('result'),
                extractor=collected.get('receipt',{}).get('manifest',{}).get('extractor'),
                dictionaries=[{'selector':item['selector'],'dictionary':item['dictionary']}
                              for item in collected.get('files',[]) if 'dictionary'in item]))
            save()
        report.update(result='COLLECTED_UNREVIEWED',phase='complete');save()
        print(f'Collected {len(selected)} Numbers/Pages dictionaries in one clone; API review required; evidence {artifact}',flush=True)
    except (Exception,SystemExit)as error:
        report['error']=repr(error);save();raise


preflight()
