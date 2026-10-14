from pathlib import Path
import base64
import plistlib
import re

ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = 'io.bquick.explorer'
TEAM_ID = 'B5M99337GK'
BASE_URL = 'https://downloads.bquick.io/explorer'
BUCKET = 'macexplorer-releases'
PREFIX = 'explorer'


def version_tuple(value):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        raise ValueError('Release version must be major.minor.patch')
    return tuple(map(int, value.split('.')))


def validate_version(version, build, previous=None):
    current = version_tuple(version)
    if not str(build).isdigit() or int(build) <= 0:
        raise ValueError('Build number must be a positive integer')
    if previous and (current <= version_tuple(previous['version']) or int(build) <= int(previous['build'])):
        raise ValueError('Version and build number must both increase beyond the published release')


def app_info(path=None):
    with open(path or ROOT / 'Support/Info.plist', 'rb') as stream:
        info = plistlib.load(stream)
    validate_version(info['CFBundleShortVersionString'], info['CFBundleVersion'])
    if info['CFBundleIdentifier'] != BUNDLE_ID:
        raise ValueError('Unexpected application identifier')
    if info.get('SUFeedURL') != BASE_URL + '/stable/appcast.xml':
        raise ValueError('Unexpected update feed')
    if len(base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)) != 32:
        raise ValueError('A valid Sparkle public key is required')
    for key in ['SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed']:
        if info.get(key) is not True:
            raise ValueError(f'{key} must be enabled')
    return info
