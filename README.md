![Maintenance](https://img.shields.io/maintenance/yes/2017.svg)

`dup`licity `wrap`per
--------------------

This Ansible role installs a simple wrapper around the [duplicity](http://duplicity.nongnu.org/) backup tool. It has two modes of operation - backing up to Amazon S3, or an encrypted Mac disk image on an external Volume. The `dupwrap` tool supports multiple backup profiles on a single host. It may be run as either the `root` user to backup servers, or as another user to backup workstations.

## S3 Mode

This will upload the GPG encrypted backup to a specified S3 bucket. The IAM user associated with the provided API keys requires both read/write permissions.

## Mac USB Mode

This will create/maintain a encrypted volume on external volumes. This does result in a double encryption but I don't really mind. This mode does _not_ yet support scheduled backups.

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

You must pass these instance variables if backing up to Mac/USB

* `dupwrap_unencrypted_volume` is the name of the mounted external volume to use
* `dupwrap_encrypted_volume` is the name of the encrypted volume to make
* `dupwrap_encrypted_volume_size` is the size of the volume, and defaults to `256m`

## `dupwrap` script

This script is the interface around `duplicity`. It is also what gets called by `cron`, if using that. All mac/usb interactions will ask for a password.

### Options

These options change the default behaviour. Note that some actions will require a profile specified.

* `-d` when specified on a mac backup will cause it to leave things mounted when done backing up.
* `-v` spits out a bunch of debugging information
* `-f` skips confirmation when removing things for ever
* `-c` specifies the directory where configuration files are stored. This defaults to whatever `dupwrap_config_prefix` is set to
* `-p` specifies a backup profile.
* `-t` Specifieds the time to restore a file from. I have no idea why this is an option and not an action argument. Probably because I'm terrible at computers.

### Actions

* `backup` will kick off a backup. If no profile specified then every found backup will be run.
* `list` lists everything in the most recent backup
* `restore_file` will restore a specific file to the given location
  * `restore_file <file> <dest>` to restore most recent
* `status` basic information on the backup set
* `prune` will remove old backups. If no profile is specified then every found backup will be purged.

On macOS, there are some additional actions available.

* `init` will create the encrypted disk image
* `purge` will remove the encrypted disk image
* `mount` will mount the encrypted disk image
* `unmount` will unmount the encrypted disk image

## Swap Helper

The swap helper script (`dupwrap-swap-helper`) is meant to be used with the `pre_script` and `post_script` job variables. It is invoked with a single argument which is either `pre` or `post`.

# License

[MIT](https://github.com/otakup0pe/ansible-dupwrap/blob/master/LICENSE)

# Author

This Ansible role was created by [Jonathan Freedman](http://jonathanfreedman.bio/) because he was tired of losing things to the inexorable decay of data.
