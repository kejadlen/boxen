# boxen

- Secrets live in `host_vars/*.sops.yml`. Never read `.envrc`; it loads secrets.
- Run playbooks with `--limit <host>`. The shared ones in `playbooks/` target
  only the limited hosts and match nothing without it.
- Deploying changes — running playbooks, applying tofu — is human-only.
  Prepare the change, then hand it off.
- Don't run ad-hoc commands against hosts. Ask for the fact instead.
- Keep evergreen documentation, meaning how things work now, in `docs/`.
  Update it in the same change that makes it stale. Prefer living documents
  over dated write-ups; `docs/<host>/YYYY-MM-DD-slug.md` is for when the
  history itself matters, like a one-time migration record.
- ranger's `boxen` backlog is the near-term work queue, not a record of
  every TODO. Add a task when the work is ready to implement. When work
  lands or a plan changes, update the affected tasks' state, order, and
  descriptions along with the docs, so that neither drifts.
- Commit scope is the directory the change lives in (`lotus-land-story:`).
