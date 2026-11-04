# frozen_string_literal: true

require 'fileutils'

# Temporary copies of an MPR package, for gates that must not touch the original.
module PackageCopy
  module_function

  # The name in mprcontents/mprname when it is not this MPR. The library refuses to
  # open such a project, because writing to it would corrupt the owner's contents.
  def contents_owner(source)
    marker = File.join(File.dirname(source), 'mprcontents', 'mprname')
    return unless File.file?(marker)

    owner = File.read(marker).strip
    owner unless owner == File.basename(source)
  end

  def copy(source, directory)
    copy = File.join(directory, File.basename(source))
    FileUtils.cp(source, copy)
    contents = File.join(File.dirname(source), 'mprcontents')
    FileUtils.cp_r(contents, directory) if File.directory?(contents)
    copy
  end

  # A copy whose marker names the project, so the library will open it.
  def claim(source, directory)
    claimed = copy(source, directory)
    File.write(File.join(directory, 'mprcontents', 'mprname'), File.basename(source))
    claimed
  end
end
