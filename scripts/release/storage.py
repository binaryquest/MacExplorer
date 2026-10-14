"""R2 transport through the official AWS CLI; credentials are read from its environment."""
import json
import os
from pathlib import Path
import subprocess
from urllib.parse import urlparse

from config import BUCKET


class R2:
    def __init__(self):
        self.endpoint = os.environ.get('R2_ENDPOINT', '')
        endpoint = urlparse(self.endpoint)
        if endpoint.scheme != 'https' or not (endpoint.hostname or '').endswith('.r2.cloudflarestorage.com') or endpoint.username or endpoint.password or endpoint.path not in ['', '/'] or endpoint.query or endpoint.fragment:
            raise ValueError('Set R2_ENDPOINT to the bucket account S3 HTTPS endpoint')
        for name in ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY']:
            if not os.environ.get(name):
                raise ValueError(f'{name} is required for R2')

    def call(self, args, missing_ok=False):
        env = dict(os.environ, AWS_EC2_METADATA_DISABLED='true', AWS_PAGER='')
        result = subprocess.run(['aws', '--endpoint-url', self.endpoint, '--region', 'auto', 's3api', *args,
                                 '--bucket', BUCKET], capture_output=True, text=True, env=env)
        if result.returncode:
            if missing_ok and any(code in result.stderr for code in ['(NoSuchKey)', '(404)', '(NotFound)']):
                return None
            raise RuntimeError('R2 operation failed: ' + result.stderr.strip())
        return json.loads(result.stdout or '{}')

    def get(self, key, path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        result = self.call(['get-object', '--key', key, str(path)], missing_ok=True)
        return result is not None

    def head(self, key):
        return self.call(['head-object', '--key', key], missing_ok=True)

    def put(self, key, path, content_type, digest, immutable=False):
        cache = 'public,max-age=31536000,immutable' if immutable else 'no-store,max-age=0'
        self.call(['put-object', '--key', key, '--body', str(path), '--content-type', content_type,
                   '--cache-control', cache, '--metadata', json.dumps({'sha256': digest})])
