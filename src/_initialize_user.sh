function create_user() {
  # create "plextrac" user with UID/GID 1337 to match the UID/GID of the container user
  # this is required for anything in the uploads directory to
  if ! id -u "plextrac" >/dev/null 2>&1
  then
    info "Adding plextrac user..."
    if [ "$CONTAINER_RUNTIME" == "podman" ]; then
      useradd --uid 1337 \
              --shell /bin/bash \
              --create-home --home "${PLEXTRAC_HOME}" \
              plextrac
    else
      useradd --uid 1337 \
              --groups docker \
              --shell /bin/bash \
              --create-home --home "${PLEXTRAC_HOME}" \
              plextrac
    fi
    log "Done."
  fi
}

function configure_user_environment() {
  info "Configuring plextrac user environment..."
    PROFILES=("/etc/skel/.profile" "/etc/skel/.bash_profile" "/etc/skel/.bashrc")
    for profile in "${PROFILES[@]}"; do
      if [ -f "${profile}" ]; then
        debug "Copying ${profile} to ${PLEXTRAC_HOME}"
        cp "${profile}" "${PLEXTRAC_HOME}"
      else
        debug "${profile} does not exist, skipping"
      fi
    done
    mkdir -p "${PLEXTRAC_HOME}/.local/bin"
    sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/' "${PLEXTRAC_HOME}/.bashrc"
    grep -E 'PATH=${HOME}/.local/bin:$PATH' "${PLEXTRAC_HOME}/.bashrc" || echo 'PATH=${HOME}/.local/bin:$PATH' >> "${PLEXTRAC_HOME}/.bashrc"
    log "Done."
}

function copy_scripts() {
  info "Copying plextrac CLI to user PATH..."
  tmp=`mktemp -p ~/ plextrac-XXX`
  debug "tmp script location: $tmp"
  debug "`$0 dist 2>/dev/null > $tmp && cp -uv $tmp "${PLEXTRAC_HOME}/.local/bin/plextrac"`"
  chmod +x "${PLEXTRAC_HOME}/.local/bin/plextrac"
  log "Done."
}

function fix_file_ownership() {
  info "Fixing file ownership in ${PLEXTRAC_HOME} for plextrac"
  chown -R plextrac:plextrac "${PLEXTRAC_HOME}"
  log "Done."
} 
