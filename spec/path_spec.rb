require "spec_helper"

describe Backup::Path do
  describe ".join_within" do
    it "joins validated components beneath the trusted root" do
      root = File.join(Dir.tmpdir, "backup-path-spec")

      expect(
        described_class.join_within(
          root,
          "application",
          "2026.08.06.12.00.00",
          label: "Outbox Package Path"
        )
      ).to eq(File.join(root, "application", "2026.08.06.12.00.00"))
    end

    it "rejects components that could escape the trusted root" do
      expect do
        described_class.join_within(
          Dir.tmpdir,
          "../outside",
          label: "Outbox Package Path"
        )
      end.to raise_error(described_class::Error, /Invalid Outbox Package Path/)
    end
  end

  describe ".join_components" do
    it "builds a relative path from validated components" do
      expect(
        described_class.join_components(
          "backups",
          "application",
          "package.tar",
          label: "Object Key Component"
        )
      ).to eq("backups/application/package.tar")
    end

    it "rejects separators in any component" do
      expect do
        described_class.join_components(
          "backups",
          "application/../outside",
          label: "Object Key Component"
        )
      end.to raise_error(described_class::Error, /Invalid Object Key Component/)
    end
  end

  describe "model triggers" do
    it "rejects values that can escape a path component" do
      ["", ".", "../foo", "foo/../bar", "foo/bar", "foo\\bar"].each do |trigger|
        expect do
          Backup::Model.new(trigger, "label")
        end.to raise_error(Backup::Path::Error, /Invalid Model Trigger/)
      end
    end

    it "preserves safe punctuation" do
      expect(Backup::Model.new("nightly-backup.1", "label").trigger)
        .to eq("nightly-backup.1")
    end
  end
end
