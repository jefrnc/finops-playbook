# Tools

Runnable utilities that complement the playbook. Organized by cloud provider —
each folder is self-contained (own `lib/`, `config/`, `output/`, README).

| Provider | Folder | Status |
|---|---|---|
| Azure | [`azure/`](./azure) | Available — 5 scripts (drift, waste, tag compliance, cost-by-tag, monthly orchestrator) |
| AWS | `aws/` | Not yet — contributions welcome |
| GCP | `gcp/` | Not yet — contributions welcome |

## Contributing a new provider folder

Keep each provider's toolkit independent so it can be adopted without pulling
in the others. Minimum structure:

```
tools/<provider>/
  README.md                 # what it does, requirements, usage
  lib/common.sh             # shared helpers (logging, config, output paths)
  config/example.env        # template profile, no real data
  config/.gitignore         # ignore *.env, keep example.env
  output/.gitkeep           # reports land here, gitignored
  <provider>-*.sh           # actual scripts
```

Design principles (copied from the Azure toolkit — recommended for new ones):

- **Read-only.** Query the cloud, write CSV + Markdown. Do not mutate.
- **Local state only.** Baselines live next to reports in `output/`. No DB,
  no remote storage.
- **Profile-based config.** Clients / environments live in `config/<name>.env`,
  gitignored. Scripts load them via `FINOPS_PROFILE=<name>`.
- **Portable bash.** Target Bash 3.2 (macOS default), force `LC_ALL=C` for
  locale-safe decimal formatting.
