function podman_setup() {
  info "Configuring up PlexTrac with podman"
  debug "Podman Network Configuration"
  if container_client network exists plextrac; then
    debug "Network plextrac already exists"
  else
    debug "Creating network plextrac"
    container_client network create plextrac 1>/dev/null
  fi
  create_volume_directories
  declare -A pt_volumes
  pt_volumes["postgres-initdb"]="${PLEXTRAC_HOME:-.}/volumes/postgres-initdb"
  pt_volumes["redis"]="${PLEXTRAC_HOME:-.}/volumes/redis"
  pt_volumes["couchbase-backups"]="${PLEXTRAC_BACKUP_PATH}/couchbase"
  pt_volumes["postgres-backups"]="${PLEXTRAC_BACKUP_PATH}/postgres"
  pt_volumes["nginx_ssl_certs"]="${PLEXTRAC_HOME:-.}/volumes/nginx_ssl_certs"
  pt_volumes["nginx_logos"]="${PLEXTRAC_HOME:-.}/volumes/nginx_logos"
  for volume in "${!pt_volumes[@]}"; do
    if container_client volume exists "$volume"; then
      debug "-- Volume $volume already exists"
    else
      debug "-- Creating volume $volume"
      container_client volume create "$volume" --driver=local --opt device="${pt_volumes[$volume]}" --opt type=none --opt o="bind" 1>/dev/null
    fi
  done

  #####
  # Placeholder for right now. These ENVs may need to be set in the .env file if we are using podman.
  #####
  # POSTGRES_HOST_AUTH_METHOD=scram-sha-256
  # POSTGRES_INITDB_ARGS="--auth-local=scram-sha-256 --auth-host=scram-sha-256"
  # PG_MIGRATE_PATH=/usr/src/plextrac-api
  # PGDATA=/var/lib/postgresql/data/pgdata
}

