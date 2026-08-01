require "spec_helper"
require File.expand_path("../integration/tasks/fileset_builder", __dir__)

describe FilesetBuilder do
  it "creates generated files below the requested directory" do
    file = double
    expect(Dir).to receive(:exist?).with("root/safe_dir").and_return(true)
    expect(File).to receive(:open).with("root/safe_dir/1.txt", "w").and_yield(file)

    described_class.new.create("root", "safe_dir", 1, 0)
  end

  it "rejects a directory name that escapes the requested root" do
    expect(Dir).to_not receive(:mkdir)
    expect(File).to_not receive(:open)

    expect do
      described_class.new.create("root", "../outside", 1, 0)
    end.to raise_error(ArgumentError, "invalid directory name")
  end
end
