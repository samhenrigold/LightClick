#!/usr/bin/env python3
"""Checks that scripts/generate-machine-options notices a stale file, a bad table and names that drifted from QEMU."""
import copy
import importlib.machinery
import importlib.util
import json
from pathlib import Path

path = str(Path(__file__).with_name('generate-machine-options'))
loader = importlib.machinery.SourceFileLoader('generate_machine_options', path)
spec = importlib.util.spec_from_loader(loader.name, loader)
tool = importlib.util.module_from_spec(spec)
loader.exec_module(tool)

table = json.loads((tool.SOURCE/tool.TABLE).read_text())
assert tool.validate(table) == []

# The checkout's own files and names are current.
assert all((tool.SOURCE/name).read_text() == text for name, text in tool.render(table).items())
read = {reader: tool.literals(directory) for reader, directory in tool.READERS.items()}
assert tool.drift(table, read) == []
assert 'VIM_INPUT_BACKPRESSURE' in read['qemu']

# Any change to the table changes what's generated, so --check fails until it's regenerated.
changed = copy.deepcopy(table)
changed['options'][1]['default'] = 'something else'
assert tool.render(changed)[tool.HEADER] != tool.render(table)[tool.HEADER]
assert tool.render(changed)[tool.SWIFT] != tool.render(table)[tool.SWIFT]

# A name only QEMU knows, and a listed name nothing reads.
assert any('PVG_NEW' in problem for problem in tool.drift(table, {**read, 'qemu': read['qemu'] | {'PVG_NEW'}}))
assert any('PVG_TCG_TSO' in problem for problem in tool.drift(table, {**read, 'qemu': read['qemu'] - {'PVG_TCG_TSO'}}))
# The engine's readers are on other branches: its names may be unread here, and are checked once they land.
assert not any('LC_HVDBT' in problem for problem in tool.drift(table, read))

# A default-on fast path can't be a Bool, whose false would mean unset, which is on.
bad = copy.deepcopy(table)
bad['options'][1]['type'] = 'fastPath'
assert any("can't be a typed option" in problem for problem in tool.validate(bad))
bad = copy.deepcopy(table)
bad['testingFlags'].append(bad['options'][1])
assert any('listed twice' in problem for problem in tool.validate(bad))

# Presence flags stay unset for false, since QEMU would read 0 as on.
assert '"PVG_SHADOW_COALESCE", shadowCoalesce == true ? "1" : nil' in tool.render(table)[tool.SWIFT]
print('PASS')
