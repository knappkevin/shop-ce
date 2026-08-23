#!/bin/bash

function getMyPath() {
  # Version 1.0.1
  source="${BASH_SOURCE[1]}"
  while [ -h "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ $source != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname "$source")" && pwd
}

check_docker_compose() {
    if command -v docker &> /dev/null && docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
    else
        echo "Error: Neither 'docker compose' nor 'docker-compose' found"
        exit 1
    fi
    echo "Using command: $DOCKER_COMPOSE"
}

# Wait until the shop container is actually serving before returning.
# After `up -d` returns, the shop entrypoint still runs composer install, the
# DB schema + demodata import and theme setup (~1-2 min on a first run) before
# Apache answers requests. The compose healthcheck (`test ! -f
# /tmp/o3setup-running`) flips to "healthy" only once that work is done, so we
# poll it and show progress dots. Note: with the current healthcheck timing
# (interval 5s / retries 20 / start_period 5s) a long first-run setup can make
# the container report "unhealthy" transiently before it goes "healthy" — so we
# treat only "healthy" as done and keep waiting through anything else until the
# timeout. Must be called from the docker/ dir (where $DOCKER_COMPOSE resolves).
wait_for_shop() {
    local shop_cid status i
    local timeout=180   # up to 180 * 2s = 6 minutes

    shop_cid=$($DOCKER_COMPOSE ps -q shop)
    if [ -z "$shop_cid" ]; then
        echo "Warning: could not locate the shop container; skipping the readiness wait."
        return 0
    fi

    echo "Installing Composer dependencies, importing the database + demo data and setting up themes."
    echo "This can take 1-2 minutes on the first run — the shop is not reachable until it finishes."
    printf "Waiting for the shop to become ready"

    for ((i = 1; i <= timeout; i++)); do
        status=$(docker inspect --format '{{.State.Health.Status}}' "$shop_cid" 2>/dev/null || echo starting)
        if [ "$status" = "healthy" ]; then
            echo " ready."
            return 0
        fi
        printf "."
        sleep 2
    done

    echo
    echo "Timed out after $((timeout * 2))s waiting for the shop to become healthy (last status: '$status')."
    echo "Recent shop container logs:"
    docker logs --tail 40 "$shop_cid"
    return 1
}

start_containers() {
    MY_DIR=$(getMyPath)
    cd "$MY_DIR/docker" || { echo "Error: Docker directory not found"; exit 1; }
    check_docker_compose

    # Ensure the shared network exists (idempotent)
    docker network create o3shop-shared 2>/dev/null || true

    if $IS_WORKTREE; then
        MAIN_REPO_DIR=$(echo "$MY_DIR" | sed 's|/.claude/worktrees/.*||')
        MAIN_PROJECT="o3shop-$(basename "$MAIN_REPO_DIR")"
        DB_CONTAINER=$(docker ps -q \
            --filter "label=com.docker.compose.service=db" \
            --filter "label=com.docker.compose.project=$MAIN_PROJECT")
        if [ -z "$DB_CONTAINER" ]; then
            echo "ERROR: Shared MariaDB is not running."
            echo "  Start the main repo first: cd $MAIN_REPO_DIR && ./docker.sh start"
            exit 1
        fi
        DBROOT=$(grep "^O3SHOP_CONF_DBROOT=" "$MY_DIR/.env.example" | cut -d= -f2- | tr -d '"')
        echo "Creating database ${O3SHOP_CONF_DBNAME} in shared MariaDB..."
        docker exec "$DB_CONTAINER" mysql -uroot -p"${DBROOT}" -e \
            "CREATE DATABASE IF NOT EXISTS \`${O3SHOP_CONF_DBNAME}\`;
             GRANT ALL ON \`${O3SHOP_CONF_DBNAME}\`.* TO 'o3shop'@'%';" 2>/dev/null
    fi

    COMPOSE_PROFILES=""
    $IS_WORKTREE || COMPOSE_PROFILES="--profile db"

    echo "Pulling latest Docker images..."
    $DOCKER_COMPOSE pull
    echo "Starting Docker containers..."
    $DOCKER_COMPOSE $COMPOSE_PROFILES up -d
    if [ $? -ne 0 ]; then
        echo "Error: Failed to start Docker containers"
        exit 1
    fi

    wait_for_shop || exit 1

    echo "Docker containers started successfully"
    $DOCKER_COMPOSE ps
    echo "
+----------------+------------------------------------------+
| Credentials    |                                          |
+----------------+------------------------------------------+
| Shop URL       | http://localhost:${O3SHOP_PORT_HTTP}      |
| Admin URL      | http://localhost:${O3SHOP_PORT_HTTP}/admin/ |
| Shop URL (SSL) | https://localhost:${O3SHOP_PORT_HTTPS} (self-signed) |
| Admin Login    | admin@example.com                        |
| Admin Password | admin123                                 |
+----------------+------------------------------------------+
| Mailpit URL    | http://localhost:${O3SHOP_PORT_MAILPIT}   |
+----------------+------------------------------------------+
| Adminer URL    | http://localhost:${O3SHOP_PORT_ADMINER}   |
| DB Root User   | root                                     |
| DB Root PW     | supersecret                              |
| Database       | ${O3SHOP_CONF_DBNAME}                    |
+----------------+------------------------------------------+
"
    # Always-on asset pipeline: keep o3-theme CSS/JS rebuilt on save so a
    # browser refresh is enough to see style/script changes. Non-fatal.
    if [ -d "$MY_DIR/source/Application/views/o3-theme" ]; then
        echo "Starting o3-theme gulp watcher..."
        watch_start >/dev/null 2>&1 || echo "(watcher not started — run './docker.sh watch-start' later)"
    fi

    return 0
}

stop_containers() {
    MY_DIR=$(getMyPath)
    cd "$MY_DIR/docker" || { echo "Error: Docker directory not found"; exit 1; }
    check_docker_compose

    # When stopping the main repo, tear down all worktree stacks first
    if ! $IS_WORKTREE; then
        WORKTREE_PROJECTS=$(docker ps \
            --format '{{index .Labels "com.docker.compose.project.working_dir"}}|{{index .Labels "com.docker.compose.project"}}' \
            2>/dev/null \
            | awk -F'|' '$1 ~ /\.claude\/worktrees\// {print $2}' \
            | sort -u)
        for project in $WORKTREE_PROJECTS; do
            echo "Stopping worktree stack: $project"
            $DOCKER_COMPOSE -p "$project" down
        done
    fi

    echo "Stopping Docker containers..."
    $DOCKER_COMPOSE down
    if [ $? -eq 0 ]; then
        echo "Docker containers stopped successfully"
    else
        echo "Error: Failed to stop Docker containers"
        exit 1
    fi
}

rebuild_containers() {
    MY_DIR=$(getMyPath)
    rm -f "$MY_DIR/runned.txt"
    rm -f "$MY_DIR/source/tmp/"*.txt
    rm -f "$MY_DIR/source/tmp/"*.php
    rm -f "$MY_DIR/source/tmp/smarty/"*.php
    cd "$MY_DIR/docker" || { echo "Error: Docker directory not found"; exit 1; }
    check_docker_compose

    docker network create o3shop-shared 2>/dev/null || true

    COMPOSE_PROFILES=""
    $IS_WORKTREE || COMPOSE_PROFILES="--profile db"

    echo "Pulling latest Docker images..."
    $DOCKER_COMPOSE pull
    $DOCKER_COMPOSE build --no-cache
    echo "Starting Docker containers..."
    $DOCKER_COMPOSE $COMPOSE_PROFILES up -d
    if [ $? -eq 0 ]; then
        echo "Docker containers started successfully"
        $DOCKER_COMPOSE ps
        return 0
    else
        echo "Error: Failed to start Docker containers"
        exit 1
    fi
}

run_tests() {
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  NC='\033[0m'

  MY_DIR=$(getMyPath)
  cd "$MY_DIR/docker" || { echo "Error: Docker directory not found"; exit 1; }
  check_docker_compose

  if ! $DOCKER_COMPOSE ps shop 2>/dev/null | grep -q "Up\|running"; then
      echo -e "${RED} ✗ shop container is NOT running – aborting. ${NC}"
      exit 1
  fi

  echo -e "${GREEN}✓ shop container is running – executing tests${NC}"

  # Clear the application cache before the suite — stale Smarty / module /
  # container caches have masked real failures in the past (a stale class map
  # let a deleted class still resolve, an old Smarty template hid a syntax
  # fix, etc.). Cheap to run; eliminates a class of false-greens.
  echo -e "${GREEN}✓ Clearing application cache (oe:cache:clear)...${NC}"
  $DOCKER_COMPOSE exec shop php /var/www/html/bin/oe-console oe:cache:clear || {
      echo -e "${RED} ✗ oe:cache:clear failed – aborting before tests run. ${NC}"
      exit 1
  }

  $DOCKER_COMPOSE exec shop ./run-tests.sh "$@"
}

run_php_cs_fixer() {
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  NC='\033[0m'

  MY_DIR=$(getMyPath)
  cd "$MY_DIR/docker" || { echo "Error: Docker directory not found"; exit 1; }
  check_docker_compose

  if ! $DOCKER_COMPOSE ps shop 2>/dev/null | grep -q "Up\|running"; then
      echo -e "${RED} ✗ shop container is NOT running – aborting. ${NC}"
      exit 1
  fi

  if $DOCKER_COMPOSE exec shop php-cs-fixer --version &> /dev/null; then
      echo -e "${GREEN}✓ Running php-cs-fixer...${NC}"
      $DOCKER_COMPOSE exec shop php-cs-fixer fix || true
  else
      echo -e "${RED}php-cs-fixer not found in shop container. Please install it!${NC}"
      exit 1
  fi

  cd "$MY_DIR"
}

run_quarantine_tests() {
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  NC='\033[0m'

  MY_DIR=$(getMyPath)
  cd "$MY_DIR/docker" || { echo "Error: Docker directory not found"; exit 1; }
  check_docker_compose

  if ! $DOCKER_COMPOSE ps shop 2>/dev/null | grep -q "Up\|running"; then
      echo -e "${RED} ✗ shop container is NOT running – aborting. ${NC}"
      exit 1
  fi

  echo -e "${GREEN}✓ Running quarantine tests (slow / special tests)${NC}"
  $DOCKER_COMPOSE exec shop ./run-tests.sh --quarantine
}

run_npm_audits() {
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  NC='\033[0m'

  MY_DIR=$(getMyPath)
  cd "$MY_DIR/docker" || { echo "Error: Docker directory not found"; exit 1; }
  check_docker_compose

  if ! $DOCKER_COMPOSE ps shop 2>/dev/null | grep -q "Up\|running"; then
      echo -e "${RED} ✗ shop container is NOT running – aborting. ${NC}"
      exit 1
  fi

  # Themes audited as part of the regular test suite. Wave-theme is intentionally
  # NOT included — it's being deprecated and pins known-vulnerable jQuery 2.1.4
  # / Bootstrap 4.1.3 by design (see .claude/memory/project_o3-theme-dep-audit.md).
  # Auditing wave here would block every test run on issues we explicitly chose
  # not to fix.
  local audit_themes=("o3-theme")

  echo "---------------------------"
  echo "Running npm audit:"
  echo "---------------------------"

  for theme in "${audit_themes[@]}"; do
      local theme_path="source/Application/views/${theme}"
      if ! $DOCKER_COMPOSE exec shop test -f "/var/www/html/${theme_path}/package.json"; then
          echo -e "${YELLOW}⚠ Skipping npm audit for ${theme} — no package.json found.${NC}"
          continue
      fi
      echo -e "${GREEN}✓ Auditing ${theme_path}...${NC}"
      if ! $DOCKER_COMPOSE exec -w "/var/www/html/${theme_path}" shop npm audit; then
          echo -e "${RED}"
          echo "================================================================================"
          echo " ✗ npm audit reported vulnerabilities in ${theme}."
          echo "================================================================================"
          echo -e "${NC}"
          echo "What to do:"
          echo ""
          echo "  1. Re-read the report above (advisory titles + affected packages)."
          echo ""
          echo "  2. Apply the auto-fix (preferred — patch/minor bumps only):"
          echo ""
          echo "       $DOCKER_COMPOSE exec -w /var/www/html/${theme_path} \\"
          echo "                   shop npm audit fix"
          echo ""
          echo "     If only 'npm audit fix --force' resolves it, review the breaking"
          echo "     changes carefully before accepting (it may bump a major version)."
          echo ""
          echo "  3. Rebuild the theme bundle so the fix lands in the runtime CSS/JS:"
          echo ""
          echo "       $DOCKER_COMPOSE exec -w /var/www/html/${theme_path} \\"
          echo "                   shop npx gulp prod"
          echo ""
          echo "  4. Commit the updated package-lock.json (and rebuilt out/...) inside"
          echo "     the ${theme} repo — NOT shop-ce. Themes are separate git repos."
          echo ""
          echo "  5. Re-run './docker.sh test-all' to confirm the gate is now green."
          echo ""
          echo "If a vuln cannot be fixed promptly (e.g. no patch upstream), document the"
          echo "reason in .claude/memory/project_${theme}-dep-audit.md and raise it with"
          echo "the team. Do not silence this gate."
          echo ""
          exit 1
      fi
      echo -e "${GREEN}✓ npm audit clean for ${theme}.${NC}"
  done

  cd "$MY_DIR"
}

run_full_test_with_cs_fixer() {
  run_npm_audits
  run_php_cs_fixer
  echo ""
  echo "---------------------------"
  echo "Now running tests:"
  echo "---------------------------"
  run_tests
}

run_full_test_with_coverage() {
  run_npm_audits
  run_php_cs_fixer
  echo ""
  echo "---------------------------"
  echo "Now running tests with coverage:"
  echo "---------------------------"
  run_tests --coverage
  TEST_EXIT_CODE=$?
  if [ $TEST_EXIT_CODE -ne 0 ]; then
    return $TEST_EXIT_CODE
  fi

  echo ""
  echo "---------------------------"
  echo "Checking coverage threshold:"
  echo "---------------------------"

  check_docker_compose

  $DOCKER_COMPOSE exec shop php /var/www/html/bin/check-coverage-threshold.php \
    --clover /var/www/html/coverage/coverage.xml \
    --threshold "${COVERAGE_THRESHOLD:-90}"
}

# ============================================================================
# Theme / Stream orchestration
#
# One logical fix often spans TWO repos: shop-ce and the o3-theme store-
# front theme (a real git clone nested at source/Application/views/o3-theme,
# gitignored by shop-ce). The canonical theme clone lives in the MAIN
# checkout; parallel streams get isolation via `git worktree` of BOTH repos,
# so refs are shared and branches can never diverge between copies.
# ============================================================================

THEME_DIR_NAME="o3-theme"

canonical_theme_dir() {
    # The single theme repo instance lives in the MAIN checkout, even when
    # this script is executing inside a worktree.
    local main_root
    main_root=$(echo "$MY_DIR" | sed 's|/.claude/worktrees/.*||')
    echo "$main_root/source/Application/views/${THEME_DIR_NAME}"
}

current_theme_dir() {
    echo "$MY_DIR/source/Application/views/${THEME_DIR_NAME}"
}

slugify() {
    tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-40 | sed -E 's/^-+//; s/-+$//'
}

issue_title_and_slug() {
    # $1 = issue number; prints "title<TAB>slug". Falls back gracefully offline.
    local num="$1"
    local repo="${O3SHOP_ISSUE_REPO:-o3-shop/o3-shop}"
    local title slug
    title=$(gh issue view "$num" --repo "$repo" --json title --jq '.title' 2>/dev/null) || title=""
    if [ -z "$title" ]; then
        echo "issue-${num}"
        return 0
    fi
    slug=$(printf '%s' "$title" | slugify)
    printf '%s\t%s\n' "$title" "${slug:-issue-${num}}"
}

http_port_for_dir() {
    # Mirrors the deterministic port math applied to every checkout below.
    local dir="$1"
    local base hash block
    base=$(basename "$dir")
    if [[ "$dir" == *".claude/worktrees/"* ]]; then
        hash=$(echo -n "$base" | cksum | cut -d' ' -f1)
        block=$(( hash % 90 ))
        echo $(( 9000 + block * 10 ))
    else
        echo 8080
    fi
}

stack_is_up() {
    # $1 = checkout dir; true only when THAT project's shop service is running.
    local project="o3shop-$(basename "$1")"
    [ -n "$(docker ps -q \
        --filter "label=com.docker.compose.project=${project}" \
        --filter "label=com.docker.compose.service=shop" 2>/dev/null)" ]
}

dirty_count() {
    git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' '
}

ensure_stream_theme_worktree() {
    # Creates (or reuses) a theme worktree inside the given stream checkout,
    # sharing refs with the canonical clone. $1 = stream dir, $2 = theme branch.
    local stream_dir="$1" theme_branch="$2"
    local canon target
    canon=$(canonical_theme_dir)
    target="$stream_dir/source/Application/views/${THEME_DIR_NAME}"

    if [ ! -d "$canon/.git" ] && [ ! -f "$canon/.git" ]; then
        echo "ERROR: canonical theme clone missing at $canon"
        return 1
    fi

    if [ -d "$target" ]; then
        echo "Theme worktree already present ($(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null))"
        return 0
    fi

    mkdir -p "$(dirname "$target")"
    if git -C "$canon" show-ref --verify --quiet "refs/heads/${theme_branch}"; then
        git -C "$canon" worktree add "$target" "$theme_branch" || return 1
    else
        git -C "$canon" worktree add -b "$theme_branch" "$target" || return 1
    fi
    echo "Theme worktree created on branch ${theme_branch}"
}

bootstrap_theme_node_modules() {
    # A fresh git worktree carries no untracked files, i.e. no node_modules.
    # Hardlink-copy from the canonical clone (instant, shared inodes); fall
    # back to npm ci when that is impossible (different filesystem).
    local theme_dir
    theme_dir=$(current_theme_dir)
    [ -d "$theme_dir/node_modules" ] && return 0

    local canon
    canon=$(canonical_theme_dir)
    if [ -d "$canon/node_modules" ] \
       && [ "$(stat -c %d "$canon" 2>/dev/null)" = "$(stat -c %d "$MY_DIR" 2>/dev/null)" ]; then
        echo "Hardlinking node_modules from canonical clone..."
        cp -al "$canon/node_modules" "$theme_dir/node_modules" && return 0
    fi
    echo "Installing theme dependencies (npm ci, one-time)..."
    (cd "$theme_dir" && npm ci --no-audit --no-fund)
}

watch_start() {
    # Starts the o3-theme gulp dev watcher (build + watch) detached inside
    # THIS checkout's shop container. Idempotent via pidfile.
    cd "$MY_DIR/docker" || return 1
    local theme_rel="source/Application/views/${THEME_DIR_NAME}"
    bootstrap_theme_node_modules || return 1
    $DOCKER_COMPOSE exec -T shop bash -c '
        PIDFILE=/tmp/gulp-dev.pid
        if [ -f "$PIDFILE" ]; then
            OLD=$(cat "$PIDFILE" 2>/dev/null)
            # Verify the pid really is our watcher before trusting it.
            if [ -n "$OLD" ] && grep -qs gulp "/proc/$OLD/cmdline"; then
                echo "gulp watcher already running (pid $OLD)"
                exit 0
            fi
        fi
        cd "/var/www/html/'"$theme_rel"'" || exit 1
        touch /tmp/gulp-dev.log
        nohup gulp dev >>/tmp/gulp-dev.log 2>&1 &
        echo $! > "$PIDFILE"
        echo "gulp watcher started (pid $(cat "$PIDFILE"), log: container /tmp/gulp-dev.log)"
    '
}

watch_stop() {
    cd "$MY_DIR/docker" || return 1
    $DOCKER_COMPOSE exec -T shop bash -c '
        PIDFILE=/tmp/gulp-dev.pid
        STOPPED=0
        if [ -f "$PIDFILE" ]; then
            OLD=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$OLD" ] && kill "$OLD" 2>/dev/null; then
                STOPPED=1
            fi
            rm -f "$PIDFILE"
        fi
        # Sweep any strays (e.g. started without the pidfile).
        pkill -f "^node .*/gulp dev" 2>/dev/null && STOPPED=1
        [ "$STOPPED" = "1" ] && echo "gulp watcher stopped" || echo "no watcher running"
        true
    '
}

watch_status() {
    cd "$MY_DIR/docker" || return 1
    $DOCKER_COMPOSE exec -T shop bash -c '
        RUNNING=""
        if [ -f /tmp/gulp-dev.pid ]; then
            OLD=$(cat /tmp/gulp-dev.pid 2>/dev/null)
            [ -n "$OLD" ] && grep -qs gulp "/proc/$OLD/cmdline" && RUNNING="$OLD"
        fi
        if [ -n "$RUNNING" ]; then
            echo "gulp watcher running (pid $RUNNING)"
            echo "== last log lines (/tmp/gulp-dev.log) =="
            tail -5 /tmp/gulp-dev.log 2>/dev/null
        else
            echo "no gulp watcher running in this stack"
        fi
    '
}

theme_status() {
    local theme_dir
    theme_dir=$(current_theme_dir)
    if [ ! -d "$theme_dir/.git" ] && [ ! -f "$theme_dir/.git" ]; then
        echo "No theme working tree at $theme_dir"
        return 1
    fi
    local canon branch ahead behind dirty
    canon=$(canonical_theme_dir)
    branch=$(git -C "$theme_dir" rev-parse --abbrev-ref HEAD)
    dirty=$(dirty_count "$theme_dir")
    echo "Theme dir : $theme_dir"
    if [ "$theme_dir" != "$canon" ]; then
        echo "Kind      : worktree of canonical clone ($canon)"
    else
        echo "Kind      : canonical clone"
    fi
    echo "Branch    : $branch"
    echo "Dirty     : $dirty change(s)"
    git -C "$theme_dir" fetch --quiet origin 2>/dev/null
    ahead=$(git -C "$theme_dir" rev-list --count "origin/${branch}..${branch}" 2>/dev/null || echo "?")
    behind=$(git -C "$theme_dir" rev-list --count "${branch}..origin/${branch}" 2>/dev/null || echo "?")
    echo "Remote    : ahead $ahead / behind $behind vs origin/${branch}"
}

theme_branch() {
    # Creates or switches the CANONICAL clone's default working branch.
    local canon
    canon=$(canonical_theme_dir)
    git -C "$canon" show-ref --verify --quiet "refs/heads/$1" \
        && git -C "$canon" switch "$1" \
        || git -C "$canon" switch -c "$1"
}

theme_prod() {
    local theme_dir
    theme_dir=$(current_theme_dir)
    bootstrap_theme_node_modules || return 1
    (cd "$theme_dir" && npx gulp prod)
}

branch_merged_into_any() {
    # $1 = repo dir, $2 = branch, rest = candidate bases (e.g. origin/main ...)
    local repo="$1" br="$2"; shift 2
    local base
    for base in "$@"; do
        if git -C "$repo" rev-parse --verify --quiet "$base" >/dev/null &&
           git -C "$repo" merge-base --is-ancestor "$br" "$base" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

stream_resolve() {
    # $1 = issue number or free-form name -> sets globals:
    STREAM_TITLE="" STREAM_CE_BRANCH="" STREAM_THEME_BRANCH=""
    local ref="$1"
    if [[ "$ref" =~ ^[0-9]+$ ]]; then
        local out title slug
        out=$(issue_title_and_slug "$ref") || out=""
        title="${out%%$'\t'*}"
        slug="${out##*$'\t'}"
        STREAM_TITLE="$title"
        STREAM_CE_BRANCH="${ref}-${slug}"
        STREAM_THEME_BRANCH="fix/${ref}-${slug}"
    else
        STREAM_CE_BRANCH="$ref"
        STREAM_THEME_BRANCH="$ref"
    fi
}

stream_start() {
    local ref="$1"
    [ -z "$ref" ] && { echo "Usage: $0 stream start <issue-number|branch-name>"; return 1; }

    stream_resolve "$ref"
    local stream_dir="$MY_DIR/.claude/worktrees/${STREAM_CE_BRANCH}"

    if [ -d "$stream_dir" ]; then
        echo "Stream already exists: $stream_dir"
        echo "Re-enter it with: cd $stream_dir && ./docker.sh start"
        return 0
    fi

    echo "Creating shop-ce worktree '${STREAM_CE_BRANCH}'..."
    git -C "$MY_DIR" worktree add -b "$STREAM_CE_BRANCH" "$stream_dir" || {
        echo "ERROR: could not create worktree/branch (does the branch already exist?)"
        return 1
    }

    if ! ensure_stream_theme_worktree "$stream_dir" "$STREAM_THEME_BRANCH"; then
        echo "Rolling back shop-ce worktree..."
        git -C "$MY_DIR" worktree remove --force "$stream_dir"
        return 1
    fi

    echo ""
    echo "Booting stream stack (shared DB, dedicated ports)..."
    (cd "$stream_dir" && ./docker.sh start) || {
        echo "ERROR: stack failed to start; worktree kept for inspection."
        return 1
    }
    (cd "$stream_dir" && ./docker.sh watch-start) || true

    local port
    port=$(http_port_for_dir "$stream_dir")
    echo "
+----------------------------------------------------------+
| Stream ready                                             |
+----------------------------------------------------------+
| Dir         : $stream_dir
| Issue       : ${STREAM_TITLE:-<none>}
| shop-ce     : ${STREAM_CE_BRANCH}
| o3-theme    : ${STREAM_THEME_BRANCH}
| Shop URL    : http://localhost:${port}
| Assets      : gulp watcher running (live CSS/JS rebuilds)
+----------------------------------------------------------+
"
}

stream_each_dir() {
    # Prints the main checkout plus every worktree dir, one per line.
    echo "$MY_DIR"
    if [ -d "$MY_DIR/.claude/worktrees" ]; then
        for d in "$MY_DIR"/.claude/worktrees/*/; do
            [ -d "$d" ] && echo "${d%/}"
        done
    fi
}

stream_list() {
    local fmt="%-28s %-34s %-34s %-6s %-8s %s\n"
    printf "$fmt" "STREAM" "SHOP-BRANCH" "THEME-BRANCH" "PORT" "STACK" "DIRTY(ce/thm)"
    local d name ce_br th_br port up dce dth label
    while IFS= read -r d; do
        name=$(basename "$d")
        [[ "$d" == "$MY_DIR" ]] && label="(main)" || label="$name"
        ce_br=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")
        th_dir="$d/source/Application/views/${THEME_DIR_NAME}"
        if [ -d "$th_dir/.git" ] || [ -f "$th_dir/.git" ]; then
            th_br=$(git -C "$th_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")
            dth=$(dirty_count "$th_dir")
        else
            th_br="-"; dth="-"
        fi
        port=$(http_port_for_dir "$d")
        if stack_is_up "$d"; then up="up"; else up="down"; fi
        dce=$(dirty_count "$d")
        printf "$fmt" "$label" "$ce_br" "$th_br" "$port" "$up" "$dce/$dth"
    done < <(stream_each_dir)
}

stream_dir_for() {
    # $1 = stream name (worktree dir name) or empty for current checkout.
    local name="$1"
    if [ -z "$name" ]; then
        echo "$MY_DIR"
    elif [ -d "$MY_DIR/.claude/worktrees/$name" ]; then
        echo "$MY_DIR/.claude/worktrees/$name"
    else
        return 1
    fi
}

stream_push() {
    local name="$1" dir ce_br th_dir th_br
    dir=$(stream_dir_for "$name") || { echo "Unknown stream: $name"; return 1; }
    ce_br=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
    echo "Pushing shop-ce branch '$ce_br'..."
    git -C "$dir" push -u origin "$ce_br" || return 1
    th_dir="$dir/source/Application/views/${THEME_DIR_NAME}"
    if [ -d "$th_dir/.git" ] || [ -f "$th_dir/.git" ]; then
        th_br=$(git -C "$th_dir" rev-parse --abbrev-ref HEAD)
        echo "Pushing o3-theme branch '$th_br'..."
        git -C "$th_dir" push -u origin "$th_br" || return 1
    fi
}

stream_pr() {
    local name="$1" dir ce_br th_dir th_br num
    dir=$(stream_dir_for "$name") || { echo "Unknown stream: $name"; return 1; }
    ce_br=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
    th_dir="$dir/source/Application/views/${THEME_DIR_NAME}"
    th_br=$(git -C "$th_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    num=$(echo "$ce_br" | grep -oE '^[0-9]+')

    local title ce_body ce_issue=""
    if [ -n "$num" ]; then
        title=$(gh issue view "$num" --repo "${O3SHOP_ISSUE_REPO:-o3-shop/o3-shop}" --json title --jq '.title' 2>/dev/null)
        [ -z "$title" ] && title="$ce_br"
        ce_issue="Closes #$num
"
    else
        title="$ce_br"
    fi

    echo "Opening shop-ce PR (base ${O3SHOP_CE_BASE:-b-1.6})..."
    local ce_url
    ce_url=$(cd "$dir" && gh pr create \
        --title "$title" \
        --base "${O3SHOP_CE_BASE:-b-1.6}" \
        --body "$(printf '%s\nCompanion o3-theme branch: %s\n' "$ce_issue" "$th_br")") || ce_url=""
    [ -n "$ce_url" ] && echo "  $ce_url"

    if [ -n "$th_br" ] && [ "$th_br" != "-" ]; then
        echo "Opening o3-theme PR (base ${O3SHOP_THEME_BASE:-main})..."
        (cd "$th_dir" && gh pr create \
            --title "$title" \
            --base "${O3SHOP_THEME_BASE:-main}" \
            --body "$(printf '%s%s\nCompanion shop-ce PR: %s\n' "$ce_issue" "" "${ce_url:-<see issue>}")") || true
    fi
}

stream_done() {
    local name="$1" force="$2" dir ce_br th_dir th_br canon
    dir=$(stream_dir_for "$name") || { echo "Unknown stream: $name"; return 1; }
    [[ "$dir" == "$MY_DIR" ]] && { echo "Refusing to 'done' the main checkout."; return 1; }
    name=$(basename "$dir")

    ce_br=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
    th_dir="$dir/source/Application/views/${THEME_DIR_NAME}"
    th_br=$(git -C "$th_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    canon=$(canonical_theme_dir)

    if [ "$force" != "--force" ]; then
        local dce dth
        dce=$(dirty_count "$dir"); dth=$(dirty_count "$th_dir" 2>/dev/null || echo 0)
        if [ "$dce" != "0" ] || [ "$dth" != "0" ]; then
            echo "Refusing: uncommitted changes (shop-ce: $dce, o3-theme: $dth)."
            echo "Commit/push them first, or rerun with --force to discard."
            return 1
        fi
    fi

    echo "Stopping stream stack..."
    (cd "$dir" && ./docker.sh stop) || true
    (cd "$dir" && ./docker.sh watch-stop) >/dev/null 2>&1 || true

    if [ -n "$th_br" ] && [ -d "$th_dir" ]; then
        echo "Removing theme worktree ($th_br)..."
        git -C "$canon" worktree remove "$th_dir" 2>/dev/null \
            || git -C "$canon" worktree remove --force "$th_dir" || true
    fi

    echo "Removing shop-ce worktree ($ce_br)..."
    git -C "$MY_DIR" worktree remove "$dir" 2>/dev/null \
        || git -C "$MY_DIR" worktree remove --force "$dir" || true
    if [ -d "$dir" ]; then
        # Container entrypoints write as root; fall back to a root-privileged
        # cleanup via docker itself (no host sudo required). The bind-mount
        # target itself cannot be unlinked in-container, so clear contents and
        # rmdir from the host side.
        echo "Root-owned files present; cleaning via docker..."
        docker run --rm -v "$dir:/target" alpine:3.20 \
            sh -c 'rm -rf /target/* /target/.[!.]* /target/..?* 2>/dev/null; true' || true
        rmdir "$dir" 2>/dev/null || true
        git -C "$MY_DIR" worktree prune
    fi

    # Branch deletion: local only (remotes are managed explicitly), and only
    # when safely merged, unless --force.
    local bases_ce=(origin/main origin/b-1.7)
    local bases_th=(origin/main)
    if branch_merged_into_any "$MY_DIR" "$ce_br" "${bases_ce[@]}" || [ "$force" = "--force" ]; then
        git -C "$MY_DIR" branch -D "$ce_br" 2>/dev/null && echo "Deleted local shop-ce branch $ce_br"
    else
        echo "Kept local shop-ce branch $ce_br (not merged into ${bases_ce[*]})."
    fi
    if [ -n "$th_br" ]; then
        if branch_merged_into_any "$canon" "$th_br" "${bases_th[@]}" || [ "$force" = "--force" ]; then
            git -C "$canon" branch -D "$th_br" 2>/dev/null && echo "Deleted local o3-theme branch $th_br"
        else
            echo "Kept local o3-theme branch $th_br (not merged into ${bases_th[*]})."
        fi
    fi
    echo "Stream '$name' closed."
}

stream_prune() {
    # Deletes LOCAL branches whose tips are fully merged into origin/main or
    # origin/b-1.7 (shop-ce) / origin/main (theme). Protected names survive.
    local protected='^(main|master|b-[0-9.]+|kevin-.*)$'
    local br canon
    echo "== shop-ce =="
    while IFS= read -r br; do
        [[ "$br" =~ $protected ]] && continue
        if branch_merged_into_any "$MY_DIR" "$br" origin/main origin/b-1.7; then
            git -C "$MY_DIR" branch -d "$br" && echo "  deleted $br"
        fi
    done < <(git -C "$MY_DIR" for-each-ref --format='%(refname:short)' refs/heads)
    canon=$(canonical_theme_dir)
    echo "== o3-theme =="
    while IFS= read -r br; do
        [[ "$br" =~ $protected ]] && continue
        if branch_merged_into_any "$canon" "$br" origin/main; then
            git -C "$canon" branch -d "$br" && echo "  deleted $br"
        fi
    done < <(git -C "$canon" for-each-ref --format='%(refname:short)' refs/heads)
    git -C "$MY_DIR" worktree prune
}

MY_DIR=$(getMyPath)

# Detect whether we are running inside a git worktree
IS_WORKTREE=false
[[ "$MY_DIR" == *".claude/worktrees/"* ]] && IS_WORKTREE=true

# Compose project name: unique per checkout directory
COMPOSE_PROJECT_NAME="o3shop-$(basename "$MY_DIR")"

# Port block: deterministic hash of directory name for worktrees
if $IS_WORKTREE; then
    HASH=$(echo -n "$(basename "$MY_DIR")" | cksum | cut -d' ' -f1)
    BLOCK=$(( HASH % 90 ))
    O3SHOP_PORT_HTTP=$(( 9000 + BLOCK * 10 ))
    O3SHOP_PORT_ADMINER=$(( O3SHOP_PORT_HTTP + 1 ))
    O3SHOP_PORT_MAILPIT=$(( O3SHOP_PORT_HTTP + 2 ))
    O3SHOP_PORT_SMTP=$(( O3SHOP_PORT_HTTP + 3 ))
    O3SHOP_PORT_HTTPS=$(( O3SHOP_PORT_HTTP + 4 ))
    O3SHOP_CONF_DBNAME="o3shop_${O3SHOP_PORT_HTTP}"
else
    O3SHOP_PORT_HTTP=8080
    O3SHOP_PORT_ADMINER=8081
    O3SHOP_PORT_MAILPIT=8025
    O3SHOP_PORT_SMTP=1025
    O3SHOP_PORT_HTTPS=8443
fi

# Bootstrap .env if missing
if [ ! -f "$MY_DIR/.env" ]; then
    cp "$MY_DIR/.env.example" "$MY_DIR/.env" || { echo "Failed to copy .env.example to .env"; exit 1; }
    echo "Created .env file from example"
fi

# For worktrees: patch project .env with the computed DBNAME and SHOP URLs so
# the shop installer uses the right database and generates correct URLs.
# SSLSHOPURL is stripped and re-written with an explicit value too: .env.example
# defines it as "${O3SHOP_CONF_SHOPURL}", and since we re-append SHOPURL at the
# end, that interpolation would become a forward reference Dotenv cannot resolve
# (leaving the literal "${O3SHOP_CONF_SHOPURL}" in every SSL link). Writing it
# explicitly avoids the ordering trap entirely.
if $IS_WORKTREE; then
    grep -v "^O3SHOP_CONF_DBNAME=\|^O3SHOP_CONF_SHOPURL=\|^O3SHOP_CONF_SSLSHOPURL=" "$MY_DIR/.env" > "$MY_DIR/.env.tmp"
    echo "O3SHOP_CONF_DBNAME=\"${O3SHOP_CONF_DBNAME}\"" >> "$MY_DIR/.env.tmp"
    echo "O3SHOP_CONF_SHOPURL=\"http://localhost:${O3SHOP_PORT_HTTP}\"" >> "$MY_DIR/.env.tmp"
    echo "O3SHOP_CONF_SSLSHOPURL=\"http://localhost:${O3SHOP_PORT_HTTP}\"" >> "$MY_DIR/.env.tmp"
    mv "$MY_DIR/.env.tmp" "$MY_DIR/.env"
fi

# Always regenerate docker/.env so port vars and project name are current
{
    grep "^O3SHOP_CONF_DBUSER=" "$MY_DIR/.env.example"
    grep "^O3SHOP_CONF_DBPWD=" "$MY_DIR/.env.example"
    grep "^O3SHOP_CONF_DBROOT=" "$MY_DIR/.env.example"
    if $IS_WORKTREE; then
        echo "O3SHOP_CONF_DBNAME=${O3SHOP_CONF_DBNAME}"
    else
        grep "^O3SHOP_CONF_DBNAME=" "$MY_DIR/.env.example"
    fi
    echo "O3SHOP_PORT_HTTP=${O3SHOP_PORT_HTTP}"
    echo "O3SHOP_PORT_HTTPS=${O3SHOP_PORT_HTTPS}"
    echo "O3SHOP_PORT_ADMINER=${O3SHOP_PORT_ADMINER}"
    echo "O3SHOP_PORT_MAILPIT=${O3SHOP_PORT_MAILPIT}"
    echo "O3SHOP_PORT_SMTP=${O3SHOP_PORT_SMTP}"
    echo "COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}"
} > "$MY_DIR/docker/.env"

case "$1" in
    start)
        start_containers || exit 127
        ;;
    stop)
        stop_containers || exit 127
        ;;
    rebuild)
        rebuild_containers || exit 127
        ;;
    test)
        shift
        run_tests "$@" || exit 127
        ;;
    test-all)
        run_full_test_with_cs_fixer || exit 127
        ;;
    test-all-coverage)
        run_full_test_with_coverage || exit 127
        ;;
    quarantine)
        run_quarantine_tests || exit 127
        ;;
    cs-fixer)
        run_php_cs_fixer || exit 127
        ;;
    xdebug)
        shift
        toggle_xdebug "$@" || exit 127
        ;;
    playwright)
        shift
        cd "$MY_DIR/tests/Acceptance/playwright" || exit 127
        if [ ! -d node_modules ]; then
            echo "Installing Playwright dependencies (one-time)..."
            npm install || exit 127
            npx playwright install chromium || exit 127
        fi
        export SHOP_CONTAINER="${COMPOSE_PROJECT_NAME}-shop-1"
        npx playwright test "$@" || exit 127
        ;;
    theme)
        shift
        case "$1" in
            status)  theme_status ;;
            branch)  shift; [ -n "$1" ] && theme_branch "$1" || { echo "Usage: $0 theme branch <name>"; exit 127; } ;;
            prod)    theme_prod ;;
            *)       echo "Usage: $0 theme <status|branch <name>|prod>"; exit 127 ;;
        esac
        ;;
    watch-start)
        check_docker_compose && watch_start
        ;;
    watch-stop)
        check_docker_compose && watch_stop
        ;;
    watch-status)
        check_docker_compose && watch_status
        ;;
    stream)
        shift
        case "$1" in
            start)  shift; stream_start "$1" ;;
            list)   stream_list ;;
            push)   shift; stream_push "$1" ;;
            pr)     shift; stream_pr "$1" ;;
            done)   shift
                    if [ "$1" = "--force" ]; then
                        stream_done "" "--force"
                    else
                        stream_done "$1" "$2"
                    fi ;;
            prune)  stream_prune ;;
            *)      echo "Usage: $0 stream <start|list|push|pr|done|prune> [args]"
                    echo ""
                    echo "  start <issue#|name>   Create shop-ce worktree + matching o3-theme"
                    echo "                        worktree/branch, boot its stack, start watcher"
                    echo "  list                  Show every checkout: branches, port, stack, dirty"
                    echo "  push [name]           Push both repos' branches (explicit action)"
                    echo "  pr [name]             Open cross-linked PRs (shop-ce + o3-theme)"
                    echo "  done [name] [--force] Stop stack, remove worktrees, drop merged branches"
                    echo "  prune                 Delete local branches already merged (protected: main, b-*, kevin-*)"
                    exit 127 ;;
        esac
        ;;
    *)
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  start        Start Docker containers"
        echo "  stop         Stop Docker containers"
        echo "  rebuild      Rebuild Docker containers from scratch"
        echo ""
        echo "  test         Run unit tests (pass extra args to phpunit)"
        echo "  test-all     Run php-cs-fixer, then full test suite"
        echo "  test-all-coverage  Run php-cs-fixer, then full test suite with coverage report"
        echo "  cs-fixer     Run php-cs-fixer on the entire codebase"
        echo "  xdebug       Toggle step debugging: $0 xdebug <on|off|status>"
        echo "  quarantine   Run slow/special @group quarantine tests only"
        echo "  playwright   Run the Playwright browser test suite (auto-installs deps on first run)"
        echo ""
        echo "Parallel work streams (shop-ce + o3-theme coordinated):"
        echo "  stream start <issue#|name>   Spin up an isolated stream (worktrees in both repos,"
        echo "                               own ports/DB, live asset watcher)"
        echo "  stream list                  Overview of all checkouts and their state"
        echo "  stream push [name]           Push both repos' branches"
        echo "  stream pr [name]             Open cross-linked PRs for the stream"
        echo "  stream done [name] [--force] Close a stream: stop stack, remove worktrees/branches"
        echo "  stream prune                 Delete local branches merged into main/b-1.7"
        echo ""
        echo "Theme helpers:"
        echo "  theme status                 Show o3-theme branch/dirty/sync state of this checkout"
        echo "  theme branch <name>          Create/switch a branch in the canonical theme clone"
        echo "  theme prod                   Minified production build (o3-theme) of this checkout"
        echo "  watch-start|watch-stop|watch-status   Control the gulp dev watcher"
        echo ""
        echo "Options for 'test':"
        echo "  --fast           Skip shop install, call phpunit directly"
        echo "  --coverage       Generate coverage reports (clover, html, junit)"
        echo "  --all-failures   Don't stop at the first failure — run the full"
        echo "                   suite and collect every failure in one pass."
        echo "                   Use when one fix dominoes into many test"
        echo "                   updates (seed-data changes, fixture renames)."
        echo ""
        echo "Examples:"
        echo "  $0 start"
        echo "  $0 test --fast tests/Unit/Core/ConfigTest.php"
        echo "  $0 test --all-failures"
        echo "  $0 test-all"
        echo "  $0 quarantine"
        exit
        ;;
esac

exit 0
