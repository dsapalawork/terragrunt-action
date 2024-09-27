#!/usr/bin/env bash
set -e
[[ "${TRACE}" == "1" ]] && set -x

# extract existing trap for signal
# shellcheck disable=SC2317 # used in traps
trap_extract() {
  local -r trap_cmd="${1:-}"
  [ "$trap_cmd" == 'trap' ] || (echo "${FUNCNAME[0]} 1st arg (trap cmd) must be 'trap'" >&2 && return 1)
  local -r dashes="${2:-}"
  [ "$dashes" == '--' ] || (echo "${FUNCNAME[0]} 2nd arg (separator) must be '--'" >&2 && return 1)
  local -r cmd="${3:-}"
  [ -n "$cmd" ] || (echo "${FUNCNAME[0]} 3rd arg (cmd) must not be empty" >&2 && return 1)
  local -r signal="${4:-}"
  [ -n "$signal" ] || (echo "${FUNCNAME[0]} 4th arg (signal) must not be empty" >&2 && return 1)

  printf '%s\n' "$cmd";
}
declare -f -t trap_extract

# prepend or append command to existing trap for signal
# shellcheck disable=SC2317 # used in traps
trap_modify() {
  if [ "$#" -lt 3 ]; then
    echo "${FUNCNAME[0]} requires at least 3 arguments: op, cmd, and signal(s)" >&2 && return 1
  fi

  local -r op="${1:-}"
  local -r cmd="${2:-}"
  shift 2 || (echo "${FUNCNAME[0]} incorrect number of arguments" >&2 && return 1)

  for signal in "$@"; do
    existing_trap="$(trap -p "$signal")"

    if [ -z "$existing_trap" ]; then
      # no existing trap, just set it
      trap -- "$cmd" "$signal" || (echo "unable to trap for $signal" >&2 && return 1)
      continue
    fi

    declare prepend_cmd='' append_cmd=''
    if [ "$op" == 'prepend' ]; then
      prepend_cmd="$cmd"
    elif [ "$op" == 'append' ]; then
      append_cmd="$cmd"
    else
      echo "${FUNCNAME[0]} 1st arg (op) must be 'prepend' or 'append'" >&2 && return 1
    fi
    readonly prepend_cmd append_cmd

    trap -- "$(
      [ -n "$prepend_cmd" ] && printf '%s\n' "$prepend_cmd"
      eval "trap_extract $(trap -p "$signal")"
      [ -n "$append_cmd" ] && printf '%s\n' "$append_cmd"
    )" "$signal" || (echo "unable to $op to trap for $signal" >&2 && return 1)
  done
}
declare -f -t trap_modify

# prepend command to existing trap for signal
# shellcheck disable=SC2317 # used in traps
trap_prepend() { trap_modify 'prepend' "$@"; }
declare -f -t trap_prepend

# append command to existing trap for signal
# shellcheck disable=SC2317 # used in traps
trap_append() { trap_modify 'append' "$@"; }
declare -f -t trap_append

# write log message with timestamp
function log {
  local -r message="$1"
  local -r timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  >&2 echo -e "${timestamp} ${message}"
}

# remove ANSI color codes from argument variable
function clean_colors {
  local -r input="$1"
  echo "${input}" | sed -E 's/\x1B\[[0-9;]*[mGK]//g'
}

# clean multiline text to be passed to Github API
function clean_multiline_text {
  local -r input="$1"
  local output
  output="${input//'%'/'%25'}"
  output="${output//$'\n'/'%0A'}"
  output="${output//$'\r'/'%0D'}"
  output="${output//$'<'/'%3C'}"
  echo "${output}"
}

# install and switch particular terraform version
function install_tofu {
  local -r version="$1"
  if [[ "${version}" == "none" ]]; then
    return
  fi
  log "Installing OpenTofu version ${version}"
  mise install -y opentofu@"${version}"
  mise use -g opentofu@"${version}"
}

function install_terraform {
  local -r version="$1"
  if [[ "${version}" == "none" ]]; then
    return
  fi
  log "Installing Terraform version ${version}"
  mise install terraform@"${version}"
  mise use -g terraform@"${version}"
}

