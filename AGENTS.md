# boxen

- Secrets live in `host_vars/*.sops.yml`. Never read `.envrc`; it loads secrets.
- Run playbooks with `--limit <host>`. The shared ones in `playbooks/` target
  only the limited hosts and match nothing without it.
- Don't run ad-hoc commands against hosts. Ask for the fact instead.
- Keep evergreen documentation, meaning how things work now, in `docs/`.
  Update it in the same change that makes it stale. Dated write-ups go in
  `docs/<host>/YYYY-MM-DD-slug.md`.
- Commit scope is the directory the change lives in (`lotus-land-story:`).
