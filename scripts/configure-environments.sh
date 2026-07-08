#!/usr/bin/env bash
# configure-environments.sh - configure GitHub Environments for the promotion
# jobs in this repo's Deployment GitOps CI workflow.
#
# `ci.yml` has three promotion jobs (promote-dev, promote-staging,
# promote-prod). None of them handle cloud credentials - promotion is just a
# `git commit` + `git push` using the default GITHUB_TOKEN - so Environments
# here are purely about adding a human-approval gate in front of
# staging/production, plus a branch policy restricting deploys to `main`
# (every promote job already checks out `ref: main`).
#
#   - dev:        no protection rules at all (repository_dispatch-driven,
#                 no human in the loop; must stay fully automatic).
#   - staging:    required reviewer + main-only deployment branch policy.
#   - production: required reviewer + main-only deployment branch policy.
#
# Usage:
#   ./scripts/configure-environments.sh [--dry-run]
#   GITHUB_ORG=devdanielgherasim GITHUB_REPO=micro-market-deployment \
#     REVIEWER_LOGIN=devdanielgherasim \
#     ./scripts/configure-environments.sh --dry-run

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

GITHUB_ORG="${GITHUB_ORG:-devdanielgherasim}"
GITHUB_REPO="${GITHUB_REPO:-micro-market-deployment}"
REVIEWER_LOGIN="${REVIEWER_LOGIN:-devdanielgherasim}"
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage:
  configure-environments.sh [options]

Options:
  --org <owner>        GitHub org/user. Defaults to GITHUB_ORG or devdanielgherasim.
  --repo <name>         GitHub repository name. Defaults to GITHUB_REPO or micro-market-deployment.
  --reviewer <login>    GitHub login required to approve staging/production deployments.
                         Defaults to REVIEWER_LOGIN or devdanielgherasim.
  --dry-run             Print intended gh api calls without changing anything.
  -h, --help             Show this help.

Configures three GitHub Environments:
  - dev:        no protection rules (repository_dispatch-driven, fully automatic).
  - staging:    required reviewer + main-only deployment branch policy.
  - production: required reviewer + main-only deployment branch policy.

The authenticated gh user/token must have repository Administration: write.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)
      GITHUB_ORG="${2:-}"; shift 2 ;;
    --repo)
      GITHUB_REPO="${2:-}"; shift 2 ;;
    --reviewer)
      REVIEWER_LOGIN="${2:-}"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown argument: $1" ;;
  esac
done

[[ -n "${GITHUB_ORG}" ]] || die "GitHub org/user is required. Pass --org or set GITHUB_ORG."
[[ -n "${GITHUB_REPO}" ]] || die "GitHub repo is required. Pass --repo or set GITHUB_REPO."
[[ -n "${REVIEWER_LOGIN}" ]] || die "Reviewer login is required. Pass --reviewer or set REVIEWER_LOGIN."

require_cmd() {
  command -v "${1}" >/dev/null 2>&1 || die "${1} is not installed. Install it first."
}

if [[ "${DRY_RUN}" != "true" ]]; then
  require_cmd gh
  require_cmd jq
  gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated. Run 'gh auth login' first."
fi

repo_full_name="${GITHUB_ORG}/${GITHUB_REPO}"
reviewer_id=""

resolve_reviewer_id() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api users/${REVIEWER_LOGIN} --jq '.id'"
    reviewer_id="<reviewer-id-of-${REVIEWER_LOGIN}>"
    return 0
  fi

  info "Resolving numeric GitHub user id for reviewer '${REVIEWER_LOGIN}'"
  reviewer_id="$(gh api "users/${REVIEWER_LOGIN}" --jq '.id')"
  [[ -n "${reviewer_id}" && "${reviewer_id}" != "null" ]] || die "Could not resolve a numeric id for '${REVIEWER_LOGIN}'."
  success "reviewer=${REVIEWER_LOGIN} id=${reviewer_id}"
}

configure_environment_unprotected() {
  local env_name="$1"
  info "Configuring environment '${env_name}' for ${repo_full_name} (no protection rules)"

  local payload="{}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api --method PUT repos/${repo_full_name}/environments/${env_name} --input -"
    echo "${payload}"
    return 0
  fi

  gh api \
    --method PUT \
    "repos/${repo_full_name}/environments/${env_name}" \
    --input - <<<"${payload}" >/dev/null
}