# install passed terragrunt version
function install_terragrunt {
  local -r version="$1"
  if [[ "${version}" == "none" ]]; then
    return
  fi
  log "Installing Terragrunt version ${version}"
  mise install -y terragrunt@"${version}"
  mise use -g terragrunt@"${version}"
}

# run terragrunt commands in specified directory
# arguments: directory and terragrunt command
# output variables:
# terragrunt_log_file path to log file
# terragrunt_exit_code exit code of terragrunt command
function run_terragrunt {
  local -r dir="$1"
  local command
  IFS=" " read -r -a command <<< "$2"
  readonly command

  # terragrunt_log_file can be used later as file with execution output
  terragrunt_log_file=$(mktemp)

  cd "${dir}"
  terragrunt "${command[@]}" 2>&1 | tee "${terragrunt_log_file}"
  # terragrunt_exit_code can be used later to determine if execution was successful
  terragrunt_exit_code=${PIPESTATUS[0]}
}

# post comment to pull request
function comment {
  local -r message="$1"
  local comment_url
  comment_url=$(jq -r '.pull_request.comments_url' "$GITHUB_EVENT_PATH")
  # may be getting called from something like branch deploy
  if [[ "${comment_url}" == "" || "${comment_url}" == "null" ]]; then
    comment_url=$(jq -r '.issue.comments_url' "$GITHUB_EVENT_PATH")
  fi
  if [[ "${comment_url}" == "" || "${comment_url}" == "null" ]]; then
    log "Skipping comment as there is not comment url"
    return
  fi
  local -r escaped_message=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n')
  local -r tmpfile=$(mktemp)
  echo "{\"body\": \"$escaped_message\"}" > "$tmpfile"
  curl -s -S -H "Authorization: token $GITHUB_TOKEN" -H "Content-Type: application/json" -d @"$tmpfile" "$comment_url"
  rm "$tmpfile"
}

function setup_git {
  # Avoid git permissions warnings
  git config --global --add safe.directory /github/workspace
  # Also trust any subfolder within workspace
  git config --global --add safe.directory "*"
}

function setup_permissions {
  local -r dir="${1}"
  local -r uid="${2}"
  local -r gid="${3}"

  if [[ -e "${dir}" ]]; then
      sudo chown -R "$uid:$gid" "${dir}"
      sudo chmod -R o+rw "${dir}"
  fi
}

# Run INPUT_PRE_EXEC_* environment variables as Bash code
function setup_pre_exec {
  # Get all environment variables that match the pattern INPUT_PRE_EXEC_*
  local -r pre_exec_vars=$(env | grep -o '^INPUT_PRE_EXEC_[0-9]\+' | sort)
  # Loop through each pre-execution variable and execute its value (Bash code)
  local pre_exec_command
  while IFS= read -r pre_exec_var; do
    if [[ -n "${pre_exec_var}" ]]; then
      log "Evaluating ${pre_exec_var}"
      pre_exec_command="${!pre_exec_var}"
      eval "$pre_exec_command"
    fi
  done <<< "$pre_exec_vars"
}

# Run INPUT_POST_EXEC_* environment variables as Bash code
function setup_post_exec {
  # Get all environment variables that match the pattern INPUT_POST_EXEC_*
  local -r post_exec_vars=$(env | grep -o '^INPUT_POST_EXEC_[0-9]\+' | sort)
  # Loop through each pre-execution variable and execute its value (Bash code)
  local post_exec_command
  while IFS= read -r post_exec_var; do
    if [[ -n "${post_exec_var}" ]]; then
      log "Evaluating ${post_exec_var}"
      post_exec_command="${!post_exec_var}"
      eval "$post_exec_command"
    fi
  done <<< "$post_exec_vars"
}

