---
name: launching-a-fresh-live-shop
description: Use when you need a clean productive ("live") O3-Shop to reproduce or verify a storefront/build issue. Wipes the shop stack + DB + theme clone, reinstalls from the latest upstream theme and demodata, enables productive mode, fixes web-writable ownership, and verifies. Triggers: live shop, productive mode, oxproductive, fresh install, main.min.css, PurgeCSS dropped CSS, thumbnails not writable, verify an upstream theme/demodata fix.
---

# Launching a Fresh Live Shop

A **live** shop means `oxshops.oxproductive = 1`. In that mode o3-theme serves
`out/o3-theme/src/css/main.min.css` (the PurgeCSS build) instead of the unpurged
`main.css`. Bugs that only appear in production (e.g. CSS classes PurgeCSS
dropped) can only be seen in productive mode.

This skill recreates a clean, productive shop **from scratch** so you can
reproduce/verify against the *latest upstream* theme + demodata rather than a
stale local clone.

## Key concepts (the traps)

- **Productive mode refuses to render while `source/Setup/index.php` exists**
  (`ShopControl::_runOnce()`, `source/Core/ShopControl.php:616`). So `source/Setup`
  must be **present during install** and **removed for production**.
- **If `source/Setup` is missing at install time, `bin/o3-setup` silently skips the
  schema import** (`database_schema.sql` not found) → migrations then fail on an
  empty DB. Restore Setup before installing.
- **The entrypoint only clones themes/demodata when the directory is empty** and
  never updates an existing clone. To pick up an upstream fix you must delete the
  clone (theme) or `git pull` it (demodata satellite).
- **The entrypoint/setup run as root; Apache runs as `www-data` (uid 33).** The
  writable dirs must be owned by `www-data` or thumbnail/image writes fail.
- Deleting the theme clone leaves `source/out/o3-theme` as a dangling symlink;
  delete both, or the entrypoint aborts on `ln -s` ("File exists").

## Procedure

### 1. Isolate a checkout

```bash
git fetch upstream
git worktree add .claude/worktrees/<name> -b <branch> upstream/b-1.7
```

(On a dev-stream build this is `./docker.sh stream start <issue>` — it makes a
worktree in shop-ce and o3-theme, its own stack/DB, and a gulp watcher.)

### 2. Bring git up to date (both repos)

```bash
# shop-ce: get the latest b-1.7 (fixes, e.g. search suggestions)
git rebase upstream/b-1.7

# demodata satellite (top-level dir, gitignored)
git -C shop-demodata-ce fetch origin && git -C shop-demodata-ce checkout main && git -C shop-demodata-ce pull --ff-only
```

o3-theme is re-cloned in step 4, so it will already be current.

### 3. Tear down the old shop state

```bash
./docker.sh stop
docker exec o3shop-shop-ce-db-1 mysql -uroot -psupersecret \
  -e "DROP DATABASE IF EXISTS \`o3shop_<port>\`;"

# force a fresh theme clone (delete dir + dangling symlink)
rm -rf source/Application/views/o3-theme source/out/o3-theme
# if node_modules is root-owned the rm as your user will fail; wipe via container:
#   docker run --rm -v "$PWD/source/Application/views:/v" --entrypoint sh \
#     o3shop-shop-ce-shop:latest -c 'rm -rf /v/o3-theme'

git checkout -- source/Setup          # installer needs Setup/Sql/database_schema.sql
rm -f runned.txt                       # force full re-import (may need the container)
```

### 4. Start (installs + clones upstream theme)

```bash
./docker.sh start     # composer install, clone o3-theme main, schema + demodata, themes
```

Wait for `healthy`. If a later `SHOW TABLES` is empty (Setup was missing at
install time), re-run the installer manually:

```bash
docker exec <shop-container> bash -lc 'cd /var/www/html && php bin/o3-setup'
```

### 5. Make it productive ("live")

```bash
mv source/Setup /tmp/Setup-<port>-backup            # remove setup dir
docker exec o3shop-shop-ce-db-1 mysql -uo3shop -po3shop o3shop_<port> \
  -e "UPDATE oxshops SET oxproductive=1 WHERE oxid=1;"

docker exec <shop-container> bash -lc '
  for d in source/out/pictures source/out/downloads source/out/media \
           source/tmp source/log source/cache source/export; do
    [ -e "/var/www/html/$d" ] && chown -R www-data:www-data "/var/www/html/$d"
  done
  php /var/www/html/bin/oe-console oe:cache:clear >/dev/null
  rm -rf /var/www/html/source/tmp/*
'
```

### 6. Verify

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:<port>/
curl -s http://localhost:<port>/ | grep -o 'main[^"]*\.css[^"]*'          # expect main.min.css
curl -s http://localhost:<port>/out/o3-theme/src/css/main.min.css | grep -c 'search-suggest'
curl -s "http://localhost:<port>/index.php?cl=searchsuggest&searchparam=Kuh"

# thumbnail write + serve
docker exec -u www-data <shop-container> bash -c \
  'touch /var/www/html/source/out/pictures/generated/_w && rm /var/www/html/source/out/pictures/generated/_w'
curl -s -o /dev/null -w "%{http_code}\n" \
  http://localhost:<port>/out/pictures/master/product/1/35_10.jpg

# E2E
cd tests/Acceptance/playwright
SHOP_URL=http://localhost:<port> npx playwright test tests/storefront/<spec>.spec.ts
```

## Notes

- Ports and DB per stack: main checkout `8080` / `o3shop`; worktree
  `o3shop-<dirname>` with a deterministic port block (`docker.sh` prints it).
  Worktrees share the main `o3shop-shop-ce-db-1` MariaDB.
- Demo content is expected even in a "live" shop: the core `initial_data.sql`
  ships a "Demo des O3-Shops" footer, and demodata adds the demo products/home
  text. Productive mode is about assets, not content.
- On the dev-stream build, `./docker.sh stream done [name]` stops the stack,
  removes the worktrees, and drops merged branches; `./docker.sh theme prod`
  rebuilds minified theme assets.
