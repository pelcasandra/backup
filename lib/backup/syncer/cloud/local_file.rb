require "digest/md5"

module Backup
  module Syncer
    module Cloud
      class LocalFile
        attr_reader :path, :relative_path
        attr_accessor :md5

        class << self
          # Returns a Hash of LocalFile objects for each file within +dir+,
          # except those matching any of the +excludes+.
          # Hash keys are the file's path relative to +dir+.
          def find(dir, excludes = [])
            dir = File.expand_path(dir)
            hash = {}
            find_md5(dir, excludes).each do |file|
              relative_path = file.relative_path || file.path.sub("#{dir}/", "")
              hash[relative_path] = file
            end
            hash
          end

          # Return a new LocalFile object if it's valid.
          # Otherwise, log a warning and return nil.
          def new(*args)
            file = super
            if file.invalid?
              Logger.warn("\s\s[skipping] #{file.path}\n" \
                          "\s\sPath Contains Invalid UTF-8 byte sequences")
              file = nil
            end
            file
          end

          private

          # Returns an Array of file paths and their md5 hashes.
          def find_md5(dir, excludes)
            root = File.realpath(dir)
            find_md5_within(dir, excludes, root, dir)
          end

          def find_md5_within(dir, excludes, root, logical_root, ancestors = [])
            safe_dir = Path.realpath_within(root, dir, "Sync Source Path")
            return [] if ancestors.include?(safe_dir)

            ancestors += [safe_dir]
            found = []
            (Dir.entries(dir) - %w[. ..]).map { |e| File.join(dir, e) }.each do |path|
              if File.directory?(path)
                unless exclude?(excludes, path)
                  found += find_md5_within(
                    path, excludes, root, logical_root, ancestors
                  )
                end
              elsif File.file?(path) && !exclude?(excludes, path)
                source_path = Path.realpath_within(
                  root, path, "Sync Source Path"
                )
                relative_path = path.sub("#{logical_root}/", "")
                if file = new(source_path, relative_path)
                  file.md5 = Digest::MD5.file(file.path).hexdigest
                  found << file
                end
              end
            end
            found
          end

          # Returns true if +path+ matches any of the +excludes+.
          # Note this can not be called if +path+ includes invalid UTF-8.
          def exclude?(excludes, path)
            excludes.any? do |ex|
              if ex.is_a?(String)
                File.fnmatch?(ex, path)
              elsif ex.is_a?(Regexp)
                ex.match(path)
              end
            end
          end
        end

        # If +path+ contains invalid UTF-8, it will be sanitized
        # and the LocalFile object will be flagged as invalid.
        # This is done so @file.path may be logged.
        def initialize(path, relative_path = nil)
          @path = sanitize(path)
          @relative_path = relative_path
        end

        def invalid?
          !!@invalid
        end

        private

        def sanitize(str)
          str.each_char.map do |char|
            begin
              char.unpack("U")
              char
            rescue
              @invalid = true
              "\xEF\xBF\xBD" # => "\uFFFD"
            end
          end.join
        end
      end
    end
  end
end
