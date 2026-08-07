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
