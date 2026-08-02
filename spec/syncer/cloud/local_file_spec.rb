require "spec_helper"

module Backup
  describe Syncer::Cloud::LocalFile do
    describe ".find" do
      before do
        @tmpdir = Dir.mktmpdir("backup_spec")
        SandboxFileUtils.activate!(@tmpdir)
        FileUtils.mkdir_p File.join(@tmpdir, "sync_dir/sub_dir")
        allow(Utilities).to receive(:utility).and_call_original
      end

      after do
        FileUtils.rm_r(@tmpdir, force: true, secure: true)
      end

      it "returns an empty hash if no files are found" do
        expect(described_class.find(@tmpdir)).to eq({})
      end

      context "with test files" do
        let(:test_files) do
          { "sync_dir/one.file"           => "c9f90c31589526ef50cc974a614038d5",
            "sync_dir/two.file"           => "1d26903171cef8b1d7eb035ca049f492",
            "sync_dir/sub_dir/three.file" => "4ccdba38597e718ed00e3344dc78b6a1",
            "base_dir.file"               => "a6cfa67bfa0e16402b76d4560c0baa3d" }
        end
        before do
          test_files.each_key do |path|
            File.open(File.join(@tmpdir, path), "w") { |file| file.write path }
          end
        end

        # This fails on OSX, see https://github.com/backup/backup/issues/482
        # for more information.
        it "returns a Hash of LocalFile objects, keyed by relative path", skip: RUBY_PLATFORM =~ /darwin/ do
          Dir.chdir(@tmpdir) do
            bad_file = "sync_dir/bad\xFFfile"
            sanitized_bad_file = "sync_dir/bad\xEF\xBF\xBDfile"
            FileUtils.touch bad_file

            expect(Logger).to receive(:warn).with(
              "\s\s[skipping] #{File.expand_path(sanitized_bad_file)}\n" \
              "\s\sPath Contains Invalid UTF-8 byte sequences"
            )

            local_files = described_class.find("sync_dir")
            expect(local_files.keys.count).to be 3
            local_files.each do |relative_path, local_file|
              expect(local_file.path).to eq(
                File.expand_path("sync_dir/#{relative_path}")
              )
              expect(local_file.md5).to eq(
                test_files["sync_dir/#{relative_path}"]
              )
            end
          end
        end

        it "ignores excluded files" do
          expect(
            described_class.find(@tmpdir, ["**/two.*", /sub|base_dir/]).keys
          ).to eq(["sync_dir/one.file"])
        end

        it 'follows symlinks that remain within the sync root' do
          FileUtils.ln_s File.join(@tmpdir, 'base_dir.file'),
            File.join(@tmpdir, 'sync_dir/link')
          FileUtils.ln_s File.join(@tmpdir, 'sync_dir/sub_dir'),
            File.join(@tmpdir, 'sync_dir/sub_dir_link')

          found = described_class.find(@tmpdir)
          expect(found.keys).to include('sync_dir/link')
          expect(found['sync_dir/link'].md5).to eq(test_files['base_dir.file'])
          expect(found.keys).to include('sync_dir/sub_dir_link/three.file')
          expect(found['sync_dir/sub_dir_link/three.file'].md5)
            .to eq(test_files['sync_dir/sub_dir/three.file'])
        end

        it 'rejects symlinks that escape the sync root' do
          FileUtils.ln_s File.join(@tmpdir, 'base_dir.file'),
            File.join(@tmpdir, 'sync_dir/link')

          expect do
            described_class.find(File.join(@tmpdir, 'sync_dir'))
          end.to raise_error(Backup::Path::Error, /Invalid Sync Source Path/)
        end

        it 'ignores excluded symlinks that escape the sync root' do
          FileUtils.ln_s File.join(@tmpdir, 'base_dir.file'),
            File.join(@tmpdir, 'sync_dir/link')

          found = described_class.find(
            File.join(@tmpdir, 'sync_dir'), ['**/link']
          )

          expect(found).not_to include('link')
        end

        it 'rejects directory symlinks that escape the sync root' do
          FileUtils.ln_s @tmpdir, File.join(@tmpdir, 'sync_dir/link')

          expect do
            described_class.find(File.join(@tmpdir, 'sync_dir'))
          end.to raise_error(Backup::Path::Error, /Invalid Sync Source Path/)
        end
      end
    end
  end
end
