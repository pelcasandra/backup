require 'backup/storage/s3'

module Backup
  module Uploader
    class S3 < Storage::S3
      def upload(source, destination)
        key = remote_key(destination)
        Logger.info "Uploading '#{source}' to '#{bucket}/#{key}'..."
        cloud_io.upload(source, key)
        key
      end

      private
        def remote_key(destination)
          parts = [path, destination].reject { it.to_s.empty? }
            .flat_map { it.to_s.split('/') }
          Path.join_components(*parts, label: 'Object Key Component')
        end
    end
  end
end
