#!/usr/bin/env node

import { readFile, writeFile } from 'node:fs/promises';
import process from 'node:process';

const VERSION_HEADING_REGEX = /^##\s+\[([^\]]+)\](?:\s+-\s+.*)?\s*$/;

function normalizeVersion(value) {
  return value.trim().replace(/^v/, '');
}

function compareVersions(version1, version2) {
  const v1Base = version1.split('-')[0];
  const v2Base = version2.split('-')[0];
  const v1Pre = version1.includes('-') ? version1.slice(version1.indexOf('-') + 1) : '';
  const v2Pre = version2.includes('-') ? version2.slice(version2.indexOf('-') + 1) : '';

  if (v1Base === v2Base) {
    if (!v1Pre && v2Pre) return 1;
    if (v1Pre && !v2Pre) return -1;
    if (version1 === version2) return 0;
  }

  const sorted = [version1, version2].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  return sorted[0] === version1 ? -1 : 1;
}

function parseArgs(argv) {
  const args = {
    changelog: 'CHANGELOG.md',
    channel: 'production',
    commitSha: '',
    fallback: 'none',
    out: '',
    ref: '',
    version: '',
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];

    if (arg === '--version') {
      if (!next) throw new Error('Missing value for --version');
      args.version = next;
      i += 1;
      continue;
    }

    if (arg === '--changelog') {
      if (!next) throw new Error('Missing value for --changelog');
      args.changelog = next;
      i += 1;
      continue;
    }

    if (arg === '--out') {
      if (!next) throw new Error('Missing value for --out');
      args.out = next;
      i += 1;
      continue;
    }

    if (arg === '--channel') {
      if (!next) throw new Error('Missing value for --channel');
      args.channel = next;
      i += 1;
      continue;
    }

    if (arg === '--fallback') {
      if (!next) throw new Error('Missing value for --fallback');
      args.fallback = next;
      i += 1;
      continue;
    }

    if (arg === '--ref') {
      if (!next) throw new Error('Missing value for --ref');
      args.ref = next;
      i += 1;
      continue;
    }

    if (arg === '--commit-sha') {
      if (!next) throw new Error('Missing value for --commit-sha');
      args.commitSha = next;
      i += 1;
      continue;
    }

    if (arg === '--help' || arg === '-h') {
      printHelp();
      process.exit(0);
    }

    throw new Error(`Unknown argument: ${arg}`);
  }

  if (!args.version) {
    throw new Error('Missing required argument: --version');
  }

  return args;
}

function printHelp() {
  console.log(`Generate GitHub release notes from CHANGELOG.md.

Usage:
  node scripts/generate-github-release-notes.mjs --version <version> [options]

Options:
  --version <version>          Required release version
  --channel <production|staging>
  --fallback <none|newest-older>
  --ref <git ref>             Staging source ref label
  --commit-sha <sha>          Staging source commit
  --changelog <path>          Changelog path (default: CHANGELOG.md)
  --out <path>                Output file path (default: stdout)
  -h, --help                  Show this help
`);
}

