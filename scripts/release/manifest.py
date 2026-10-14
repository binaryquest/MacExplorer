import hashlib
import json
from pathlib import Path
import sys
from config import BASE_URL, app_info

output = Path(sys.argv[1])
info = app_info()
version = info['CFBundleShortVersionString']
name = f'MacExplorer-{version}.dmg'
dmg = output / name
manifest = {'version': version, 'build': int(info['CFBundleVersion']), 'minimumSystemVersion': info['LSMinimumSystemVersion'],
            'url': f'{BASE_URL}/releases/{version}/{name}', 'size': dmg.stat().st_size,
            'sha256': hashlib.file_digest(dmg.open('rb'), 'sha256').hexdigest(),
            'releaseNotesURL': f'{BASE_URL}/releases/{version}/MacExplorer-{version}.md'}
(output / 'latest.json').write_text(json.dumps(manifest, indent=2) + '\n')
names = [name, f'MacExplorer-{version}.md', 'appcast.xml', 'latest.json']
(output / 'checksums.txt').write_text(''.join(f"{hashlib.file_digest((output / file).open('rb'), 'sha256').hexdigest()}  {file}\n" for file in names))
