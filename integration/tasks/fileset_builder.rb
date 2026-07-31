# encoding: utf-8

class FilesetBuilder
  def create(root_dir, dir_name, total, file_size)
    dir = File.join(root_dir, safe_component(dir_name))
    create_dir(dir)
    create_fileset(dir, total, file_size)
  end

  private

  def create_dir(dir)
    Dir.mkdir(dir) unless Dir.exist?(dir)
  end

  def create_file(file_path, file_size)
    File.open(file_path, "w") do |file|
      contents = "x" * (1024 * 1024)
      file_size.to_i.times { file.write(contents) }
    end
  end

  def create_fileset(dir, total, file_size)
    count = 0
    total.times do
      count += 1
      file_name = "#{count}.txt"
      file_path = File.join(dir, file_name)
      create_file(file_path, file_size)
    end
  end

  def safe_component(value)
    value = value.to_s
    invalid = value.empty? || value == "." || value.include?("..") ||
      value.include?("/") || value.include?("\\") || value.include?("\0")
    raise ArgumentError, "invalid directory name" if invalid
    value
  end
end
