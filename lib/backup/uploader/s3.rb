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
          parts.map! { Path.component(it, 'Object Key Component') }
          File.join(parts)
        end
    end
  end
end
