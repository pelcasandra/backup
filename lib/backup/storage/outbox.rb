require 'digest'

module Backup
  module Storage
    class Outbox < Base
      class Error < Backup::Error; end
      class IntegrityError < Error; end

      SIDECAR_SUFFIX = '.sha256'
      SIDECAR_PATTERN = %r{\A([0-9a-f]{64})  ([^/\r\n]+)\r?\n?\z}

      attr_accessor :retention
      attr_reader :uploader

      def initialize(model, storage_id = nil, &block)
        super(model, storage_id, &block)

        @path ||= '~/backups'
        validate_configuration!
      end

      def upload_with(name, uploader_id = nil, &block)
        raise Error, 'Only one uploader may be configured for an outbox' if @uploader

        @uploader = uploader_class(name).new(model, uploader_id, &block)
      end

      def retry_upload!(time)
        time = Path.component(time, 'Package Time')
        artifacts = artifacts_for(time)
        artifacts.each(&:verify!)
        artifacts.each { upload_artifact(it, time) }
        Logger.info "Upload-only retry completed for #{package.trigger}/#{time}"
        true
      end

      def cleanup!(now: Time.now.utc)
        unless retention
          Logger.info "Local cleanup is disabled for #{package.trigger}; no retention is configured"
          return []
        end

        cutoff = now - retention
        removed = cleanup_outbox(cutoff)
        removed.concat(cleanup_temporary(cutoff))
        Logger.info "Local cleanup removed #{removed.length} path(s) for #{package.trigger}"
        removed
      end

      private
        def transfer!
          time = Path.component(package.time, 'Package Time')
          persist!(time)
          retry_upload!(time)
        end

        def persist!(time)
          sources = package.filenames.map do |filename|
            filename = Path.component(filename, 'Package Filename')
            File.join(Config.tmp_path, filename)
          end
          missing = sources.reject { File.file?(it) && !File.zero?(it) }
          raise Error, "Package files are missing or empty: #{missing.join(', ')}" unless missing.empty?

          directory = local_directory(time)
          raise Error, "Outbox package already exists: #{directory}" if File.exist?(directory)

          FileUtils.mkdir_p(directory)
          transfer_method = package_movable? ? :mv : :cp
          sources.each do |source|
            destination = File.join(directory, File.basename(source))
            Logger.info "Persisting '#{destination}'..."
            FileUtils.public_send(transfer_method, source, destination)
            write_sidecar(destination)
          end
        end

        def write_sidecar(source)
          digest = Digest::SHA256.file(source).hexdigest
          File.open("#{source}#{SIDECAR_SUFFIX}", 'w') do |file|
            file.write("#{digest}  #{File.basename(source)}\n")
          end
        end

        def artifacts_for(time)
          directory = existing_local_directory(time)
          entries = Dir.children(directory).reject { it.start_with?('.') }
          sources = entries.reject { it.end_with?(SIDECAR_SUFFIX) }.sort
          sidecars = entries.select { it.end_with?(SIDECAR_SUFFIX) }.sort
          expected_sidecars = sources.map { "#{it}#{SIDECAR_SUFFIX}" }

          if sources.empty? || sidecars != expected_sidecars
            raise IntegrityError,
                  "Expected one SHA-256 sidecar per package file in #{directory}"
          end

          sources.map { Artifact.new(directory, it) }
        end

        def upload_artifact(artifact, time)
          [artifact.source, artifact.sidecar].each do |source|
            destination = File.join(package.trigger, time, File.basename(source))
            uploader.upload(source, destination)
          end
        end

        def local_directory(time)
          File.expand_path(File.join(path, package.trigger, time))
        end

        def existing_local_directory(time)
          root = File.expand_path(File.join(path, package.trigger))
          directory = local_directory(time)
          raise Error, "Outbox package not found: #{directory}" unless
            File.directory?(root) && File.directory?(directory)

          Path.realpath_within(root, directory, 'Outbox Package Path')
        end

        def cleanup_outbox(cutoff)
          root = File.expand_path(File.join(path, package.trigger))
          return [] unless File.directory?(root)

          real_root = File.realpath(root)
          Dir.children(root).sort.filter_map do |entry|
            candidate = File.join(root, entry)
            next unless removable_directory?(real_root, candidate)
            next unless outbox_mtime(candidate) < cutoff

            FileUtils.rm_r(candidate)
            Logger.info "Removed expired outbox package: #{candidate}"
            candidate
          end
        end

        def cleanup_temporary(cutoff)
          removed = []
          trigger = Path.component(package.trigger, 'Model Trigger')
          directory = File.join(Config.tmp_path, trigger)
          if plain_path?(directory, :directory?) && File.mtime(directory) < cutoff
            FileUtils.rm_r(directory)
            removed << directory
          end

          pattern = File.join(Config.tmp_path, "#{trigger}.tar{,[.-]*}")
          Dir[pattern].sort.each do |candidate|
            next unless plain_path?(candidate, :file?) && File.mtime(candidate) < cutoff

            FileUtils.rm_f(candidate)
            removed << candidate
          end
          removed
        end

        def removable_directory?(root, candidate)
          status = File.lstat(candidate)
          status.directory? && !status.symlink? && File.dirname(File.realpath(candidate)) == root
        rescue Errno::ENOENT
          false
        end

        def plain_path?(candidate, type)
          status = File.lstat(candidate)
          !status.symlink? && status.public_send(type)
        rescue Errno::ENOENT
          false
        end

        def outbox_mtime(directory)
          sources = Dir.children(directory).filter_map do |entry|
            next if entry.start_with?('.') || entry.end_with?(SIDECAR_SUFFIX)

            candidate = File.join(directory, entry)
            File.mtime(candidate) if plain_path?(candidate, :file?)
          end
          sources.empty? ? File.mtime(directory) : sources.max
        end

        def package_movable?
          return true if self == model.storages.last

          Logger.warn Error.new(<<-MESSAGE)
            Outbox File Copy Warning!
            The final backup file(s) for '#{model.label}' (#{model.trigger})
            will be copied to '#{local_directory(package.time)}'.
            Add the Outbox storage last to move the package instead.
          MESSAGE
          false
        end

        def uploader_class(name)
          return name if name.is_a?(Class)

          klass = Uploader
          name.to_s.sub(/^Backup::Config::DSL::/, '').split('::').each do |part|
            klass = klass.const_get(part)
          end
          klass
        rescue NameError
          raise Error, "Unknown outbox uploader: #{name}"
        end

        def validate_configuration!
          raise Error, 'An outbox uploader must be configured with #upload_with' unless uploader

          return if retention.nil? || retention.is_a?(Integer) && retention.positive?

          raise Error, '#retention must be a positive number of seconds or nil'
        end

      class Artifact
        attr_reader :source, :sidecar

        def initialize(directory, filename)
          @source = plain_file(File.join(directory, filename))
          @sidecar = plain_file("#{@source}#{SIDECAR_SUFFIX}")
        end

        def verify!
          match = SIDECAR_PATTERN.match(File.read(sidecar))
          raise IntegrityError, "Invalid SHA-256 sidecar: #{sidecar}" unless
            match && match[2] == File.basename(source)

          actual = Digest::SHA256.file(source).hexdigest
          return true if actual == match[1]

          raise IntegrityError,
                "SHA-256 mismatch for #{source}: expected #{match[1]}, got #{actual}"
        end

        private
          def plain_file(path)
            status = File.lstat(path)
            return path if status.file? && !status.symlink?

            raise IntegrityError, "Expected a regular file: #{path}"
          rescue Errno::ENOENT
            raise IntegrityError, "Expected a regular file: #{path}"
          end
      end
    end
  end
end
