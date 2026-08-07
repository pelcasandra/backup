require 'spec_helper'

module Backup
  module Uploader
    class Spec
      attr_accessor :failure
      attr_reader :model, :uploader_id, :uploads

      def initialize(model, uploader_id = nil)
        @model = model
        @uploader_id = uploader_id
        @uploads = []
        yield self if block_given?
      end

      def upload(source, destination)
        @uploads << [source, destination]
        raise failure if failure

        destination
      end
    end
  end

  describe Storage::Outbox do
    before do
      Model.send(:reset!)
      @sandbox = Dir.mktmpdir('backup-outbox-spec')
      @temporary_path = File.join(@sandbox, 'tmp')
      @outbox_path = File.join(@sandbox, 'outbox')
      SandboxFileUtils.activate!(@sandbox)
      FileUtils.mkdir_p(@temporary_path)
      allow(Config).to receive(:tmp_path).and_return(@temporary_path)
    end

    after do
      Model.send(:reset!)
      SandboxFileUtils.deactivate!
      FileUtils.rm_rf(@sandbox)
    end

    describe '#initialize' do
      it 'configures persistence, retention, and its uploader in the model' do
        storage = build_storage(storage_id: :primary)

        expect(storage.path).to eq(@outbox_path)
        expect(storage.retention).to eq(86_400)
        expect(storage.storage_id).to eq('primary')
        expect(storage.uploader).to be_a(Uploader::Spec)
        expect(storage.uploader.uploader_id).to eq(:remote)
      end

      it 'requires exactly one uploader and valid retention' do
        model = Model.new(:test_trigger, 'test label')

        expect do
          described_class.new(model) { it.path = @outbox_path }
        end.to raise_error(described_class::Error, /uploader must be configured/)

        expect do
          described_class.new(model) do |outbox|
            outbox.retention = 0
            outbox.upload_with Uploader::Spec
          end
        end.to raise_error(described_class::Error, /positive number of seconds/)
      end
    end

    describe '#perform!' do
      it 'persists split package files and uploads every checksum separately' do
        storage = build_storage
        write_packages(storage, suffixes: %w[aa ab])

        storage.perform!

        directory = stored_directory
        expected = %w[
          test_trigger.tar-aa
          test_trigger.tar-aa.sha256
          test_trigger.tar-ab
          test_trigger.tar-ab.sha256
        ]
        expect(Dir.children(directory).sort).to eq(expected.sort)
        expect(storage.uploader.uploads.map { File.basename(it.first) }).to eq(expected)
        expect(storage.uploader.uploads.map(&:last)).to eq(
          expected.map { File.join('test_trigger', timestamp, it) }
        )
        expect(Dir.children(@temporary_path)).to be_empty
        expected.grep_v(/sha256\z/).each do |filename|
          expect(valid_checksum?(directory, filename)).to be(true)
        end
      end

      it 'preserves the local package and checksum when upload fails' do
        storage = build_storage(failure: RuntimeError.new('remote unavailable'))
        write_packages(storage)

        expect { storage.perform! }.to raise_error(RuntimeError, 'remote unavailable')
        expect(Dir.children(stored_directory).sort).to eq(
          %w[test_trigger.tar test_trigger.tar.sha256]
        )
        expect(valid_checksum?(stored_directory, 'test_trigger.tar')).to be(true)
      end

      it 'rejects a symlinked temporary package before persistence' do
        storage = build_storage
        outside = File.join(@sandbox, 'outside.tar')
        source = File.join(@temporary_path, storage.package.filenames.first)
        File.write(outside, 'sensitive data')
        File.symlink(outside, source)

        expect do
          storage.perform!
        end.to raise_error(described_class::Error, /files are missing or empty/)
        expect(File.read(outside)).to eq('sensitive data')
        expect(File.exist?(stored_directory)).to be(false)
        expect(storage.uploader.uploads).to be_empty
      end

      it 'sets the model failure status after preserving a failed upload' do
        storage = build_storage(failure: RuntimeError.new('remote unavailable'))
        write_packages(storage)
        allow(storage.model).to receive(:procedures).and_return([-> { storage.perform! }])
        Timecop.freeze(Time.utc(2026, 8, 6, 12))

        storage.model.perform!

        expect(storage.model.exit_status).to eq(2)
        expect(storage.model.exception.message).to eq('remote unavailable')
        expect(File.directory?(stored_directory)).to be(true)
      ensure
        Timecop.return
      end
    end

    describe '#retry_upload!' do
      it 'uploads existing files again without recreating the package' do
        storage = build_storage
        write_packages(storage)
        storage.perform!
        original_mtime = File.mtime(File.join(stored_directory, 'test_trigger.tar'))
        storage.uploader.uploads.clear

        storage.retry_upload!(timestamp)

        expect(storage.uploader.uploads.map { File.basename(it.first) }).to eq(
          %w[test_trigger.tar test_trigger.tar.sha256]
        )
        expect(File.mtime(File.join(stored_directory, 'test_trigger.tar'))).to eq(original_mtime)
      end

      it 'rejects corruption before any upload begins' do
        storage = build_storage
        write_packages(storage)
        storage.perform!
        storage.uploader.uploads.clear
        File.write(File.join(stored_directory, 'test_trigger.tar'), 'tampered')

        expect do
          storage.retry_upload!(timestamp)
        end.to raise_error(described_class::IntegrityError, /SHA-256 mismatch/)
        expect(storage.uploader.uploads).to be_empty
      end

      it 'rejects a timestamp that could escape the model outbox' do
        storage = build_storage

        expect do
          storage.retry_upload!('../outside')
        end.to raise_error(Path::Error, /Invalid Package Time/)
        expect(storage.uploader.uploads).to be_empty
      end

      it 'rejects an untrusted artifact name before upload' do
        storage = build_storage
        FileUtils.mkdir_p(stored_directory)
        source = File.join(stored_directory, 'forged..tar')
        File.write(source, 'forged data')
        write_checksum(source)

        expect do
          storage.retry_upload!(timestamp)
        end.to raise_error(Path::Error, /Invalid Outbox Package File/)
        expect(storage.uploader.uploads).to be_empty
      end

      it 'rejects a symlinked package directory before upload' do
        storage = build_storage
        outside = File.join(@sandbox, 'outside-package')
        FileUtils.mkdir_p(File.dirname(stored_directory))
        FileUtils.mkdir_p(outside)
        File.symlink(outside, stored_directory)

        expect do
          storage.retry_upload!(timestamp)
        end.to raise_error(described_class::Error, /Outbox package not found/)
        expect(storage.uploader.uploads).to be_empty
      end
    end

    describe '#cleanup!' do
      it 'removes expired outbox and temporary data independently' do
        storage = build_storage
        write_packages(storage)
        storage.perform!
        old_time = Time.utc(2026, 8, 5, 10)
        Dir.children(stored_directory).each do |entry|
          path = File.join(stored_directory, entry)
          File.utime(old_time, old_time, path)
        end

        stale_packaging = File.join(@temporary_path, 'test_trigger')
        stale_package = File.join(@temporary_path, 'test_trigger.tar.failed')
        FileUtils.mkdir_p(stale_packaging)
        File.write(stale_package, 'stale')
        File.utime(old_time, old_time, stale_packaging)
        File.utime(old_time, old_time, stale_package)

        fresh_directory = File.join(@outbox_path, 'test_trigger', '2026.08.06.11.30.00')
        FileUtils.mkdir_p(fresh_directory)
        File.write(File.join(fresh_directory, 'test_trigger.tar'), 'fresh')

        removed = storage.cleanup!(now: Time.utc(2026, 8, 6, 12))

        expect(removed).to contain_exactly(
          stored_directory,
          stale_packaging,
          stale_package
        )
        expect(File.directory?(fresh_directory)).to be(true)
      end

      it 'rejects an untrusted package entry before cleanup' do
        storage = build_storage
        FileUtils.mkdir_p(stored_directory)
        File.write(File.join(stored_directory, 'forged..tar'), 'forged data')

        expect do
          storage.cleanup!(now: Time.utc(2026, 8, 6, 12))
        end.to raise_error(Path::Error, /Invalid Outbox Package File/)
        expect(File.directory?(stored_directory)).to be(true)
      end
    end

    describe 'model configuration' do
      it 'loads the outbox and S3 uploader from the standard model file' do
        config_file = File.join(@sandbox, 'config.rb')
        models_path = File.join(@sandbox, 'models')
        FileUtils.mkdir_p(models_path)
        File.write(config_file, <<~RUBY)
          # Backup v5.x Configuration
          root_path '#{@sandbox}'
        RUBY
        File.write(File.join(models_path, 'application.rb'), <<~RUBY)
          Model.new(:application, 'Application') do
            store_with Outbox do |outbox|
              outbox.path = '#{@outbox_path}'
              outbox.retention = 86_400
              outbox.upload_with S3 do |s3|
                s3.access_key_id = 'access-key'
                s3.secret_access_key = 'secret-key'
                s3.bucket = 'bucket-name'
                s3.region = 'auto'
                s3.path = 'backups'
                s3.chunk_size = 64
                s3.max_retries = 5
                s3.retry_waitsec = 30
                s3.storage_class = :standard
                s3.fog_options = {
                  endpoint: 'https://account.r2.cloudflarestorage.com',
                  path_style: true,
                  aws_signature_version: 4
                }
              end
            end
          end
        RUBY

        Config.load(config_file:)

        model = Model.find_by_trigger('application').first
        expect(model.storages.length).to eq(1)
        expect(model.storages.first).to be_a(described_class)
        expect(model.storages.first.uploader).to be_a(Uploader::S3)
        expect(model.storages.first.uploader.region).to eq('auto')
      end
    end

    private
      def build_storage(storage_id: nil, failure: nil)
        model = Model.new(:test_trigger, 'test label')
        outbox_path = @outbox_path
        storage = described_class.new(model, storage_id) do |outbox|
          outbox.path = outbox_path
          outbox.retention = 86_400
          outbox.upload_with Uploader::Spec, :remote do |uploader|
            uploader.failure = failure
          end
        end
        model.storages << storage
        storage.package.time = timestamp
        storage
      end

      def write_packages(storage, suffixes: [])
        storage.package.chunk_suffixes = suffixes
        storage.package.filenames.each do |filename|
          File.write(File.join(@temporary_path, filename), "data for #{filename}")
        end
      end

      def stored_directory
        File.join(@outbox_path, 'test_trigger', timestamp)
      end

      def timestamp
        '2026.08.06.12.00.00'
      end

      def valid_checksum?(directory, filename)
        source = File.join(directory, filename)
        expected = Digest::SHA256.file(source).hexdigest
        File.read("#{source}.sha256") == "#{expected}  #{filename}\n"
      end

      def write_checksum(source)
        digest = Digest::SHA256.file(source).hexdigest
        File.write("#{source}.sha256", "#{digest}  #{File.basename(source)}\n")
      end
  end
end
