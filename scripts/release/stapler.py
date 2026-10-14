#!/usr/bin/env python3
"""Retry transient Apple ticket-service failures without weakening validation."""
import argparse
import re
import subprocess
import time


RETRY_DELAYS = (10, 20, 40, 80)
COMMAND_TIMEOUT = 120
EX_NOHOST = 68
# NSURLError: timed out, host lookup/connect failure, connection lost, DNS, offline.
TRANSIENT_URL_ERRORS = {-1001, -1003, -1004, -1005, -1006, -1009}


def is_transient(returncode, output):
    # EX_NOHOST also means "not notarized". Require a transport diagnostic;
    # never retry revoked/invalid/missing tickets or TLS/authentication errors.
    codes = re.findall(r'\bDomain=NSURLErrorDomain\s+Code=(-\d+)\b', output)
    return returncode == EX_NOHOST and bool(codes) and all(int(code) in TRANSIENT_URL_ERRORS for code in codes)


def run_stapler(action, path):
    command = ['xcrun', 'stapler', action, str(path)]
    attempts = len(RETRY_DELAYS) + 1
    for attempt in range(attempts):
        print(f'Stapler {action}: attempt {attempt + 1}/{attempts}', flush=True)
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, encoding='utf-8', errors='replace', timeout=COMMAND_TIMEOUT)
            output = result.stdout
            returncode = result.returncode
            retryable = is_transient(returncode, output)
        except subprocess.TimeoutExpired as error:
            output = error.stdout or ''
            if isinstance(output, bytes):
                output = output.decode('utf-8', errors='replace')
            output += f'\nStapler {action} exceeded the {COMMAND_TIMEOUT}-second command timeout.\n'
            returncode, retryable = 124, True
        if output:
            print(output, end='' if output.endswith('\n') else '\n', flush=True)
        if returncode == 0:
            return 0
        if not retryable:
            print(f'Stapler {action} failed with a non-retryable error ({returncode}).', flush=True)
            return returncode if returncode > 0 else 128 - returncode
        if attempt == attempts - 1:
            print(f'Stapler {action}: retries exhausted; release verification failed.', flush=True)
            return returncode
        delay = RETRY_DELAYS[attempt]
        print(f'Temporary Apple ticket-service failure; retrying {action} in {delay} seconds.', flush=True)
        time.sleep(delay)
    raise AssertionError('Unreachable')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['staple', 'validate'])
    parser.add_argument('path')
    args = parser.parse_args()
    raise SystemExit(run_stapler(args.action, args.path))
