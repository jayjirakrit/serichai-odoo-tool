# serichai-odoo-tool

Ops scripts for the Serichai Odoo 19.0 deployment.

| Script | Purpose |
|---|---|
| `setup/setup_vm.sh` | Bootstrap a fresh Ubuntu 24.04 VM (packages, PostgreSQL 16, venv, Odoo + Serichai + OCA repos, optional nginx/systemd). Re-runnable. |
| `run/run_odoo.sh` | Start Odoo from the vendored `odoo/` tree and project `.venv`. Extra args pass through to `odoo-bin`. |
| `backup/backup_odoo.sh` | Full backup: DB + filestore zip, addons tarball, pip freeze, checksums. |
| `backup/restore_odoo.sh` | Restore a backup (`--force`, `--neutralize`, `--addons`). |

Scripts locate the install via `BASE_PATH` (default `/home/odoo/serichai-odoo`), not their own location.