configure_environment_protected() {
  local env_name="$1"
  info "Configuring environment '${env_name}' for ${repo_full_name} (reviewer=${REVIEWER_LOGIN}, branch policy=main-only)"

  local payload
  payload="$(cat <<JSON
{
  "reviewers": [
    { "type": "User", "id": ${reviewer_id} }
  ],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
JSON
)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api --method PUT repos/${repo_full_name}/environments/${env_name} --input -"
    echo "${payload}"
    return 0
  fi

  gh api \
    --method PUT \
    "repos/${repo_full_name}/environments/${env_name}" \
    --input - <<<"${payload}" >/dev/null
}

add_main_branch_policy() {
  local env_name="$1"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api repos/${repo_full_name}/environments/${env_name}/deployment-branch-policies --jq '.branch_policies[].name'"
    echo "[dry-run] gh api --method POST repos/${repo_full_name}/environments/${env_name}/deployment-branch-policies -f name=main"
    return 0
  fi

  local existing
  existing="$(gh api "repos/${repo_full_name}/environments/${env_name}/deployment-branch-policies" --jq '.branch_policies[].name' 2>/dev/null || true)"
  if grep -qx "main" <<<"${existing}"; then
    info "Branch policy 'main' already present for environment '${env_name}'; skipping."
    return 0
  fi

  info "Restricting environment '${env_name}' deployments to branch 'main'"
  gh api \
    --method POST \
    "repos/${repo_full_name}/environments/${env_name}/deployment-branch-policies" \
    -f name=main >/dev/null
}

verify_environment_unprotected() {
  local env_name="$1"
  info "Verifying environment '${env_name}' has no protection rules"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api repos/${repo_full_name}/environments/${env_name}"
    return 0
  fi

  local env_json reviewer_count
  env_json="$(gh api "repos/${repo_full_name}/environments/${env_name}")"
  reviewer_count="$(echo "${env_json}" | jq '.protection_rules // [] | map(select(.type == "required_reviewers")) | length')"

  [[ "${reviewer_count}" == "0" ]] || die "Expected no required reviewers on '${env_name}', found ${reviewer_count}."

  success "environment=${env_name} reviewers=none"
}

verify_environment_protected() {
  local env_name="$1"
  info "Verifying environment '${env_name}' reviewer + branch policy"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api repos/${repo_full_name}/environments/${env_name}"
    echo "[dry-run] gh api repos/${repo_full_name}/environments/${env_name}/deployment-branch-policies"
    return 0
  fi

  local env_json reviewer_ids custom_policies protected_branches
  env_json="$(gh api "repos/${repo_full_name}/environments/${env_name}")"
  reviewer_ids="$(echo "${env_json}" | jq '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?.reviewer.id]')"
  custom_policies="$(echo "${env_json}" | jq -r '.deployment_branch_policy.custom_branch_policies')"
  protected_branches="$(echo "${env_json}" | jq -r '.deployment_branch_policy.protected_branches')"

  echo "${reviewer_ids}" | jq -e "any(. == ${reviewer_id})" >/dev/null \
    || die "Expected reviewer id ${reviewer_id} on '${env_name}', found ${reviewer_ids}."
  [[ "${custom_policies}" == "true" ]] || die "Expected custom_branch_policies=true on '${env_name}', got ${custom_policies}."
  [[ "${protected_branches}" == "false" ]] || die "Expected protected_branches=false on '${env_name}', got ${protected_branches}."

  local policies_json branch_names
  policies_json="$(gh api "repos/${repo_full_name}/environments/${env_name}/deployment-branch-policies")"
  branch_names="$(echo "${policies_json}" | jq -r '.branch_policies[].name')"
  grep -qx "main" <<<"${branch_names}" || die "Expected a 'main' deployment branch policy on '${env_name}', found: ${branch_names}."

  success "environment=${env_name} reviewer=${REVIEWER_LOGIN}(${reviewer_id}) branch_policy=main-only"
}

resolve_reviewer_id

configure_environment_unprotected "dev"

configure_environment_protected "staging"
add_main_branch_policy "staging"

configure_environment_protected "production"
add_main_branch_policy "production"

verify_environment_unprotected "dev"
verify_environment_protected "staging"
verify_environment_protected "production"

success "GitHub Environments configured for ${repo_full_name}"
