# sf-validate

Quick SF Validate Command

A lightweight shell script for performing Salesforce deployment validations with intelligent delta detection, test execution control, and comprehensive reporting.

## Overview

The `validate` command streamlines Salesforce validation workflows by:
- **Automatically detecting changed sources** between git commits
- **Intelligently selecting tests** based on code changes
- **Tracking validation progress** asynchronously
- **Generating detailed coverage reports** with test results
- **Supporting flexible execution modes** for CI/CD pipelines

## Prerequisites

- `git` - For repository and commit operations
- `sf` (Salesforce CLI) - For Salesforce deployment and validation
- `jq` - For JSON parsing and report generation

## Installation

Clone the repository and enter the project directory:

```bash
git clone https://github.com/lukemoorhous/sf-validate.git
cd sf-validate
```

### macOS / Linux

Ensure the script is executable and run it directly or after installing it on your PATH:

```bash
chmod +x src/validate.sh
./src/validate.sh [options]
# or, once `src/validate.sh` is on your PATH,
validate [options]
```

### Git Bash (Windows)

Run the bundled installer so `validate` lives in `~/bin` and your shell picks it up:

```bash
./installers/windows-git-bash.sh
```

The installer copies `src/validate.sh` to `~/bin/validate`, makes it executable, and ensures your `~/.bashrc`
adds `~/bin` to `PATH` (the script updates `~/.bash_profile` to source `~/.bashrc` if needed). Restart Git Bash
or `source ~/.bashrc` after running the installer before invoking `validate`.

## Usage

```bash
validate [options]
```

> Because `validate` always runs `sf project deploy validate --async --json`, a nonzero exit (typically 1 or 69) while the job is queued is treated as expected; the script still pulls the job ID from the JSON payload and keeps watching the validation until it completes.

### Defaults

| Setting | Default |
|---------|---------|
| Branch | Current git branch |
| Base branch | `main` |
| From SHA | Merge base of HEAD and base branch |
| To SHA | HEAD |
| Output root | `<repo>/tmp/<branch>` (locally) or system temp (CI) |
| Delta dir | `<output root>/changed-sources` |
| Target org | Auto-detected from `SF_TARGET_ORG` or sf config |
| Test level | `RunRelevantTests` |
| Source dir | `force-app/main` |
| SGD ignore | `<repo root>/.sgdignore` (override with `-i/--sgdignore`) |

> The validation step tolerates the Salesforce CLI returning exit code 1 (queued) or 69 (pending) and continues monitoring the job via the extracted job ID whenever the deployment status is not yet final.

### Options

| Option | Description |
|--------|-------------|
| `-b, --branch` | Working branch name; defaults to current branch |
| `-B, --base-branch` | Branch to compare against (default: `main`) |
| `-f, --from, --from-sha` | Explicit from SHA |
| `-t, --to, --to-sha` | Explicit to SHA |
| `-o, --output-root` | Output root; overrides default |
| `-s, --source-dir` | Source directory (default: `force-app/main`) |
| `-D, --skip-delta` | Skip delta generation and reuse an existing manifest |
| `-m, --manifest <path>` | Manifest to validate; useful with `--skip-delta` |
| `-u, --target-org` | Salesforce target org/alias (auto-detected if not provided) |
| `-l, --test-level` | Test execution level: `RunRelevantTests` \| `RunLocalTests` \| `RunAllTestsInOrg` \| `RunSpecifiedTests` |
| `-T, --tests` | Comma-separated tests for `RunSpecifiedTests` |
| `-i, --sgdignore <path>` | Path to the `.sgdignore` file used by `sgd source delta` (defaults to repo-root `.sgdignore`) |
| `--debug` | Enable full debug/verbose logging |
| `-h, --help` | Show help message |

By default the delta generation step uses the `.sgdignore` file located at the repository root. Point the `-i/--sgdignore` option at a custom ignore file when your repo keeps it elsewhere or needs a different delta configuration.

### Examples

```bash
# Basic validation
validate

# With debug output
validate --debug

# Reuse an existing manifest
validate -D -m ./tmp/SUR-105-async-site-checkin-engine/changed-sources/package/package.xml

# Target a different org
validate -u UAT

# Compare against a different base branch
validate -B release

# Run only local tests
validate -l RunLocalTests

# Run specific tests
validate -l RunSpecifiedTests -T "AccountServiceTest,ContactServiceTest"

# Custom output directory
validate -o ./tmp/custom-run

# Use a custom ignore file for delta generation
validate -i ./configs/.sgdignore
```

> Because the wrapper already handles the CLI’s queued/pending exit codes (1/69), you don’t need to rerun `validate` manually—any job that is still initializing is automatically resumed until the report is available.

## Output

The script generates the following artifacts in the output root:
- validation.json - Raw validation response from Salesforce
- validation.stderr.log - Validation stderr output
    report.json - Complete deployment report with test results
    report.stderr.log - Report retrieval stderr output
    coverage.json - Processed coverage and test summary
    changed-sources/ - Delta package with only changed files
