#!/usr/bin/env bash
#
# A script to find the latest scheduled GitHub Actions run,
# locate the "e2e tests (providers)" job, find the "Run E2E tests"
# step within it, and display its logs.
#
# Prerequisites:
# 1. GitHub CLI (`gh`) must be installed and authenticated.

set -eo pipefail

# --- Prerequisite Check ---
if ! command -v gh &>/dev/null; then
  echo "Error: GitHub CLI ('gh') is not installed. ❌ Please install it to continue."
  echo "See: https://cli.github.com/"
  exit 1
fi
echo "✅ GitHub CLI is installed."

# --- Main Logic ---

# Get the current repository in the owner/repo format.
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
if [[ -z "$REPO" ]]; then
    echo "❌ Error: Could not determine GitHub repository. Are you inside a git repository that has a GitHub remote?"
    exit 1
fi

echo "REPO: ${REPO}"
echo
echo

echo "🔄 Searching for the latest scheduled run in repository: $REPO..."

# Fetch the last 50 runs and use jq to filter for the first 'schedule' event's ID.
RUN_ID=$(gh run list --limit 50 --json databaseId,conclusion,event --jq '[.[] | select(.event == "schedule" and .conclusion == "failure")][0].databaseId')

# Check if a run was found
if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
  echo "No scheduled failure runs found in the last 50 workflow runs."
  exit 0
fi

echo "✅ Found latest scheduled run with ID: $RUN_ID"
echo "---"
echo "🔄 Searching for the 'e2e tests (providers)' job in this run..."

# Get the jobs for the run and find the databaseId of the specific job.
JOB_ID=$(gh run view "$RUN_ID" --repo "$REPO" --json jobs --jq '.jobs[] | select(.name == "e2e tests (providers)") | .databaseId')

# Check if the job was found
if [[ -z "$JOB_ID" || "$JOB_ID" == "null" ]]; then
    echo "❌ Error: Could not find a job named 'e2e tests (providers)' in run ID $RUN_ID."
    exit 1
fi

STEP_NAME="Run E2E Tests"
echo "✅ Found job 'e2e tests (providers)' with ID: $JOB_ID"
echo "---"
echo "🔄 Fetching logs for the specific step: '${STEP_NAME}'..."
echo

COMMIT_SHA=$(gh run view "$RUN_ID" --json headSha --jq '.headSha')
COMMIT_MESSAGE=$(gh api "repos/${REPO}/commits/${COMMIT_SHA}" --jq .commit.message)

# Fetch the full job log and then use 'sed' to filter the output, showing only
# the content between the start of the target step and the start of the next one.
# GitHub Actions logs.

LOG_CONTENT=$(gh run view --log --job "$JOB_ID" --repo "$REPO")

# Find the name of the last test that failed.
# 1. `grep "^--- FAIL:"`: Find all lines that mark a failed test.
# 2. `tail -n 1`: Get only the very last one.
# 3. `awk '{print $3}'`: Get the third field (the test name, e.g., "TestGiteaBadYamlValidation").
last_failed_test_name=$(echo "$LOG_CONTENT" | grep "^--- FAIL:" | tail -n 1 | awk '{print $3}')

# If the variable is empty, it means no "--- FAIL:" lines were found.
if [[ -z "$last_failed_test_name" ]]; then
  echo "✅ No failed tests found in the log."
  exit 0
fi

echo "🔄 Found last failed test: ${last_failed_test_name}"
echo "---"
echo "Log output for this test:"
echo

# Use 'sed' to print the block of text for the failed test.
# It starts printing from the line that begins with "=== RUN   <TestName>"
# and stops printing after the line that begins with "--- FAIL: <TestName>".
FAILED_TEST_LOGS=$(echo "$LOG_CONTENT" | sed -n "/^=== RUN   ${last_failed_test_name}$/,/^--- FAIL: ${last_failed_test_name}/p")

AI_OUTPUT=$(aichat -c "Given this commit message: ${COMMIT_MESSAGE}, and the following E2E CI error log: ${FAILED_TEST_LOGS}\n\n, is the failure related to the commit? Answer YES or NO.")


if [ "$AI_OUTPUT" = "NO" ]; then
  echo "Ok, I am triggering the Job again..."
  gh run rerun "${RUN_ID}"
else
  echo "Test failure seems related to HEAD commit; you need to check what's going wrong!"
fi
