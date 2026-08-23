# Agent Notes for O3-Shop (shop-ce)

## Docker Setup

- The project directory is **bind-mounted** into the container at `/var/www/html`.
- **Do NOT use `docker cp`** to copy files into the container. File changes on the host are immediately visible inside the container.
- Container name: `o3shop-shop-ce-shop-1` (compose project `o3shop-shop-ce`; worktree stacks use `o3shop-<worktree-name>-shop-1`)
- Database container: `o3shop-shop-ce-db-1` (MariaDB 10.11, named volume `db_data`)
- Container entrypoints may write files as **root**; non-root cleanups of
  worktrees fall back to a docker-based wipe (handled by `stream done`).

## Parallel Work Streams (shop-ce + o3-theme)

A logical fix often spans TWO repos: shop-ce and the o3-theme storefront theme
(real git clone nested at `source/Application/views/o3-theme`, gitignored).
Use the stream orchestrator instead of juggling clones manually:

```bash
./docker.sh stream start <issue#|name>  # worktree in BOTH repos + own stack (ports/DB) + gulp watcher
./docker.sh stream list                 # all checkouts: branches, port, stack up/down, dirty counts
./docker.sh stream push [name]          # push both repos' branches (explicit action only)
./docker.sh stream pr [name]            # cross-linked PRs (shop-ce base b-1.6, theme base main)
./docker.sh stream done [name] [--force]# stop stack, remove worktrees, drop merged local branches
./docker.sh stream prune                # delete local branches already merged into main / b-1.7
```

- Branch naming from issue numbers: shop-ce `<N>-<slug>`, o3-theme `fix/<N>-<slug>`; slug derived from the issue title in `O3SHOP_ISSUE_REPO` (default `o3-shop/o3-shop`).
- Streams share ONE MariaDB; each stack gets its own DB (`o3shop_<port>`) and deterministic ports — **no stop/start between streams**.
- The canonical theme clone lives in the MAIN checkout; stream theme dirs are `git worktree`s of it (shared refs — branches can never diverge between copies). Do not create second standalone clones.
- A `gulp dev --watch` runs inside each stack's shop container (`watch-start|watch-stop|watch-status`); CSS/JS rebuild on save, templates need no build. Run `./docker.sh theme prod` once for minified output before committing release assets.
- Theme helpers: `theme status`, `theme branch <name>`, `theme prod`.

## Running Tests

- **Full test suite from host**: `bash docker.sh test-all` (from project root)
- **Individual tests inside container**:
  ```bash
  docker exec o3shop-shop-ce-shop-1 bash -c "cd /var/www/html && sed -i 's/^O3SHOP_CONF_DBNAME=\"o3shop\"$/O3SHOP_CONF_DBNAME=\"o3shop-test\"/' .env && php vendor/bin/phpunit --bootstrap vendor/o3-shop/testing-library/bootstrap.php --no-coverage tests/Unit/Path/To/TestFile.php 2>&1; sed -i 's/^O3SHOP_CONF_DBNAME=\"o3shop-test\"$/O3SHOP_CONF_DBNAME=\"o3shop\"/' .env"
  ```
- In a stream worktree, its DB is `o3shop_<port>` (see `stream list`) — adjust the sed accordingly.
- `tests/phpunit.xml` has `stopOnError="true" stopOnFailure="true"` — any error/failure aborts the run.
- `--exclude-group quarantine` is used for normal test runs. `docker.sh quarantine` runs quarantine tests separately.
- `install_shop: true` in `test_config.yml` — `runtests` wrapper always rebuilds the test DB.

## Database

- Production DB: `o3shop`, Test DB: `o3shop-test`; per-stream DBs: `o3shop_<http-port>`
- DB credentials: user=o3shop, pwd=o3shop, root pwd=supersecret
- `.env` file controls which DB is active (`O3SHOP_CONF_DBNAME`)
