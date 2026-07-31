require "spec_helper"

describe Backup::Path do
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
