require 'spec_helper'

describe Backup::CLI do
  let(:model) { Backup::Model.new(:application, 'Application') }
  let(:outbox) do
    Backup::Storage::Outbox.new(model, :primary) do |storage|
      storage.path = '/var/backups/application'
      storage.retention = 86_400
      storage.upload_with Backup::Uploader::S3 do |s3|
        s3.access_key_id = 'access-key'
        s3.secret_access_key = 'secret-key'
        s3.bucket = 'bucket-name'
      end
    end
  end

  before do
    @saved_arguments = ARGV.dup
    Backup::Model.send(:reset!)
    model.storages << outbox
    allow(Backup::Config).to receive(:load)
    allow(Backup::Logger).to receive(:start!)
  end

  after do
    ARGV.replace(@saved_arguments)
    Backup::Model.send(:reset!)
  end

  describe '#outbox:upload' do
    it 'loads the normal configuration and retries the selected package' do
      expect(Backup::Config).to receive(:load).with(
        hash_including(config_file: '/etc/backup/config.rb')
      )
      expect(outbox).to receive(:retry_upload!).with('2026.08.06.03.15.00')

      ARGV.replace(
        %w[
          outbox:upload
          --trigger application
          --storage primary
          --time 2026.08.06.03.15.00
          --config-file /etc/backup/config.rb
        ]
      )
      described_class.start
    end

    it 'exits nonzero when the upload-only retry fails' do
      allow(outbox).to receive(:retry_upload!).and_raise('remote unavailable')
      allow(Backup::Logger).to receive(:error)
      expect(Backup::Logger).to receive(:abort!)

      ARGV.replace(
        %w[
          outbox:upload
          --trigger application
          --time 2026.08.06.03.15.00
        ]
      )
      expect { described_class.start }.to raise_error(SystemExit) do |error|
        expect(error.status).to eq(2)
      end
    end
  end

  describe '#outbox:cleanup' do
    it 'runs cleanup without requiring a package time' do
      expect(outbox).to receive(:cleanup!)

      ARGV.replace(%w[outbox:cleanup --trigger application])
      described_class.start
    end
  end
end
