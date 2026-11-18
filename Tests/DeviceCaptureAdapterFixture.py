"""Compile production scheduling methods with fake workers and recorded UI effects."""
from pathlib import Path
import re, sys
source, scaffold, destination = map(Path, sys.argv[1:])
text = source.read_text()
names = ['deviceThatIsOn', 'lockedAlternate', 'selectCapture', 'selectionDeadline', 'retargetPipelineCapture', 'retargetCapture', 'admitCapture',
         'pumpCaptures', 'startPipelineCapture', 'fallBackFromBlackFrame', 'receivePipelineCapture', 'startQueuedPress', 'deliverCaptureResult',
         'startCapture', 'isCurrentActivation', 'locateAfterActivation']
methods = []
for name in names:
    found = list(re.finditer(r'^    private func ' + name + r'\(.*?^    \}', text, re.M | re.S))
    assert len(found) == 1, name
    methods.append(('    @discardableResult\n' if name == 'admitCapture' else '') + found[0].group().replace('private func', 'func', 1))
for name in ('singlePressDevice', 'doublePressDevice'):
    found = re.findall(r'^    private var ' + name + r': .+$', text, re.M)
    assert len(found) == 1, name
    methods.append(found[0].replace('private var', 'var', 1))
destination.write_text(scaffold.read_text().replace('// PRODUCTION_METHODS', '\n'.join(methods)))
print('Compiled actual TossApp methods:', ', '.join(names))
