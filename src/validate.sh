#!/usr/bin/env bash
set -euo pipefail

DEBUG=false

on_error() {
  local rc=$?
  local line_no="${BASH_LINENO[0]}"
  local cmd="${BASH_COMMAND}"
  if [[ "${DEBUG}" == true ]]; then
    echo "ERROR: command failed at line $line_no: $cmd (exit $rc)" >&2
  else
    echo "❌ Validate Failed" >&2
  fi
  exit "$rc"
}
trap 'on_error' ERR

BRANCH=""
BASE_BRANCH="main"
FROM_SHA=""
TO_SHA=""
SOURCE_DIR="force-app/main"
OUTPUT_ROOT=""
TARGET_ORG=""
TEST_LEVEL="RunRelevantTests"
TESTS=""
SKIP_DELTA=false
MANIFEST_PATH=""
SGD_IGNORE_FILE=""

usage() {
cat <<EOF
Usage:
  validate [options]

Defaults:
  branch        = current git branch
  base branch   = main
  from sha      = git merge-base HEAD <base branch>
  to sha        = HEAD
  output root   = <repo>/tmp/<branch> locally, system temp in CI
  delta dir     = <output root>/changed-sources
  target org    = auto-detect from env or sf config
  test level    = RunRelevantTests
  source dir    = force-app/main
  sgd ignore    = <repo root>/.sgdignore

Options:
  -b, --branch               Working branch name; defaults to current branch
  -B, --base-branch          Branch to compare against; default: main
  -f, --from, --from-sha     Explicit from SHA
  -t, --to, --to-sha         Explicit to SHA
  -o, --output-root          Output root; overrides default
  -s, --source-dir           Source dir; default: force-app/main
  -D, --skip-delta           Skip delta generation and reuse an existing manifest
  -m, --manifest <path>      Manifest to validate; useful with --skip-delta
  -u, --target-org           Salesforce target org / alias
                             Default: auto-detect from SF_TARGET_ORG or sf config
  -l, --test-level           RunRelevantTests | RunLocalTests | RunAllTestsInOrg | RunSpecifiedTests
  -T, --tests                Comma-separated tests for RunSpecifiedTests
  -i, --sgdignore <path>     Path to the .sgdignore file for sgd source delta (default: repo root/.sgdignore)
      --debug                Enable full debug / verbose logging
  -h, --help                 Show this help

Examples:
  validate
  validate --debug
  validate -D -m ./tmp/SUR-105-async-site-checkin-engine/changed-sources/package/package.xml
  validate -D -m C:/Users/you/Projects/repo/tmp/SUR-105-async-site-checkin-engine/changed-sources/package/package.xml
  validate -u UAT
  validate -B release
  validate -l RunLocalTests
  validate -l RunSpecifiedTests -T "AccountServiceTest,ContactServiceTest"
  validate -o ./tmp/custom-run
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

debug_log() {
  if [[ "${DEBUG}" == true ]]; then
    echo "$@"
  fi
  return 0
}

info_log() {
  echo "$@"
}

require_value() {
  local flag="$1"
  local value="${2-}"
  [[ -n "$value" && "${value:0:1}" != "-" ]] || die "Missing value for $flag"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

json_get_first_string() {
  local json_file="$1"
  local query="$2"

  [[ -f "$json_file" ]] || return 1

  jq -er "$query | select(type == \"string\" and length > 0)" "$json_file" 2>/dev/null | head -n1
}

extract_job_id_from_json() {
  local json_file="$1"

  json_get_first_string "$json_file" '
    .result.id //
    .result.jobId //
    .result.deployId //
    .id //
    .jobId //
    .deployId
  '
}

extract_status_from_json() {
  local json_file="$1"

  json_get_first_string "$json_file" '
    .result.status //
    .status
  '
}

is_ci() {
  [[ -n "${CI:-}" ]]
}

resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

resolve_system_tmp() {
  if [[ -n "${TMPDIR:-}" ]]; then
    printf '%s\n' "${TMPDIR%/}"
  elif [[ -d /tmp ]]; then
    printf '%s\n' "/tmp"
  else
    printf '%s\n' "$(pwd)"
  fi
}

sanitize_path_segment() {
  local value="$1"
  value="${value//\//-}"
  value="${value//\\/-}"
  value="${value//:/-}"
  printf '%s\n' "$value"
}

normalize_path() {
  local path="$1"
  printf '%s\n' "${path//\\//}"
}

is_absolute_path() {
  local path
  path="$(normalize_path "$1")"

  [[ "$path" == /* ]] && return 0
  [[ "$path" == ~/* ]] && return 0
  [[ "$path" =~ ^[A-Za-z]:[/] ]] && return 0
  return 1
}

resolve_path() {
  local path
  path="$(normalize_path "$1")"

  if [[ "$path" == ~/* ]]; then
    printf '%s\n' "${HOME}/${path#~/}"
  elif is_absolute_path "$path"; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "${REPO_ROOT}/${path}"
  fi
}

resolve_default_output_root() {
  local repo_root="$1"
  local system_tmp="$2"
  local safe_branch="$3"

  if is_ci; then
    printf '%s\n' "${system_tmp}/${safe_branch}"
  else
    printf '%s\n' "${repo_root}/tmp/${safe_branch}"
  fi
}

resolve_target_org() {
  local org=""

  if [[ -n "${TARGET_ORG:-}" ]]; then
    printf '%s\n' "$TARGET_ORG"
    return 0
  fi

  if [[ -n "${SF_TARGET_ORG:-}" ]]; then
    printf '%s\n' "$SF_TARGET_ORG"
    return 0
  fi

  org="$(sf config get target-org --json 2>/dev/null | jq -r '
    .result[]? | select(.key=="target-org") | .value
  ')"

  if [[ -n "$org" && "$org" != "null" ]]; then
    printf '%s\n' "$org"
    return 0
  fi

  return 1
}

count_manifest_items() {
  local manifest_path="$1"

  [[ -f "$manifest_path" ]] || {
    printf '0\n'
    return 0
  }

  grep -c '<members>' "$manifest_path" 2>/dev/null || printf '0\n'
}

generate_delta() {
  info_log "🚧 Identifying Changed Sources"
  local branch="$1"
  local from_sha="$2"
  local to_sha="$3"
  local source_dir="$4"
  local output_dir="$5"
  local sgd_ignore_file="${6-}"

  mkdir -p "$output_dir"

  debug_log "==> Generating Salesforce delta..."
  debug_log "==> Delta branch:  $branch"
  debug_log "==> Delta from:    $from_sha"
  debug_log "==> Delta to:      $to_sha"
  debug_log "==> Delta output:  $output_dir"
  debug_log

  local delta_args=(
    sgd source delta
    -t "$to_sha"
    -f "$from_sha"
    -o "$output_dir"
    --generate-delta
    --source-dir "$source_dir"
    -W
  )

  if [[ -n "$sgd_ignore_file" && -f "$sgd_ignore_file" ]]; then
    delta_args+=( -i "$sgd_ignore_file" )
  fi

  local delta_rc=0
  set +e
  if [[ "${DEBUG}" == true ]]; then
    sf "${delta_args[@]}"
  else
    sf "${delta_args[@]}" >"${output_dir}/delta.stdout.log" 2>"${output_dir}/delta.stderr.log"
  fi
  delta_rc=$?
  set -e

  if [[ "$delta_rc" -eq 0 ]]; then
    if [[ "${DEBUG}" == true ]]; then
      echo "Delta generation failed with exit code $delta_rc" >&2
    else
      echo "Delta generation failed. See:" >&2
      echo "  ${output_dir}/delta.stdout.log" >&2
      echo "  ${output_dir}/delta.stderr.log" >&2
    fi
    exit "$delta_rc"
  fi
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--branch)
      require_value "$1" "${2-}"
      BRANCH="$2"
      shift 2
      ;;
    -B|--base-branch)
      require_value "$1" "${2-}"
      BASE_BRANCH="$2"
      shift 2
      ;;
    -f|--from|--from-sha)
      require_value "$1" "${2-}"
      FROM_SHA="$2"
      shift 2
      ;;
    -t|--to|--to-sha)
      require_value "$1" "${2-}"
      TO_SHA="$2"
      shift 2
      ;;
    -o|--output-root)
      require_value "$1" "${2-}"
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    -s|--source-dir)
      require_value "$1" "${2-}"
      SOURCE_DIR="$2"
      shift 2
      ;;
    -D|--skip-delta)
      SKIP_DELTA=true
      shift
      ;;
    -m|--manifest)
      require_value "$1" "${2-}"
      MANIFEST_PATH="$2"
      shift 2
      ;;
    -u|--target-org)
      require_value "$1" "${2-}"
      TARGET_ORG="$2"
      shift 2
      ;;
    -l|--test-level)
      require_value "$1" "${2-}"
      TEST_LEVEL="$2"
      shift 2
      ;;
    -T|--tests)
      require_value "$1" "${2-}"
      TESTS="$2"
      shift 2
      ;;
    -i|--sgdignore)
      require_value "$1" "${2-}"
      SGD_IGNORE_FILE="$2"
      shift 2
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

require_cmd git
require_cmd sf
require_cmd jq

REPO_ROOT="$(resolve_repo_root)"
SYSTEM_TMP="$(resolve_system_tmp)"

TARGET_ORG="${TARGET_ORG:-}"

if ! TARGET_ORG="$(resolve_target_org)"; then
  die "No target org found. Pass --target-org, set SF_TARGET_ORG, or run 'sf config set target-org <alias>' in this project."
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
fi

[[ "$BRANCH" != "HEAD" ]] || die "Detached HEAD detected; pass --branch explicitly"

SAFE_BRANCH="$(sanitize_path_segment "$BRANCH")"

if [[ -z "$TO_SHA" ]]; then
  TO_SHA="$(git rev-parse HEAD)"
fi

if [[ -z "$FROM_SHA" ]]; then
  git fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true
  FROM_SHA="$(git merge-base HEAD "origin/$BASE_BRANCH" 2>/dev/null || git merge-base HEAD "$BASE_BRANCH")"
fi

if [[ -z "$OUTPUT_ROOT" ]]; then
  OUTPUT_ROOT="$(resolve_default_output_root "$REPO_ROOT" "$SYSTEM_TMP" "$SAFE_BRANCH")"
fi

OUTPUT_ROOT="$(resolve_path "$OUTPUT_ROOT")"

if [[ -z "$SGD_IGNORE_FILE" ]]; then
  SGD_IGNORE_FILE="$(resolve_path '.sgdignore')"
else
  SGD_IGNORE_FILE="$(resolve_path "$SGD_IGNORE_FILE")"
fi

DELTA_DIR="${OUTPUT_ROOT}/changed-sources"
VALIDATION_JSON="${OUTPUT_ROOT}/validation.json"
VALIDATION_STDERR="${OUTPUT_ROOT}/validation.stderr.log"
REPORT_JSON="${OUTPUT_ROOT}/report.json"
REPORT_STDERR="${OUTPUT_ROOT}/report.stderr.log"
COVERAGE_JSON="${OUTPUT_ROOT}/coverage.json"
PACKAGE_XML_DEFAULT="${DELTA_DIR}/package/package.xml"
PACKAGE_XML="$PACKAGE_XML_DEFAULT"
DESTRUCTIVE_XML="${DELTA_DIR}/destructiveChanges/destructiveChanges.xml"

if [[ -n "$MANIFEST_PATH" ]]; then
  PACKAGE_XML="$(resolve_path "$MANIFEST_PATH")"
fi

mkdir -p "$OUTPUT_ROOT"

if [[ "${DEBUG}" == true ]]; then
  debug_log "==> Repo root:     $REPO_ROOT"
  debug_log "==> System tmp:    $SYSTEM_TMP"
  debug_log "==> CI mode:       $(is_ci && echo true || echo false)"
  debug_log "==> Branch:        $BRANCH"
  debug_log "==> Base branch:   $BASE_BRANCH"
  debug_log "==> From SHA:      $FROM_SHA"
  debug_log "==> To SHA:        $TO_SHA"
  debug_log "==> Output root:   $OUTPUT_ROOT"
  debug_log "==> Delta dir:     $DELTA_DIR"
  debug_log "==> Source dir:    $SOURCE_DIR"
  debug_log "==> SGD ignore:    $SGD_IGNORE_FILE"
  debug_log "==> Skip delta:    $SKIP_DELTA"
  [[ -n "$MANIFEST_PATH" ]] && debug_log "==> Manifest:      $PACKAGE_XML"
  debug_log "==> Target org:    $TARGET_ORG"
  debug_log "==> Test level:    $TEST_LEVEL"
  [[ -n "$TESTS" ]] && debug_log "==> Tests:         $TESTS"
  debug_log
fi

if [[ "$SKIP_DELTA" == true ]]; then
  debug_log "==> Skipping delta generation"
  debug_log "==> Using manifest: $PACKAGE_XML"
else
  generate_delta "$BRANCH" "$FROM_SHA" "$TO_SHA" "$SOURCE_DIR" "$DELTA_DIR" "$SGD_IGNORE_FILE"

  if [[ "${DEBUG}" == true ]]; then
    debug_log "==> Delta contents:"
    find "$DELTA_DIR" -maxdepth 4 -type f | sort || true
    debug_log "==> Expected package.xml: $PACKAGE_XML"
    [[ -f "$PACKAGE_XML" ]] && debug_log "==> package.xml exists" || debug_log "==> package.xml missing"
    debug_log "==> Using manifest: $PACKAGE_XML"
  fi
fi

[[ -f "$PACKAGE_XML" ]] || die "package.xml not found at $PACKAGE_XML"

ITEM_COUNT="$(count_manifest_items "$PACKAGE_XML")"
info_log "📦 ${ITEM_COUNT} Items"

DEPLOY_ARGS=(
  project deploy validate
  --manifest "$PACKAGE_XML"
  --target-org "$TARGET_ORG"
  --async
)

if [[ -f "$DESTRUCTIVE_XML" ]]; then
  DEPLOY_ARGS+=( --post-destructive-changes "$DESTRUCTIVE_XML" )
fi

case "$TEST_LEVEL" in
  RunRelevantTests|RunLocalTests|RunAllTestsInOrg)
    DEPLOY_ARGS+=( --test-level "$TEST_LEVEL" )
    ;;
  RunSpecifiedTests)
    [[ -n "$TESTS" ]] || die "--tests is required when --test-level RunSpecifiedTests"
    DEPLOY_ARGS+=( --test-level RunSpecifiedTests --tests "$TESTS" )
    ;;
  *)
    die "Unsupported --test-level: $TEST_LEVEL"
    ;;
esac

set +e
# Allow sf to exit with non-zero codes while we inspect the JSON output.
trap - ERR
sf "${DEPLOY_ARGS[@]}" \
  --json \
  > "$VALIDATION_JSON" \
  2> >(tee "$VALIDATION_STDERR" >&2)
VALIDATE_RC=$?
trap 'on_error' ERR
set -e

if [[ "$VALIDATE_RC" -ne 0 && "$VALIDATE_RC" -ne 1 && "$VALIDATE_RC" -ne 69 ]]; then
  echo "❌ Validate Failed" >&2
  if [[ "${DEBUG}" == true ]]; then
    echo "==> Deploy validate failed with exit code $VALIDATE_RC" >&2
    echo "==> Validation JSON: $VALIDATION_JSON" >&2
    echo "==> Validation stderr: $VALIDATION_STDERR" >&2
    [[ -s "$VALIDATION_JSON" ]] && cat "$VALIDATION_JSON" >&2 || true
    [[ -s "$VALIDATION_STDERR" ]] && cat "$VALIDATION_STDERR" >&2 || true
  fi
  exit "$VALIDATE_RC"
fi

JOB_ID="$(extract_job_id_from_json "$VALIDATION_JSON" || true)"

[[ -n "$JOB_ID" ]] || die "Could not extract deploy job ID from validate output"

[[ "${DEBUG}" == true ]] && debug_log "==> Validation job id: $JOB_ID"
[[ "${DEBUG}" == true ]] && debug_log "==> Validation status: $(extract_status_from_json "$VALIDATION_JSON" || printf 'Unknown')"

info_log "📡 Watching validation progress"

set +e
sf project deploy resume \
  --job-id "$JOB_ID" \
  --wait 120
RESUME_RC=$?
set -e

if [[ "$RESUME_RC" -eq 69 ]]; then
  echo "â³ Validation still running" >&2
  echo "Job ID: $JOB_ID" >&2
  exit "$RESUME_RC"
fi

set +e
sf project deploy report \
  --job-id "$JOB_ID" \
  --json \
  > "$REPORT_JSON" 2> "$REPORT_STDERR"
REPORT_RC=$?
set -e

if [[ "$REPORT_RC" -eq 69 ]]; then
  STATUS="$(extract_status_from_json "$REPORT_JSON" || printf 'InProgress')"
  echo "Validation still running" >&2
  echo "Job ID: $JOB_ID" >&2
  echo "Status: $STATUS" >&2
  echo "Report JSON: $REPORT_JSON" >&2
  exit "$REPORT_RC"
fi

if [[ "$REPORT_RC" -ne 0 && ! -s "$REPORT_JSON" ]]; then
  echo "❌ Validate Failed" >&2
  if [[ "${DEBUG}" == true ]]; then
    echo "==> Report fetch failed with exit code $REPORT_RC" >&2
    echo "==> Resume exit code: $RESUME_RC" >&2
    echo "==> Job ID: $JOB_ID" >&2
    echo "==> Report JSON:   $REPORT_JSON" >&2
    echo "==> Report stderr: $REPORT_STDERR" >&2
    [[ -s "$REPORT_JSON" ]] && cat "$REPORT_JSON" >&2 || true
    [[ -s "$REPORT_STDERR" ]] && cat "$REPORT_STDERR" >&2 || true
  fi
  exit "$REPORT_RC"
fi

if [[ -s "$REPORT_JSON" ]]; then
  [[ "${DEBUG}" == true ]] && debug_log "==> Final JSON report fetched"
else
  rc=1
  echo "❌ Validate Failed" >&2
  if [[ "${DEBUG}" == true ]]; then
    echo "==> Report JSON file was not created" >&2
    echo "==> Report JSON:   $REPORT_JSON" >&2
    echo "==> Report stderr: $REPORT_STDERR" >&2
    [[ -s "$REPORT_JSON" ]] && cat "$REPORT_JSON" >&2 || true
    [[ -s "$REPORT_STDERR" ]] && cat "$REPORT_STDERR" >&2 || true
  fi
  exit "$rc"
fi

if [[ "${DEBUG}" == true ]]; then
  debug_log "==> Extracting coverage..."
fi

jq '
{
  jobId: (
    .result.id //
    .result.jobId //
    .result.deployId //
    null
  ),
  coverage: (
    .result.details.runTestResult.codeCoverage //
    .result.codeCoverage //
    []
  ),
  coverageWarnings: (
    .result.details.runTestResult.codeCoverageWarnings //
    .result.codeCoverageWarnings //
    []
  ),
  tests: (
    .result.details.runTestResult.successes //
    .result.tests //
    []
  ),
  summary: {
    status: (.result.status // .status // "Unknown"),
    success: (.result.success // .success // false),
    testsRun: (
      .result.details.runTestResult.numTestsRun //
      .result.numberTestsTotal //
      null
    ),
    failures: (
      .result.details.runTestResult.numFailures //
      .result.numberTestErrors //
      null
    )
  }
}' "$REPORT_JSON" > "$COVERAGE_JSON"

STATUS="$(jq -r '.summary.status // "Unknown"' "$COVERAGE_JSON")"
SUCCESS="$(jq -r '.summary.success // false' "$COVERAGE_JSON")"
TESTS_RUN="$(jq -r '.summary.testsRun // 0' "$COVERAGE_JSON")"
FAILURES="$(jq -r '.summary.failures // 0' "$COVERAGE_JSON")"

if [[ "$SUCCESS" == "true" ]]; then
  info_log "✅ Validate Succeeded"
else
  info_log "❌ Validate Failed"
fi

if [[ "${DEBUG}" == true ]]; then
  echo
  echo "Done ✅"
  echo "Status:             $STATUS"
  echo "Tests run:          $TESTS_RUN"
  echo "Failures:           $FAILURES"
  echo "Delta dir:          $DELTA_DIR"
  echo "Validation JSON:    $VALIDATION_JSON"
  echo "Validation stderr:  $VALIDATION_STDERR"
  echo "Full report JSON:   $REPORT_JSON"
  echo "Report stderr:      $REPORT_STDERR"
  echo "Coverage JSON:      $COVERAGE_JSON"
fi
true