function plextrac_install_podman() {
  var=$(declare -p "$1")
  eval "declare -A serviceValues="${var#*=}
  serviceValues[redis-entrypoint]=$(printf '%s' "--entrypoint=" "[" "\"redis-server\"" "," "\"--requirepass\"" "," "\"${REDIS_PASSWORD}\"" "]")
  serviceValues[cb-healthcheck]='--health-cmd=["wget","--user='$CB_ADMIN_USER'","--password='$CB_ADMIN_PASS'","-qO-","http://plextracdb:8091/pools/default/buckets/reportMe"]'
  serviceValues[api-image]="docker.io/plextrac/plextracapi:${UPGRADE_STRATEGY:-stable}"
  serviceValues[plextracnginx-image]="docker.io/plextrac/plextracnginx:${UPGRADE_STRATEGY:-stable}"
  if [ "$LETS_ENCRYPT_EMAIL" != '' ] && [ "$USE_CUSTOM_CERT" == 'false' ]; then
    serviceValues[plextracnginx-ports]="-p 0.0.0.0:443:443 -p 0.0.0.0:80:80"
  else
    serviceValues[plextracnginx-ports]="-p 0.0.0.0:443:443"
  fi
  serviceValues[migrations-env_vars]="-e COUCHBASE_URL=${COUCHBASE_URL:-http://plextracdb} -e CB_API_PASS=${CB_API_PASS} -e CB_API_USER=${CB_API_USER} -e REDIS_CONNECTION_STRING=${REDIS_CONNECTION_STRING:-redis} -e REDIS_PASSWORD=${REDIS_PASSWORD:?err} -e PG_HOST=${PG_HOST:-postgres} -e PG_MIGRATE_PATH=/usr/src/plextrac-api -e PG_SUPER_USER=${POSTGRES_USER:?err} -e PG_SUPER_PASSWORD=${POSTGRES_PASSWORD:?err} -e PG_CORE_ADMIN_PASSWORD=${PG_CORE_ADMIN_PASSWORD:?err} -e PG_CORE_ADMIN_USER=${PG_CORE_ADMIN_USER:?err} -e PG_CORE_DB=${PG_CORE_DB:?err} -e PG_RUNBOOKS_ADMIN_PASSWORD=${PG_RUNBOOKS_ADMIN_PASSWORD:?err} -e PG_RUNBOOKS_ADMIN_USER=${PG_RUNBOOKS_ADMIN_USER:?err} -e PG_RUNBOOKS_RW_PASSWORD=${PG_RUNBOOKS_RW_PASSWORD:?err} -e PG_RUNBOOKS_RW_USER=${PG_RUNBOOKS_RW_USER:?err} -e PG_RUNBOOKS_DB=${PG_RUNBOOKS_DB:?err} -e PG_CKEDITOR_ADMIN_PASSWORD=${PG_CKEDITOR_ADMIN_PASSWORD:?err} -e PG_CKEDITOR_ADMIN_USER=${PG_CKEDITOR_ADMIN_USER:?err} -e PG_CKEDITOR_DB=${PG_CKEDITOR_DB:?err} -e PG_CKEDITOR_RO_PASSWORD=${PG_CKEDITOR_RO_PASSWORD:?err} -e PG_CKEDITOR_RO_USER=${PG_CKEDITOR_RO_USER:?err} -e PG_CKEDITOR_RW_PASSWORD=${PG_CKEDITOR_RW_PASSWORD:?err} -e PG_CKEDITOR_RW_USER=${PG_CKEDITOR_RW_USER:?err} -e PG_TENANTS_WRITE_MODE=${PG_TENANTS_WRITE_MODE:-couchbase_only} -e PG_TENANTS_READ_MODE=${PG_TENANTS_READ_MODE:-couchbase_only} -e PG_CORE_RO_PASSWORD=${PG_CORE_RO_PASSWORD:?err} -e PG_CORE_RO_USER=${PG_CORE_RO_USER:?err} -e PG_CORE_RW_PASSWORD=${PG_CORE_RW_PASSWORD:?err} -e PG_CORE_RW_USER=${PG_CORE_RW_USER:?err}"
  title "Installing PlexTrac Instance"
  requires_user_plextrac
  mod_configure
  info "Starting Databases before other services"
  # Check if DB running first, then start it.
  debug "Handling Databases..."
  for database in "${databaseNames[@]}"; do
    info "Checking $database"
    if container_client container exists "$database"; then
      debug "$database already exists"
      # if database exists but isn't running
      if [ "$(container_client container inspect --format '{{.State.Status}}' "$database")" != "running" ]; then
        info "Starting $database"
        container_client start "$database" 1>/dev/null
      else
        info "$database is already running"
      fi
    else
      info "Container doesn't exist. Creating $database"
      if [ "$database" == "plextracdb" ]; then
        local volumes=${serviceValues[cb-volumes]}
        local ports="${serviceValues[cb-ports]}"
        local healthcheck="${serviceValues[cb-healthcheck]}"
        local image="${serviceValues[cb-image]}"
        local env_vars=""
      elif [ "$database" == "postgres" ]; then
        local volumes="${serviceValues[pg-volumes]}"
        local ports="${serviceValues[pg-ports]}"
        local healthcheck="${serviceValues[pg-healthcheck]}"
        local image="${serviceValues[pg-image]}"
        local env_vars="${serviceValues[pg-env-vars]}"
      fi
      container_client run "${serviceValues[env-file]}" "$env_vars" --restart=always "$healthcheck" \
        "$volumes" --name="${database}" "${serviceValues[network]}" "$ports" -d "$image" 1>/dev/null
      info "Sleeping to give $database a chance to start up"
      local progressBar
      for i in `seq 1 10`; do
        progressBar=`printf ".%.0s%s"  {1..$i} "${progressBar:-}"`
        msg "\r%b" "${GREEN}[+]${RESET} ${NOCURSOR}${progressBar}"
        sleep 2
      done
      >&2 echo -n "${RESET}"
      log "Done"
    fi
  done
  mod_autofix
  if [ ${RESTOREONINSTALL:-0} -eq 1 ]; then
    info "Restoring from backups"
    log "Restoring databases first"
    RESTORETARGET="couchbase" mod_restore
    if [ -n "$(ls -A -- ${PLEXTRAC_BACKUP_PATH}/postgres/)" ]; then
      RESTORETARGET="postgres" mod_restore
    else
      debug "No postgres backups to restore"
    fi
    debug "Checking for uploads to restore"
    if [ -n "$(ls -A -- ${PLEXTRAC_BACKUP_PATH}/uploads/)" ]; then
      log "Starting API to prepare for uploads restore"
      if container_client container exists plextracapi; then
        if [ "$(container_client container inspect --format '{{.State.Status}}' plextracapi)" != "running" ]; then
          container_client start plextracapi 1>/dev/null
        else
          log "plextracapi is already running"
        fi
      else
        debug "Creating plextracapi"
        container_client run "${serviceValues[env-file]}" --restart=always "$healthcheck" \
        "$volumes" --name="plextracapi" "${serviceValues[network]}" -d "${serviceValues[api-image]}" 1>/dev/null
      fi
      log "Restoring uploads"
      RESTORETARGET="uploads" mod_restore
    else
      debug "No uploads to restore"
    fi
  fi
  
  mod_start "${INSTALL_WAIT_TIMEOUT:-600}" # allow up to 10 or specified minutes for startup on install, due to migrations
  mod_info
  info "Post installation note:"
  log "If you wish to have access to historical logs, you can configure docker to send logs to journald."
  log "Please see the config steps at"
  log "https://docs.plextrac.com/plextrac-documentation/product-documentation-1/on-premise-management/setting-up-historical-logs"
}

function plextrac_start_podman() {
  var=$(declare -p "$1")
  eval "declare -A serviceValues="${var#*=}
  serviceValues[redis-entrypoint]=$(printf '%s' "--entrypoint=" "[" "\"redis-server\"" "," "\"--requirepass\"" "," "\"${REDIS_PASSWORD}\"" "]")
  serviceValues[cb-healthcheck]='--health-cmd=["wget","--user='$CB_ADMIN_USER'","--password='$CB_ADMIN_PASS'","-qO-","http://plextracdb:8091/pools/default/buckets/reportMe"]'
  serviceValues[api-image]="docker.io/plextrac/plextracapi:${UPGRADE_STRATEGY:-stable}"
  serviceValues[plextracnginx-image]="docker.io/plextrac/plextracnginx:${UPGRADE_STRATEGY:-stable}"
  if [ "$LETS_ENCRYPT_EMAIL" != '' ] && [ "$USE_CUSTOM_CERT" == 'false' ]; then
    serviceValues[plextracnginx-ports]="-p 0.0.0.0:443:443 -p 0.0.0.0:80:80"
  else
    serviceValues[plextracnginx-ports]="-p 0.0.0.0:443:443"
  fi
  serviceValues[migrations-env_vars]="-e COUCHBASE_URL=${COUCHBASE_URL:-http://plextracdb} -e CB_API_PASS=${CB_API_PASS} -e CB_API_USER=${CB_API_USER} -e REDIS_CONNECTION_STRING=${REDIS_CONNECTION_STRING:-redis} -e REDIS_PASSWORD=${REDIS_PASSWORD:?err} -e PG_HOST=${PG_HOST:-postgres} -e PG_MIGRATE_PATH=/usr/src/plextrac-api -e PG_SUPER_USER=${POSTGRES_USER:?err} -e PG_SUPER_PASSWORD=${POSTGRES_PASSWORD:?err} -e PG_CORE_ADMIN_PASSWORD=${PG_CORE_ADMIN_PASSWORD:?err} -e PG_CORE_ADMIN_USER=${PG_CORE_ADMIN_USER:?err} -e PG_CORE_DB=${PG_CORE_DB:?err} -e PG_RUNBOOKS_ADMIN_PASSWORD=${PG_RUNBOOKS_ADMIN_PASSWORD:?err} -e PG_RUNBOOKS_ADMIN_USER=${PG_RUNBOOKS_ADMIN_USER:?err} -e PG_RUNBOOKS_RW_PASSWORD=${PG_RUNBOOKS_RW_PASSWORD:?err} -e PG_RUNBOOKS_RW_USER=${PG_RUNBOOKS_RW_USER:?err} -e PG_RUNBOOKS_DB=${PG_RUNBOOKS_DB:?err} -e PG_CKEDITOR_ADMIN_PASSWORD=${PG_CKEDITOR_ADMIN_PASSWORD:?err} -e PG_CKEDITOR_ADMIN_USER=${PG_CKEDITOR_ADMIN_USER:?err} -e PG_CKEDITOR_DB=${PG_CKEDITOR_DB:?err} -e PG_CKEDITOR_RO_PASSWORD=${PG_CKEDITOR_RO_PASSWORD:?err} -e PG_CKEDITOR_RO_USER=${PG_CKEDITOR_RO_USER:?err} -e PG_CKEDITOR_RW_PASSWORD=${PG_CKEDITOR_RW_PASSWORD:?err} -e PG_CKEDITOR_RW_USER=${PG_CKEDITOR_RW_USER:?err} -e PG_TENANTS_WRITE_MODE=${PG_TENANTS_WRITE_MODE:-couchbase_only} -e PG_TENANTS_READ_MODE=${PG_TENANTS_READ_MODE:-couchbase_only} -e PG_CORE_RO_PASSWORD=${PG_CORE_RO_PASSWORD:?err} -e PG_CORE_RO_USER=${PG_CORE_RO_USER:?err} -e PG_CORE_RW_PASSWORD=${PG_CORE_RW_PASSWORD:?err} -e PG_CORE_RW_USER=${PG_CORE_RW_USER:?err}"
  
  title "Starting PlexTrac..."
  requires_user_plextrac
  
  for service in "${serviceNames[@]}"; do
  debug "Checking $service"
    local volumes=""
    local ports=""
    local healthcheck=""
    local image="${serviceValues[api-image]}"
    local restart_policy="--restart=always"
    local entrypoint=""
    local deploy=""
    local env_vars=""
    if container_client container exists "$service"; then
      if [ "$(container_client container inspect --format '{{.State.Status}}' "$service")" != "running" ]; then
        info "Starting $service"
        container_client start "$service" 1>/dev/null
      else
        info "$service is already running"
      fi
    else
      if [ "$service" == "plextracdb" ]; then
        local volumes="${serviceValues[cb-volumes]}"
        local ports="${serviceValues[cb-ports]}"
        local healthcheck="${serviceValues[cb-healthcheck]}"
        local image="${serviceValues[cb-image]}"
      elif [ "$service" == "postgres" ]; then
        local volumes="${serviceValues[pg-volumes]}"
        local ports="${serviceValues[pg-ports]}"
        local healthcheck="${serviceValues[pg-healthcheck]}"
        local image="${serviceValues[pg-image]}"
        local env_vars="${serviceValues[pg-env-vars]}"
      elif [ "$service" == "plextracapi" ]; then
        local volumes="${serviceValues[api-volumes]}"
        local healthcheck="${serviceValues[api-healthcheck]}"
        local image="${serviceValues[api-image]}"
      elif [ "$service" == "redis" ]; then
        local volumes="${serviceValues[redis-volumes]}"
        local image="${serviceValues[redis-image]}"
        local entrypoint="${serviceValues[redis-entrypoint]}"
        local healthcheck="${serviceValues[redis-healthcheck]}"
      elif [ "$service" == "notification-engine" ]; then
        local entrypoint="${serviceValues[notification-engine-entrypoint]}"
        local healthcheck="${serviceValues[notification-engine-healthcheck]}"
      elif [ "$service" == "notification-sender" ]; then
        local entrypoint="${serviceValues[notification-sender-entrypoint]}"
        local healthcheck="${serviceValues[notification-sender-healthcheck]}"
      elif [ "$service" == "contextual-scoring-service" ]; then
        local entrypoint="${serviceValues[contextual-scoring-service-entrypoint]}"
        local healthcheck="${serviceValues[contextual-scoring-service-healthcheck]}"
        local deploy="" # update this
      elif [ "$service" == "migrations" ]; then
        local volumes="${serviceValues[migrations-volumes]}"
        local env_vars="${serviceValues[migrations-env_vars]}"
      elif [ "$service" == "plextracnginx" ]; then
        local volumes="${serviceValues[plextracnginx-volumes]}"
        local ports="${serviceValues[plextracnginx-ports]}"
        local image="${serviceValues[plextracnginx-image]}"
        local healthcheck="${serviceValues[plextracnginx-healthcheck]}"
      fi
      info "Creating $service"
      # This specific if loop is because Bash escaping and the specific need for the podman flag --entrypoint were being a massive pain in figuring out. After hours of effort, simply making an if statement here and calling podman directly fixes the escaping issues
      if [ "$service" == "migrations" ]; then
        debug "Running migrations"
        podman run ${serviceValues[env-file]} $env_vars --entrypoint='["/bin/sh","-c","npm run maintenance:enable && npm run pg:migrate && npm run db:migrate && npm run pg:etl up all && npm run maintenance:disable"]' --restart=no $healthcheck \
        $volumes:z --name=${service} $deploy ${serviceValues[network]} $ports -d $image 1>/dev/null
        continue
      fi
      container_client run ${serviceValues[env-file]} $env_vars $entrypoint $restart_policy $healthcheck \
        $volumes --name=${service} $deploy ${serviceValues[network]} $ports -d $image 1>/dev/null
    fi
  done
  waitTimeout=${2:-90}
  info "Waiting up to ${waitTimeout}s for application startup"
  local progressBar
  # todo: extract this to function waitForCondition
  # it should take an optional param which is a function
  # that should return 0 when ready
  (
    while true; do
      progressBar=$(printf ".%s" "${progressBar:-}")
      msg "\r%b" "${GREEN}[+]${RESET} ${NOCURSOR}${progressBar}"
      sleep 2
    done &
    progressBarPid=$!
    debug "Waiting for migrations to run and complete if needed"
    timeout --preserve-status $waitTimeout podman wait migrations >/dev/null || { error "Migrations exceeded timeout"; kill $progressBarPid; exit 1; } &

    timeoutPid=$!
    trap "kill $progressBarPid $timeoutPid >/dev/null 2>&1 || true" SIGINT SIGTERM

    wait $timeoutPid

    kill $progressBarPid >/dev/null 2>&1 || true
    >&2 echo -n "${RESET}"

    msg " Done"
  )
}

function podman_pull_images() {

  declare -A service_images
  service_images[cb-image]="docker.io/plextrac/plextracdb:7.2.0"
  service_images[pg-image]="docker.io/postgres:14-alpine"
  service_images[api-image]="docker.io/plextrac/plextracapi:${UPGRADE_STRATEGY:-stable}"
  service_images[redis-image]="docker.io/redis:6.2-alpine"
  service_images[plextracnginx-image]="docker.io/plextrac/plextracnginx:${UPGRADE_STRATEGY:-stable}"

  info "Pulling updated container images"
  for image in "${service_images[@]}"; do
    debug "Pulling $image"
    podman pull $image 1>/dev/null
  done
  log "Done."
}

function podman_remove() {
  for service in "${serviceNames[@]}"; do
    if [ "$service" != "plextracdb" ] && [ "$service" != "postgres" ]; then
      if podman container exists "$service"; then
        podman stop "$service" 1>/dev/null
        podman rm -f "$service" 1>/dev/null
        podman image prune -f 1>/dev/null
      fi
    fi
  done
}
