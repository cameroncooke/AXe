#!/usr/bin/env python3
"""Recheck immutable benchmark evidence with the current scorer; never replay UI."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys

from baselines import METRIC_FIELDS, read_result, validate_result
from environment import digest, tree_digest
from scoring import score_run


HERE = Path(__file__).resolve().parent
RUNNER_CHECKS = ('inputs.unchanged', 'model.expected', 'runner.completed')


def verify_evidence(root, transcript_sha):
    """Verify the complete saved archive, including the original transcript hash."""
    root = Path(root).resolve(strict=True)
    manifest = root / 'archive.json'
    if manifest.is_symlink() or not manifest.is_file():
        raise ValueError('A regular evidence archive manifest is required')
    archive = json.loads(manifest.read_text(encoding='utf-8'))
    hashes = archive.get('sha256')
    source = archive.get('source')
    if (not isinstance(hashes, dict) or not isinstance(source, str)
            or not Path(source).is_absolute()):
        raise ValueError('Invalid evidence archive manifest')
    if 'claude.jsonl' not in hashes or 'result.json' not in hashes:
        raise ValueError('Archive must include the transcript and runner result')
    for name, expected in hashes.items():
        if not isinstance(name, str) or Path(name).name != name or name in ('.', '..', 'archive.json'):
            raise ValueError('Invalid archive member path')
        member = root / name
        if member.is_symlink() or not member.is_file() or digest(member) != expected:
            raise ValueError('Archive member hash mismatch: ' + name)
    if not transcript_sha or digest(root / 'claude.jsonl') != transcript_sha:
        raise ValueError('Transcript differs from the original report')
    return archive, digest(manifest)


def rescore(source_report, output, evidence_directory=None):
    """Write one new deterministic report exclusively. Original evidence stays intact.

    evidence_directory replaces the recorded location for evidence that was moved.
    The archive must still match the original report's transcript hash."""
    source = Path(source_report).expanduser().resolve(strict=True)
    destination = Path(output).expanduser().absolute()
    if destination.exists() or destination.is_symlink() or destination.resolve() == source:
        raise FileExistsError('Rescore output must be a new file')
    original_bytes = source.read_bytes()
    original_sha = hashlib.sha256(original_bytes).hexdigest()
    original = read_result(source)
    if evidence_directory is not None:
        evidence = Path(evidence_directory).expanduser().absolute()
    else:
        evidence = Path(original.get('evidenceDirectory', source.parent / 'evidence'))
    if not evidence.is_absolute():
        evidence = source.parent / evidence
    evidence = evidence.resolve(strict=True)
    try:
        destination.resolve().relative_to(evidence)
    except ValueError:
        pass
    else:
        raise ValueError('Rescore output must be outside the original evidence directory')
    archive, archive_sha = verify_evidence(evidence, original.get('transcriptSHA256'))
    scorer_sha = tree_digest(HERE, ['scoring.py', 'transcript.py'])
    if original.get('sourceRunId') and original['contract'].get('scorerSHA256') == scorer_sha:
        raise ValueError('This report already uses the current scorer; rescore the original source report instead')
    environment = original['environment']
    score = score_run(evidence, original['scenario'], original['tool']['name'],
                      expected_executable=original['tool']['executable'],
                      expected_udid=environment['udid'],
                      expected_setup={**original['app'], 'developerDir': environment['developerDir'],
                                      'udid': environment['udid'], 'runDirectory': archive['source'],
                                      'launchedByHarness': 'harness-build-install-launch' in
                                      original.get('contract', {}).get('setupPolicy', '')})
    if tree_digest(HERE, ['scoring.py', 'transcript.py']) != scorer_sha:
        raise ValueError('Scorer changed during the offline check')
    if digest(source) != original_sha or verify_evidence(evidence, original.get('transcriptSHA256'))[1] != archive_sha:
        raise ValueError('Source evidence changed during the offline check')

    result = copy.deepcopy(original)
    checks = copy.deepcopy(score['correctness']['checks'])
    if any(item['id'] in RUNNER_CHECKS for item in checks):
        raise ValueError('Scorer must not replace runner-owned checks')
    prior_checks = {item['id']: item for item in original['correctness']['checks']}
    for name in RUNNER_CHECKS:
        checks.append(copy.deepcopy(prior_checks.get(name, {
            'id': name, 'status': 'unverified', 'reason': 'Original runner check is absent.'})))
    execution = original.get('execution', {})
    cleanup = execution.get('cleanup', {})
    source_complete = (
        original.get('status') != 'blocked'
        and all(prior_checks.get(name, {}).get('status') == 'passed' for name in RUNNER_CHECKS)
        and original.get('preparation', {}).get('status') == 'ready'
        and execution.get('exitCode') == 0 and execution.get('stopReason') is None
        and isinstance(cleanup, dict) and cleanup.get('complete') is True
    )
    checks.append({'id': 'rescore.originalExecutionComplete',
                   'status': 'passed' if source_complete else 'unverified',
                   'reason': 'Original preparation, runner checks, execution and process cleanup must all be complete.'})
    differences = [{'metric': name, 'original': original['metrics'].get(name),
                    'rescored': score['metrics'].get(name)} for name in METRIC_FIELDS
                   if original['metrics'].get(name) is None
                   or score['metrics'].get(name) != original['metrics'].get(name)]
    checks.append({'id': 'rescore.measurementsUnchanged',
                   'status': 'unverified' if differences else 'passed', 'evidence': differences,
                   'reason': 'Original calls, elapsed time, text tokens and image measurements are retained.'})
    status = score['status'] if source_complete and not differences else 'unverified'
    if original['status'] == 'blocked':
        status = 'blocked'
    source_id = original.get('sourceRunId', original['runId'])
    result.update(runId=source_id + '-rescore-' + scorer_sha[:12], sourceRunId=source_id,
                  sourceReport=str(source), sourceReportSHA256=original_sha,
                  previousScorerSHA256=original['contract'].get('scorerSHA256'),
                  previousStatus=original['status'], evidenceDirectory=str(evidence),
                  evidenceArchiveSHA256=archive_sha, status=status,
                  correctness={'status': status, 'checks': checks}, warnings=score.get('warnings', []))
    result['contract']['scorerSHA256'] = scorer_sha
    if 'reason' in result:
        result['previousReason'] = result.pop('reason')
    if not source_complete or differences:
        result['reason'] = 'Original execution proof is incomplete or rescoring changed a measured cost; no pass is granted.'
    validate_result(result)
    with destination.open('x', encoding='utf-8') as stream:
        json.dump(result, stream, sort_keys=True, indent=2, ensure_ascii=False, allow_nan=False)
        stream.write('\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_report')
    parser.add_argument('--output', required=True)
    parser.add_argument('--evidence', help='Evidence directory, when it has moved since the run')
    args = parser.parse_args()
    result = rescore(args.source_report, args.output, args.evidence)
    print(json.dumps({'status': result['status'], 'runId': result['runId'], 'output': str(Path(args.output).absolute())}))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({'status': 'error', 'reason': str(error)}), file=sys.stderr)
        sys.exit(2)
