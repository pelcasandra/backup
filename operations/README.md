# Production backup operations

This directory provides a project-agnostic installation for Backup models that
use the durable `Outbox` storage. Application-specific databases, archive
paths, destinations, and credentials belong on the host in the normal Backup
configuration, not in an application repository or a second configuration
format.

## Model configuration

Install the main configuration as `/etc/backup/config.rb` and one model per
application under `/etc/backup/models/`. The complete generic example is in
[`examples/model.rb`](examples/model.rb). A model composes the existing
database and archive components with the outbox in one DSL:

```ruby
Model.new(:application, 'Application production') do
  database PostgreSQL do |database|
    database.name = 'application_production'
    database.sudo_user = 'postgres'
  end

  database Redis do |database|
    database.mode = :copy
    database.rdb_path = '/var/lib/redis/dump.rdb'
  end

  archive :host_files do |archive|
    archive.add '/srv/application/uploads'
    archive.add '/etc/application'
  end

  compress_with Gzip

  store_with Outbox do |outbox|
    outbox.path = '/var/backups/application/outbox'
    outbox.retention = 86_400

    outbox.upload_with S3 do |s3|
      s3.access_key_id = ENV.fetch('R2_ACCESS_KEY_ID')
      s3.secret_access_key = ENV.fetch('R2_SECRET_ACCESS_KEY')
      s3.bucket = 'application-backups'
      s3.path = 'backups'
      s3.region = 'auto'
      s3.storage_class = :standard
      s3.chunk_size = 64
      s3.max_retries = 5
      s3.retry_waitsec = 30
      s3.fog_options = {
        endpoint: 'https://ACCOUNT_ID.r2.cloudflarestorage.com',
        path_style: true,
        aws_signature_version: 4
      }
    end
  end
end
```

Configure `Outbox` last when a model has multiple storages. It can then move
the package into durable storage before uploading it. If it is not last, it
copies the package and emits a warning so later storages can still read the
temporary source.

## Data and failure behavior

The normal model pipeline collects each configured database and archive once,
then creates the final package once. The outbox moves or copies every final
package file to:

```text
OUTBOX_PATH/TRIGGER/YYYY.MM.DD.HH.MM.SS/PACKAGE
OUTBOX_PATH/TRIGGER/YYYY.MM.DD.HH.MM.SS/PACKAGE.sha256
```

It writes a standard SHA-256 sidecar for each package file and verifies all
sidecars before making any upload request. The package and sidecar are uploaded
as separate objects. Neither is deleted after a successful or failed upload,
so operators can download them directly from the production host until local
retention expires.

The S3-compatible uploader uses the existing retry and multipart transport.
`chunk_size` selects multipart uploads in MiB, `max_retries` and
`retry_waitsec` control retry behavior, and `storage_class = :standard` sends
`x-amz-storage-class: STANDARD` for both single and multipart initiation
requests. Exhausted retries raise through the model, producing Backup exit
status 2 and a failed systemd oneshot.

An upload-only retry reloads the same model and never runs a database or
archive component:

```sh
backup outbox:upload \
  --trigger application \
  --time 2026.08.06.03.15.00 \
  --config-file /etc/backup/config.rb
```

The command verifies every local checksum before uploading. An optional
`--storage ID` selects one outbox when the model defines more than one.

Independent cleanup reloads the model and removes expired outbox directories,
the model's stale packaging directory, and stale package files from
`Config.tmp_path`:

```sh
backup outbox:cleanup \
  --trigger application \
  --config-file /etc/backup/config.rb
```

Cleanup is disabled when `outbox.retention` is `nil`. Run backup, retry, and
cleanup commands under the same per-trigger lock so cleanup cannot overlap an
active collection or upload.

## Installation and systemd

Review the checkout, use an immutable reviewed revision, and run
`sudo operations/install`. The installer:

- refuses a dirty source checkout;
- builds and installs the gem below `/opt/pelcasandra-backup`;
- records the exact source URL, Git revision, and gem version;
- installs generic instance units and documentation;
- creates `/etc/backup/config.rb` only when it does not exist;
- reloads systemd without enabling or starting anything.

It does not create a model, project directory, schedule, or credentials. Copy
and edit the model example on the host, create its outbox directory with
restricted permissions, and put credentials in `/etc/backup/TRIGGER.env` with
mode `0600` and root ownership.

Validate the configuration without collecting or uploading data:

```sh
sudo systemd-run --pipe --wait \
  --property=EnvironmentFile=/opt/pelcasandra-backup/install.env \
  --property=EnvironmentFile=/etc/backup/application.env \
  /usr/local/libexec/pelcasandra-backup/backup check \
  --config-file /etc/backup/config.rb
```

Run one end-to-end backup and inspect its result before enabling timers:

```sh
sudo systemctl start pelcasandra-backup@application.service
sudo systemctl status pelcasandra-backup@application.service
sudo journalctl -u pelcasandra-backup@application.service --since today
```

The backup timer runs daily around 03:15 UTC with jitter. The cleanup timer
runs hourly and remains active even if the backup timer is disabled or backup
jobs repeatedly fail:

```sh
sudo systemctl enable --now pelcasandra-backup@application.timer
sudo systemctl enable --now pelcasandra-backup-cleanup@application.timer
systemctl list-timers 'pelcasandra-backup*@application*'
```

To retry one finalized package with the same lock and host environment:

```sh
sudo systemd-run --pipe --wait \
  --unit=pelcasandra-backup-upload-application \
  --property=EnvironmentFile=/opt/pelcasandra-backup/install.env \
  --property=EnvironmentFile=/etc/backup/application.env \
  /usr/bin/flock --nonblock /run/lock/pelcasandra-backup-application.lock \
  /usr/local/libexec/pelcasandra-backup/backup outbox:upload \
  --trigger application \
  --time 2026.08.06.03.15.00 \
  --config-file /etc/backup/config.rb
```

## Direct download and restore checks

Download both files before local retention expires, then verify the sidecar:

```sh
scp root@HOST:/var/backups/application/outbox/application/TIME/application.tar .
scp root@HOST:/var/backups/application/outbox/application/TIME/application.tar.sha256 .
sha256sum --check application.tar.sha256
```

Restore into an isolated host or temporary directory first. Inspect the tar
listing, validate database payloads with their native tools, and review file
ownership and modes before writing anything over production.

## Cloudflare R2 lifecycle

The installer and library do not modify bucket lifecycle rules. After upload
and restore testing, an authorized Cloudflare administrator can add a
seven-day expiration rule scoped to the configured prefix. Review the exact
bucket and prefix before running an equivalent command:

```sh
npx wrangler r2 bucket lifecycle add BUCKET_NAME \
  expire-backups-after-seven-days backups/ --expire-days 7
```

The host credential should have only Object Read & Write access to its bucket;
it should not have lifecycle administration permission. Confirm the resulting
rule in Cloudflare after it is applied. No lifecycle command is run by this
repository.

## Source verification

Before production installation, record and review the actual engine source:

```sh
git remote get-url origin
git rev-parse HEAD
ruby -Ilib -rbackup/version -e 'puts Backup::VERSION'
git status --short
```
