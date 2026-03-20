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

Clone this repository and ensure the `validate` script is executable:

```bash
git clone https://github.com/lukemoorhous/sf-validate.git
cd sf-validate
chmod +x src/validate.sh
```

Add the script to your PATH or invoke it directly:

```bash
./src/validate.sh [options]
# or
validate [options]  # if added to PATH
```

## Usage

```bash
validate [options]
```

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
| `--debug` | Enable full debug/verbose logging |
| `-h, --help` | Show help message |

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
```

## Output

The script generates the following artifacts in the output root:
- validation.json - Raw validation response from Salesforce
- validation.stderr.log - Validation stderr output
    report.json - Complete deployment report with test results
    report.stderr.log - Report retrieval stderr output
    coverage.json - Processed coverage and test summary
    changed-sources/ - Delta package with only changed files