function extractChangelogSection(changelog, version, fallbackMode) {
  const normalizedTarget = normalizeVersion(version);
  const lines = changelog.split(/\r?\n/);
  let sectionStartLine = -1;

  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index].match(VERSION_HEADING_REGEX);
    if (!match) {
      continue;
    }

    if (normalizeVersion(match[1]) === normalizedTarget) {
      sectionStartLine = index + 1;
      break;
    }
  }

  let resolvedVersion = normalizedTarget;

  if (sectionStartLine === -1 && fallbackMode === 'newest-older') {
    const versions = [];
    for (const line of lines) {
      const match = line.match(VERSION_HEADING_REGEX);
      if (!match) continue;
      const value = normalizeVersion(match[1]);
      if (value === 'Unreleased') continue;
      if (compareVersions(value, normalizedTarget) >= 0) continue;
      versions.push(value);
    }

    versions.sort((left, right) => compareVersions(right, left));
    resolvedVersion = versions[0] ?? '';

    if (resolvedVersion) {
      return extractChangelogSection(changelog, resolvedVersion, 'none');
    }
  }

  if (sectionStartLine === -1) {
    throw new Error(
      `Missing CHANGELOG section for version: ${normalizedTarget}\n` +
        `Add a heading like: ## [${normalizedTarget}] (or ## [v${normalizedTarget}] - YYYY-MM-DD)`,
    );
  }

  let sectionEndLine = lines.length;
  for (let index = sectionStartLine; index < lines.length; index += 1) {
    if (VERSION_HEADING_REGEX.test(lines[index])) {
      sectionEndLine = index;
      break;
    }
  }

  const section = lines.slice(sectionStartLine, sectionEndLine).join('\n').trim();
  if (!section) {
    throw new Error(`CHANGELOG section for version ${resolvedVersion} is empty`);
  }

  return {
    resolvedVersion,
    section,
  };
}

function buildInstallSection(version) {
  const normalizedVersion = normalizeVersion(version);
  const tag = `v${normalizedVersion}`;
  return [
    '---',
    '',
    '## Installation',
    '',
    '### Homebrew',
    '',
    '```bash',
    'brew tap cameroncooke/axe',
    'brew install axe',
    '```',
    '',
    '### Manual',
    '',
    `Download \`AXe-macOS-${tag}-universal.tar.gz\` from the assets below and extract it.`,
    '',
    'Keep the extracted payload together:',
    '',
    '```text',
    'axe',
    'Frameworks/',
    'AXe_AXe.bundle/',
    '```',
    '',
    'Then either run `./axe` from the extracted directory or symlink that `axe` executable onto your `PATH` without moving it away from `Frameworks/` and `AXe_AXe.bundle/`.',
  ].join('\n');
}

function buildProductionReleaseBody(version, changelogSection, resolvedVersion) {
  const installSection = buildInstallSection(version);
  const fallbackNotice = normalizeVersion(version) === resolvedVersion
    ? ''
    : `> Notes fallback: using CHANGELOG entry from \`${resolvedVersion}\` for \`${normalizeVersion(version)}\`.\n\n`;

  return [`## What's Changed`, '', `${fallbackNotice}${changelogSection}`, '', installSection, ''].join('\n');
}

function buildStagingReleaseBody({ version, ref, commitSha }) {
  return [
    '## Staging Build',
    '',
    `This is an unreleased staging package for AXe \`${version}\`.`,
    '',
    `- Source ref: \`${ref || 'main'}\``,
    `- Commit: \`${commitSha || 'unknown'}\``,
    '- Purpose: packaged Homebrew and archive validation before production tagging',
    '',
    '## Installation',
    '',
    '### Homebrew staging tap',
    '',
    '```bash',
    'brew tap cameroncooke/axe-staging',
    'brew install cameroncooke/axe-staging/axe',
    '```',
    '',
    'This build is intended for end-to-end packaging and install validation. It is not the production shipping release.',
    '',
  ].join('\n');
}

async function main() {
  try {
    const { changelog, channel, commitSha, fallback, out, ref, version } = parseArgs(process.argv.slice(2));

    let body = '';

    if (channel === 'staging') {
      body = buildStagingReleaseBody({ version, ref, commitSha });
    } else {
      const changelogContent = await readFile(changelog, 'utf8').catch(() => {
        throw new Error(`Could not read CHANGELOG.md at ${changelog}`);
      });
      const { resolvedVersion, section } = extractChangelogSection(changelogContent, version, fallback);
      body = buildProductionReleaseBody(version, section, resolvedVersion);
    }

    if (out) {
      await writeFile(out, body, 'utf8');
      return;
    }

    process.stdout.write(body);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`Error: ${message}\n`);
    process.exit(1);
  }
}

await main();