function main {
  log "Starting Terragrunt Action"
  trap_append 'log "Finished Terragrunt Action Execution"' EXIT
  local -r tf_version=${INPUT_TF_VERSION}
  local -r tg_version=${INPUT_TG_VERSION}
  local -r tofu_version=${INPUT_TOFU_VERSION}
  local -r tg_command=${INPUT_TG_COMMAND}
  local -r tg_comment=${INPUT_TG_COMMENT:-0}
  local -r tg_add_approve=${INPUT_TG_ADD_APPROVE:-1}
  local -r tg_dir=${INPUT_TG_DIR:-.}

  if [[ (-z "${tf_version}") && (-z "${tofu_version}") ]]; then
    log "One of tf_version or tofu_version must be set"
    exit 1
  fi

  if [[ (-n "${tf_version}") && (-n "${tofu_version}") ]]; then
    log "Only one of tf_version and tofu_version may be set"
    exit 1
  fi

  if [[ -z "${tg_version}" ]]; then
    log "tg_version is not set"
    exit 1
  fi

  if [[ -z "${tg_command}" ]]; then
    log "tg_command is not set"
    exit 1
  fi
  setup_git
  # fetch the user id and group id under which the github action is running
  local -r uid=$(stat -c "%u" "/github/workspace")
  local -r gid=$(stat -c "%g" "/github/workspace")
  local -r action_user=$(whoami)

  setup_permissions "${tg_dir}" "${action_user}" "${action_user}"
  # shellcheck disable=SC2064 # we want to expand these vars when trap is defined
  trap_append "setup_permissions '$tg_dir' '$uid' '$gid'" EXIT
  setup_pre_exec

  if [[ -n "${tf_version}" ]]; then
    install_terraform "${tf_version}"
  fi
  if [[ -n "${tofu_version}" ]]; then
    if [[ "${tg_version}" < 0.52.0 ]]; then
      log "Terragrunt version ${tg_version} is incompatible with OpenTofu. Terragrunt version 0.52.0 or greater must be specified in order to use OpenTofu."
      exit 1
    fi
    install_tofu "${tofu_version}"
  fi

  install_terragrunt "${tg_version}"

  # add auto approve for apply and destroy commands
  local tg_arg_and_commands="${tg_command}"
  if [[ -n "${tofu_version}" ]]; then
    log "Using OpenTofu"
    export TERRAGRUNT_TFPATH=tofu
  fi

  if [[ "$tg_command" == "apply"* || "$tg_command" == "destroy"* || "$tg_command" == "run-all apply"* || "$tg_command" == "run-all destroy"* ]]; then
    export TERRAGRUNT_NON_INTERACTIVE=true
    export TF_INPUT=false
    export TF_IN_AUTOMATION=1

    if [[ "${tg_add_approve}" == "1" ]]; then
      local approvePattern="^(apply|destroy|run-all apply|run-all destroy)"
      # split command and arguments to insert -auto-approve
      if [[ $tg_arg_and_commands =~ $approvePattern ]]; then
          local matchedCommand="${BASH_REMATCH[0]}"
          local remainingArgs="${tg_arg_and_commands#"$matchedCommand"}"
          # remove leading whitespace characters from remainingArgs
          local strippedRemainingArgs="${remainingArgs#"${remainingArgs%%[![:space:]]*}"}"
          tg_arg_and_commands="${matchedCommand} -auto-approve ${strippedRemainingArgs}"
      fi
    fi
  fi
  run_terragrunt "${tg_dir}" "${tg_arg_and_commands}"
  setup_permissions "${tg_dir}"
  setup_permissions "${terragrunt_log_file}"
  setup_permissions "${GITHUB_OUTPUT}"
  # setup permissions for the output files
  setup_post_exec

  local -r log_file="${terragrunt_log_file}"
  # shellcheck disable=SC2064 # we want to expand these vars when trap is defined
  trap_append "rm -rf -- '$log_file'" EXIT

  local exit_code
  exit_code=$(("${terragrunt_exit_code}"))

  local terragrunt_log_content
  terragrunt_log_content=$(cat "${log_file}")
  # output without colors
  local terragrunt_output
  terragrunt_output=$(clean_colors "${terragrunt_log_content}")

  if [[ "${tg_comment}" == "1" ]]; then
    comment "<details>
<summary>Execution result of \"$tg_command\" in \"${tg_dir}\"</summary>

\`\`\`terraform
${terragrunt_output}
\`\`\`

</details>
    "
  fi

  echo "tg_action_exit_code=${exit_code}" >> "${GITHUB_OUTPUT}"

  local tg_action_output
  tg_action_output=$(clean_multiline_text "${terragrunt_output}")
  echo "tg_action_output=${tg_action_output}" >> "${GITHUB_OUTPUT}"

  exit $exit_code
}

main "$@"
