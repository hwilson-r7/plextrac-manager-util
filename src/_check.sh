# Handle running checks on the PlexTrac instance
# Usage
#   plextrac check        # run checks against the active installation
#   plextrac check --pre  # run pre-install checks

function mod_check() {
  if [ ${DO_PREINSTALL_CHECKS:-0} -eq 1 ]; then
    title "Running pre-installation checks"
    _check_system_meets_minimum_requirements
    _check_no_existing_installation
  else
    title "Running checks on installation at '${PLEXTRAC_HOME}'"
    _check_base_required_packages
    requires_user_plextrac
    if [ "$CONTAINER_RUNTIME" != "podman" ]; then
      info "Checking Docker Compose Config"
      compose_client config -q && info "Config check passed"
      pending=`composeConfigNeedsUpdated || true`
      if [ "$pending" != "" ]; then
          error "Pending Changes:"
          msg "    %s\n" "$pending"
      fi
    fi
    mod_etl_fix
    VALIDATION_ONLY=1 configure_couchbase_users
    postgres_metrics_validation
    check_for_maintenance_mode
  fi
}

function check_for_maintenance_mode() {
  title "Checking Maintenance Mode"
  IN_MAINTENANCE=$(wget -O - -q https://127.0.0.1/api/v2/health/full --no-check-certificate | jq .data.inMaintenanceMode) || IN_MAINTENANCE="Unknown"
  info "Maintenance Mode: $IN_MAINTENANCE"
}

function mod_etl_fix() {
  if [ "$CONTAINER_RUNTIME" == "podman" ]; then
    error "ETL Fix is not supported with Podman. Skipping"
    return
  else
    debug "Running ETL Fix"
    local cmd="compose_client"
    local dir=`compose_client exec plextracapi find -type d -name etl-logs`
    if [ -n "$dir" ]; then
      local owner=`compose_client exec plextracapi stat -c '%U' uploads/etl-logs`
      info "Checking volume permissions"
      if [ "$owner" != "plextrac" ]
        then
          info "Volume permissions are wrong; initiating fix"
          compose_client exec -u 0 plextracapi chown -R 1337:1337 uploads/etl-logs
      else
        info "Volume permissions are correct"
      fi
    else
      info "Fixing ETL Folder creation"
      compose_client exec plextracapi mkdir uploads/etl-logs
      compose_client exec plextracapi chown -R 1337:1337 uploads/etl-logs
    fi
  fi
}

# Check for an existing installation
function _check_no_existing_installation() {
  if [ ${IGNORE_EXISTING_INSTALLATION:-0} -eq 1 ]; then
    info "SKIPPING existing installation checks (check command arguments)"
    return 0
  fi
  info "Checking for pre-existing installation at '${PLEXTRAC_HOME}'"
  status=0
  if test -d "${PLEXTRAC_HOME}"; then
    debug "Found directory '${PLEXTRAC_HOME}'"
    if test -f "${PLEXTRAC_HOME}/docker-compose.yml"; then
      error "Found existing docker-compose.yml"
      status=1
    fi
    if test -f "${PLEXTRAC_HOME}/docker-compose.override.yml"; then
      error "Found existing docker-compose.override.yml"
      status=1
    fi
  fi
  return $status
}

function _check_system_meets_minimum_requirements() {
  info "Checking for initial packages"
  _check_base_required_packages
  info "Checking system meets minimum requirements"
  _check_os_supported_flavor_and_release
}

# Check common files to get the os flavor/release version
function _check_os_supported_flavor_and_release() {
  debug "Supported Operation Systems:"
  debug "`jq -r '(["NAME", "VERSIONS"] | (., map(length*"-"))), (.operating_systems[] | [.name, .versions[]]) | @tsv' <<<"$SYSTEM_REQUIREMENTS"`"
  debug ""

  name=$(head -1 /etc/os-release | cut -d '=' -f2 | tr -d '"')
  debug "Detected OS name: '${name}'"
  release=$(cat /etc/os-release | grep VERSION_ID | cut -d '=' -f2 | tr -d '"')
  debug "Detected OS release/version: '${release}'"

  query=".operating_systems[] | select((.name==\"$name\" and .versions[]==\"$release\")) | .family"

  output=`jq --exit-status -r "${query}" <<<"${SYSTEM_REQUIREMENTS}"` || \
    { error "Detected OS $name:$release does not meet system requirements"
      debug "json query filter: '${query}'"; debug "$output" ; exit 1 ; }
  log "Detected supported OS '$name:$release' from family '$output'"
}

# Check for some base required packages to even validate the system
function _check_base_required_packages() {
  requiredCommands=('jq' 'wget' 'unzip' 'bc')
  missingCommands=()
  status=0
  for cmd in ${requiredCommands[@]}; do
    debug "--"
    debug "Checking if '$cmd' is available"
    output="`command -V "$cmd" 2>&1`" || { debug "Missing required command '$cmd'"; debug "$output";
                                         missingCommands+=("$cmd"); status=1 ; continue; }
    debug "$cmd is available"
  done
  if [ $status -ne 0 ]; then
    error "Missing required commands: ${missingCommands[*]}"
    # special handling for centos/rhel, which need epel enabled
    if command -v yum >/dev/null 2>&1; then
      installCmd="${BOLD}\$${RESET} ${CYAN}"
      yum repolist -q | grep epel || installCmd+='yum install --assumeyes epel-release && '

      declare -A cmdToPkg=([jq]=jq [wget]=wget)
      installCmd="$installCmd""yum install --assumeyes`for cmd in ${missingCommands[@]}; do echo -n " ${cmdToPkg[$cmd]}"; done`"

      log "${BOLD}Please enable the EPEL repo and install required packages:"
      log "$installCmd"
    fi
    # debian based systems should all be roughly similar
    if command -v apt-get >/dev/null 2>&1; then
      declare -A cmdToPkg=([jq]=jq [wget]=wget)
      installCandidates=`for cmd in ${missingCommands[@]}; do echo -n " ${cmdToPkg[$cmd]}"; done`
      log "${BOLD}Please install required packages:"
      log "${BOLD}\$${RESET} ${CYAN}apt-get install -y ${installCandidates}"
    fi
  else
    info "All expected packages present: ${requiredCommands[@]}"
  fi
  return $status
}
