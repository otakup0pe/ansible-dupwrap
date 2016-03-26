[![Maintenance](https://img.shields.io/maintenance/yes/2016.svg)]()

`dup`licity `wrap`per
--------------------

This Ansible role installs a simple wrapper around the [duplicity](http://duplicity.nongnu.org/) backup tool. It has two high-level modes - backing up to Amazon S3, or an encrypted Mac disk image on an external Volume. It is meant to be installed into a prefixed location, so conceptually you could have multiple instances of `dupwrap` installed on a system. The defaults all lean towards a S3 backup as the `root` user.

### S3 Mode

This will upload the GPG encrypted backup to a specified S3 bucket. The IAM user needs read/write permissions.

### Mac USB Mode

This will create/maintain a encrypted volume on external volumes. This does result in a double encryption but I don't really mind. This mode does _not_ yet support Cron.

### Variables

These are variables which have defaults.

* `dupwrap_user` defaults to `root`
* `dupwrap_group` defaults to `root`
* `dupwrap_config_prefix` defaults to `/etc`
* `dupwrap_bin_prefix` defaults to `/usr/local/bin`
* `dupwrap_cron` defaults to `false` - enable to setup a cronjob using the following settings
* `dupwrap_n_full` defaults to `3` and controls how many full backups to keep
* `dupwrap_remove_older` defaults to `12` will remove backups older than the specified number of months

These are instance variables and must always be passed.

* `dupwrap_passphrase` specifies the password to perform symmetric gpg encryption with
* `dupwrap_destination` should be set to either `s3` or `mac_usb`
* `dupwrap_directories` is a list of directories to backup

You must pass these instance variables if backing up to S3.

* `dupwrap_aws_access_key` is your AWS Access Key ID
* `dupwrap_aws_secret_key` is your AWS Secret Access Key
* `dupwrap_bucket` is the S3 URI to use

You must pass these instance variables if backing up to Mac/USB

* `dupwrap_unencrypted_volume` is the name of the mounted external volume to use
* `dupwrap_encrypted_volume` is the name of the encrypted volume to make

### `dupwrap` script

This script is the interface around `duplicity`. It is also what gets called by `cron`, if using that. All mac/usb interactions will ask for a password.

* `init` only available on osx, will ensure the encrypted volume exists
* `backup` will kick off a backup
* `list` lists everything in the most recent backup
* `restore` will restore a specific file to the given location
** `restore <file> <dest>` to restore most recent
** `restore <file> <dest> <time>` to restore from a specified time
* `status` basic information on the backup set
* `prune` will remove old backups

# License

[MIT](https://github.com/otakup0pe/ansible-dupwrap/blob/master/LICENSE)

# Author

This Ansible role was created by [Jonathan Freedman](http://jonathanfreedman.bio/) because he was tired of losing things to the inexorable decay of data.
