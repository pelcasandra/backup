require "spec_helper"

module Backup
  describe Template do
    describe "#result" do
      it "reads templates below TEMPLATE_PATH" do
        expect(Template.new.result("general/links"))
          .to include("github.com/backup/backup")
      end

      it "rejects paths that escape TEMPLATE_PATH" do
        expect do
          Template.new.result("../backup.gemspec")
        end.to raise_error(Path::Error, /Invalid Template Path/)
      end
    end
  end
end
