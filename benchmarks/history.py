#!/usr/bin/env python3
"""Keep small, immutable benchmark reports in Git; raw evidence stays external."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

from baselines import validate_result

DEFAULT_ROOT = Path(__file__).resolve().parent / 'history'
SCHEMA = 'axe.agent-benchmark.history'
ENTRY_SCHEMA = SCHEMA + '-entry'
RUN_ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,199}')


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _json(data):
    def invalid(value):
        raise ValueError('Invalid JSON constant: ' + value)
    return json.loads(data, parse_constant=invalid)


def _read_report(source):
    source = Path(source).expanduser().absolute()
    if source.is_symlink() or not source.is_file():
        raise ValueError('A regular report file is required: ' + str(source))
    raw = source.read_bytes()
    result = _json(raw)
    validate_result(result)
    if not RUN_ID.fullmatch(result['runId']):
        raise ValueError('Unsafe runId: ' + result['runId'])
    return source, raw, result


def _summary(result, report_sha):
    fields = ('name', 'version', 'build', 'binarySHA256', 'runtimeSHA256', 'mode')
    tool = {key: result['tool'][key] for key in fields if key in result['tool']}
    companion = result['tool'].get('companionApp')
    if isinstance(companion, dict):
        tool['companionApp'] = {key: companion[key]
                                for key in ('version', 'build', 'binarySHA256')
                                if key in companion}
    return {
        'runId': result['runId'], 'scenario': result['scenario'],
        'status': result['status'], 'tool': tool,
        'metrics': result['metrics'], 'reportSHA256': report_sha,
        'report': result['runId'] + '/report.json',
    }


def _provenance(source, result):
    location = Path(result.get('evidenceDirectory', source.parent / 'evidence'))
    if not location.is_absolute():
        location = source.parent / location
    manifest = location / 'archive.json'
    archive_sha = result.get('evidenceArchiveSHA256')
    if manifest.is_file() and not manifest.is_symlink():
        observed = _sha(manifest.read_bytes())
        if archive_sha and archive_sha != observed:
            raise ValueError('External evidence archive differs from report')
        archive_sha = observed
    return {
        'sourceReport': str(source),
        'sourceReportSHA256': _sha(source.read_bytes()),
        'evidenceDirectory': str(location.absolute()),
        'evidenceArchiveSHA256': archive_sha,
        'transcriptSHA256': result.get('transcriptSHA256'),
        'rawEvidenceIncluded': False,
        'verification': 'Provenance only; raw evidence was not revalidated during import.',
        'note': 'Raw transcripts, screenshots and builds remain external. Git history contains reports only.',
    }


def _write_json(file, value):
    raw = (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False, allow_nan=False) + '\n').encode()
    with file.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


@contextmanager
def _locked(root):
    if root.is_symlink():
        raise ValueError('History root must not be a symlink')
    root.mkdir(parents=True, exist_ok=True)
    # Lock the directory itself: no transient lock file needs to enter Git.
    descriptor = os.open(str(root), os.O_RDONLY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def _entries(root):
    entries = []
    if not root.exists():
        return entries
    if root.is_symlink():
        raise ValueError('History root must not be a symlink')
    for folder in sorted(root.iterdir()):
        if folder.name.startswith('.') or folder.name == 'index.json':
            continue
        if folder.is_symlink() or not folder.is_dir():
            raise ValueError('Unexpected history member: ' + folder.name)
        manifest_path = folder / 'manifest.json'
        if manifest_path.is_symlink() or not manifest_path.is_file():
            raise ValueError('Missing regular history manifest: ' + folder.name)
        manifest = _json(manifest_path.read_bytes())
        _, raw, result = _read_report(folder / 'report.json')
        expected = _summary(result, _sha(raw))
        if (manifest.get('schema') != ENTRY_SCHEMA or manifest.get('schemaVersion') != 1
                or manifest.get('entry') != expected or result['runId'] != folder.name
                or manifest.get('provenance', {}).get('rawEvidenceIncluded') is not False
                or manifest.get('provenance', {}).get('sourceReportSHA256') != _sha(raw)):
            raise ValueError('History manifest/report mismatch: ' + folder.name)
        entries.append(expected)
    return entries


def _index(root):
    return {'schema': SCHEMA, 'schemaVersion': 1, 'runs': _entries(root)}


def list_history(history_root=DEFAULT_ROOT):
    """Read verified local report records. No external artifacts are required."""
    root = Path(history_root).expanduser().absolute()
    value = _index(root)
    index = root / 'index.json'
    if index.is_symlink():
        raise ValueError('History index must not be a symlink')
    # The index is a derived cache. A crash after record rename can leave it stale.
    # Reports and their manifests are authoritative; do not hide such a record.
    value['indexCurrent'] = index.is_file() and _json(index.read_bytes()) == value
    return value


def _save_index(root):
    value = _index(root)
    target = root / 'index.json'
    if target.is_symlink():
        raise ValueError('History index must not be a symlink')
    descriptor, temporary = tempfile.mkstemp(prefix='.index-', dir=str(root))
    os.close(descriptor)
    temporary = Path(temporary)
    try:
        temporary.unlink()
        _write_json(temporary, value)
        os.replace(str(temporary), str(target))
    finally:
        if temporary.exists():
            temporary.unlink()


def import_report(report_path, history_root=DEFAULT_ROOT):
    """Archive exact report bytes once, with explicit external evidence provenance."""
    source, raw, result = _read_report(report_path)
    root = Path(history_root).expanduser().absolute()
    target = root / result['runId']
    with _locked(root):
        _entries(root)  # Refuse corrupt existing records before a write.
        if target.exists():
            if (target / 'report.json').read_bytes() != raw:
                raise ValueError('Run ID already contains different report bytes: ' + result['runId'])
            state = 'already-recorded'
        else:
            manifest = {'schema': ENTRY_SCHEMA, 'schemaVersion': 1,
                        'recordedAt': datetime.now(timezone.utc).isoformat(),
                        'entry': _summary(result, _sha(raw)),
                        'provenance': _provenance(source, result)}
            if source.read_bytes() != raw:
                raise ValueError('Source report changed during import')
            temporary = Path(tempfile.mkdtemp(prefix='.import-', dir=str(root)))
            try:
                with (temporary / 'report.json').open('xb') as stream:
                    stream.write(raw)
                    stream.flush()
                    os.fsync(stream.fileno())
                _write_json(temporary / 'manifest.json', manifest)
                os.rename(str(temporary), str(target))
            finally:
                if temporary.exists():
                    shutil.rmtree(temporary)
            state = 'recorded'
        # Preserve existing index bytes for an idempotent import.
        if not list_history(root)['indexCurrent']:
            _save_index(root)
    return {'status': state, 'runId': result['runId'],
            'report': str(target / 'report.json'), 'reportSHA256': _sha(raw)}


def import_source(source, history_root=DEFAULT_ROOT):
    """Import one report or all report paths in a suite summary.json."""
    source = Path(source).expanduser().absolute()
    if source.is_file():
        return {'imports': [import_report(source, history_root)]}
    summary = _json((source / 'summary.json').read_bytes())
    if not isinstance(summary.get('runs'), list):
        raise ValueError('Suite summary must contain runs')
    reports = []
    for row in summary['runs']:
        if not isinstance(row, dict) or not isinstance(row.get('report'), str):
            raise ValueError('Suite entry must contain a report path')
        report = Path(row['report'])
        if not report.is_absolute():
            report = source / report
        _read_report(report)  # Validate all input reports before starting imports.
        reports.append(report)
    return {'imports': [import_report(report, history_root) for report in reports]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs='?', choices=('list', 'import'), default='list')
    parser.add_argument('source', nargs='?')
    parser.add_argument('--root', type=Path, default=DEFAULT_ROOT)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    if args.command == 'import':
        if not args.source:
            parser.error('import requires SOURCE')
        value = import_source(args.source, args.root)
    else:
        if args.source:
            parser.error('list does not take SOURCE')
        value = list_history(args.root)
    if args.json or args.command == 'import':
        print(json.dumps(value, sort_keys=True, indent=2, allow_nan=False))
    else:
        print('Scenario | Tool | Version | Status | Calls | Seconds | Tokens | Run ID')
        for row in value['runs']:
            metrics, tool = row['metrics'], row['tool']
            print(' | '.join(str(item) for item in (
                row['scenario'], tool['name'], tool.get('version', '?'), row['status'],
                metrics.get('totalCalls', '?'), metrics.get('elapsedSeconds', '?'),
                metrics.get('returnedTextTokens', '?'), row['runId'])))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(json.dumps({'status': 'error', 'reason': str(error)}), file=sys.stderr)
        sys.exit(2)
