require 'spec_helper'

module Backup
  describe Uploader::S3 do
    let(:model) { Model.new(:test_trigger, 'test label') }
    let(:cloud_io) { double('cloud io', upload: nil) }
    let(:uploader) do
      described_class.new(model) do |s3|
        s3.access_key_id = 'access-key'
        s3.secret_access_key = 'secret-key'
        s3.bucket = 'bucket-name'
        s3.path = 'backups'
      end
    end

    before { allow(uploader).to receive(:cloud_io).and_return(cloud_io) }

    describe '#upload' do
      it 'uploads to the configured prefix and returns the object key' do
        expect(cloud_io).to receive(:upload).with(
          '/local/package.tar',
          'backups/test_trigger/2026.08.06.12.00.00/package.tar'
        )

        expect(
          uploader.upload(
            '/local/package.tar',
            'test_trigger/2026.08.06.12.00.00/package.tar'
          )
        ).to eq('backups/test_trigger/2026.08.06.12.00.00/package.tar')
      end

      it 'rejects object key traversal before calling the transport' do
        expect(cloud_io).not_to receive(:upload)

        expect do
          uploader.upload('/local/package.tar', '../outside/package.tar')
        end.to raise_error(Path::Error, /Invalid Object Key Component/)
      end

      it 'rejects traversal in the configured prefix before calling the transport' do
        uploader.path = '../outside'
        expect(cloud_io).not_to receive(:upload)

        expect do
          uploader.upload('/local/package.tar', 'application/package.tar')
        end.to raise_error(Path::Error, /Invalid Object Key Component/)
      end

      it 'sends Standard storage headers for S3-compatible providers' do
        cloud_io = CloudIO::S3.new(storage_class: :standard)

        expect(cloud_io.send(:headers)).to eq(
          'x-amz-storage-class' => 'STANDARD'
        )
      end
    end
  end
end
