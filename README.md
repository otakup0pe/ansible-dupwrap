[![CI Status](https://img.shields.io/github/actions/workflow/status/otakup0pe/ansible-dupwrap/ci.yml)](https://github.com/otakup0pe/ansible-dupwrap/actions/workflows/ci.yml)
[![Maintenance](https://img.shields.io/maintenance/yes/2026.svg)](https://github.com/otakup0pe/ansible-dupwrap)
[![License](https://img.shields.io/github/license/otakup0pe/ansible-dupwrap)](https://github.com/otakup0pe/ansible-dupwrap/blob/master/LICENSE)

`dup`licity `wrap`per
--------------------

This Ansible role installs a simple wrapper around the [duplicity](http://duplicity.nongnu.org/) backup tool. It supports backing up to Amazon S3, local filesystem paths, or FTP servers. The `dupwrap` tool supports multiple backup profiles on a single host, backup and restore operations, and may be run as either the `root` user to backup servers, or as another user to backup workstations.

## Requirements

[uv](https://docs.astral.sh/uv/) must be installed on the target host. This role uses `uv run` to manage duplicity and its Python dependencies via `pyproject.toml`, eliminating the need for system-level pip or virtualenv management. The author recommends the [ANXS.python](https://github.com/anxs/python) role, but you may use whatever your heart desires to ensure python and uv are available.

## S3 Mode

This will upload the GPG encrypted backup to a specified S3 bucket. The IAM user associated with the provided API keys requires both read/write permissions.

## Local Filesystem Mode

Backs up to a local filesystem path (e.g. USB drive, NFS mount, secondary disk). Uses duplicity's `file://` backend. No credentials required, making it suitable for CI testing and offline/DR scenarios.

## Variables

These are variables which have defaults. These values are selected to make it easy to backup an entire server, just add source and destination.

* `dupwrap_user` defaults to `root`
* `dupwrap_group` defaults to `root`
* `dupwrap_config_prefix` defaults to `/etc`
* `dupwrap_bin_prefix` defaults to `/usr/local/bin` which is sufficient for
* `dupwrap_cron` defaults to `false` - enable to setup a cronjob
* `dupwrap_cron_verbose` defaults to `false` but you can make this thing way more chatty than you could ever possibly really want
* `dupwrap_n_full` defaults to `3` and controls how many full backups to keep
* `dupwrap_remove_older` defaults to `12` will remove backups older than the specified number of months
* `dupwrap_full_older` defaults to `30D` and determines how frequently to force full backups

Multiple backup profiles may be defined. They are all stored in a a directory named `dupwrap` relative to the config prefix. The `dupwrap_backups` variable is used to define backup profiles. This variable contains a list of yaml objects, which may default to global settings.

* `passphrase` (defaulting to `dupwrap_passphrase`) specifies the password use for encryption routines
* `aws_access_key` (defaulting to `dupwrap_aws_access_key`) is the AWS Access Key ID, needed for S3 backups
* `aws_secret_key` (`dupwrap_aws_secret_key`) is the AWS Secret Access Key, needed for S3 backups
* `bucket` (`dupwrap_bucket`) is the S3 URI to use, needed for S3 backups

For local filesystem backups, set destination to `local` and provide:

* `local_path` is the filesystem path to store backups in

## `dupwrap` script

This script is the interface around `duplicity`. It is also what gets called by `cron`, if using that.

### Options

These options change the default behaviour. Note that some actions will require a profile specified.

* `-v` spits out a bunch of debugging information
* `-f` skips confirmation when removing things for ever
* `-c` specifies the directory where configuration files are stored. This defaults to whatever `dupwrap_config_prefix` is set to
* `-p` specifies a backup profile.
* `-t` specifies the time to restore from (duplicity time format)

### Actions

* `backup` will kick off a backup. If no profile specified then every found backup will be run.
* `list` lists everything in the most recent backup
* `restore_file` will restore a specific file to the given location
  * `restore_file <file> <dest>` to restore most recent
* `restore` will restore an entire backup set to a destination
* `status` basic information on the backup set
* `prune` will remove old backups. If no profile is specified then every found backup will be purged.
* `clean` will clean up failed backup sets

### Ansible Restore Tasks

The role includes `tasks/restore.yml` for ansible-driven restores:

```yaml
- include_role:
    name: otakup0pe.dupwrap
    tasks_from: restore
  vars:
    dupwrap_restore: true
    dupwrap_restore_profile: "general"
    # dupwrap_restore_time: "2026-04-20"  # optional point-in-time
    # dupwrap_restore_directories:        # optional subset of profile dirs
    #   - /mnt/things
```

Restore may be human-initiated (gated behind `dupwrap_restore: false`) or semi-automatic in a passive mode. This allows for humans to manually restore things, and for backups to be restored on first-boot when they are missing.

### Passive Auto-Restore Mode

Enable by setting in host or group vars:

```yaml
dupwrap_restore_if_missing: true
dupwrap_restore_profile: "general"
```

When `dupwrap_restore_if_missing` is `true`, the role's normal converge (`tasks/main.yml`) includes `tasks/restore.yml` at the end. For each directory in the profile:

- **Missing directory**: restored from backup.
- **Empty directory** (mount point exists but contains no files, including hidden files): restored from backup. This is the key case for post-mount storage hosts.
- **Directory with content**: skipped. Re-converge after a successful restore is a no-op, and populated directories are never clobbered.
- **Directory not found in archive**: warned, not failed.

Empty-directory detection uses `ansible.builtin.find` with `file_type: any` and `hidden: true`, so dot-files are counted as content.

This mode is distinct from operator-initiated `dupwrap_restore`, which remains explicit (`include_role` with `tasks_from: restore`). Both variables gate the same restore tasks -- the assert requires at least one of them to be true.

## Credential Script

The `cred_script` job variable specifies a script that is **sourced** (not executed) before the backup runs. It is intended for dynamic credential injection — the script should export `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for S3 destinations. Because the script is sourced, exports propagate into the dupwrap process. The script must use `return 1` (not `exit 1`) on failure to avoid killing the parent process.

## Swap Helper

The swap helper script (`dupwrap-swap-helper`) is meant to be used with the `pre_script` and `post_script` job variables. It is invoked with a single argument which is either `pre` or `post`.

## Testing

This role uses [Molecule](https://molecule.readthedocs.io/) with Docker for integration testing across multiple distributions.

```bash
# Install dependencies
make .venv

# Run linters (yamllint, ansible-lint)
make lint

# Run full test suite (all distros)
make test

# Test a specific distro
make test-ubuntu2204
make test-ubuntu2404
make test-debian12
make test-debian13
```

CI runs automatically on push and pull requests via GitHub Actions.

## Note on AI Usage

This project has been developed with AI assistance. Contributions making use of AI generated content are welcome, however they _must_ be human reviewed prior to submission as pull requests, or issues. All contributors must be able to fully explain and defend any AI generated code, documentation, issues, or tests they submit. Contributions making use of AI must have this explicitly declared in the pull request or issue. This also applies to utilization of AI for reviewing of pull requests.


# License

[MIT](https://github.com/otakup0pe/ansible-dupwrap/blob/master/LICENSE)

# Author

This Ansible role was created by [Jonathan Freedman](http://jonathanfreedman.bio/) because he was tired of losing things to the inexorable decay of data.
