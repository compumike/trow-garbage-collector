#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "logger"
require "open3"
require "optparse"
require "ostruct"
require "securerandom"
require "set"

class Repository
  MIN_GC_BLOB_AGE = ENV.fetch("MIN_GC_BLOB_AGE", "86400").to_i.clamp(0..)

  attr_reader :manifests

  def initialize(log:)
    @log = log
    @blobs = {}
    @manifests = {}
  end

  def add_blob(name:, filename:, size:, mtime:)
    @blobs[name] = OpenStruct.new(filename: filename, size: size, mtime: mtime, mentioned_by: Set.new)
  end

  def add_manifest(name:)
    @manifests[name] = OpenStruct.new
  end

  def set_manifest_blob(name:, blob:)
    @manifests[name].blob = blob
    add_mention(blob: blob, from: name)
  end

  def add_mention(blob:, from:)
    # Clean the hash
    blob = blob[7...] if blob.start_with?("sha256:")
    raise "Bad blob #{blob}" unless /\A[0-9a-f]{64}\z/.match?(blob)

    # Mark it
    blobdata = @blobs[blob]
    if blobdata.nil?
      @log.warn("Source #{from} points to blob #{blob} which doesn't exist on disk!")
      return
    end

    blobdata.mentioned_by << from
  end

  def filenames_to_delete(dry_run:, min_age: MIN_GC_BLOB_AGE)
    orphaned_blobs(min_age: min_age).tap do |filtered_blobs|
      yield filtered_blobs.values.map(&:filename)
      @blobs.delete_if { |k, _v| filtered_blobs.key?(k) } unless dry_run
    end
  end

  def puts_summary
    puts "Blobs: #{@blobs.count}"
    puts "Total size: #{@blobs.values.map(&:size).sum} bytes"
    puts "Manifests: #{@manifests.count}"
    puts "Orphaned blobs: #{orphaned_blobs.count}"
    puts "Orphaned blob total size: #{orphaned_blobs.values.map(&:size).sum} bytes"
  end

  private

  def orphaned_blobs(min_age: MIN_GC_BLOB_AGE)
    time_cutoff = Time.now - min_age
    @blobs.filter { |k, v| v.mentioned_by.empty? && v.mtime < time_cutoff }
  end
end

class TrowGarbageCollector
  POLL_INTERVAL = ENV.fetch("POLL_INTERVAL", "3600").to_i.clamp(1..)
  TROW_NAMESPACE = ENV.fetch("TROW_NAMESPACE", "trow").freeze
  TROW_POD = ENV.fetch("TROW_POD", "trow-0").freeze

  def initialize
    STDOUT.sync = true
    @log = Logger.new(STDOUT)
    @repo = Repository.new(log: @log)
    @dry_run = (ENV.fetch("DRY_RUN", "false") =~ /^(true|y|yes|1)$/i)
  end

  def trow_exec(*cmd_array, stdin_data: nil)
    # Runs a command within the TROW_POD pod and captures standard output.
    cmds = ["kubectl", "exec", "-n", TROW_NAMESPACE, TROW_POD, (["", nil].include?(stdin_data) ? nil : "-i"), "--"].compact + cmd_array

    stdout, stderr, status = Open3.capture3(*cmds, stdin_data: stdin_data)
    OpenStruct.new(stdout: stdout, stderr: stderr, status: status)
  end

  def puts_df_data
    result = trow_exec("df", "-h", "/data")
    raise "Error: #{result.status}" unless result.status.success?

    puts ""
    puts result.stdout
    puts ""
  end

  def fetch_file_sizes
    result = trow_exec("/bin/bash", "-c", "find /data/ -type f -print0 | xargs --no-run-if-empty -0 -n 1 stat -c '%s %Y %n'")
    raise "Error: #{result.status}" unless result.status.success?

    result.stdout.strip.split("\n").each do |line|
      line_sp = line.gsub(/\s+/, " ").split
      raise "Bad line '#{line_sp}'" unless line_sp.count == 3

      fsize, fmtime, fname = line_sp
      fsize = Integer(fsize)
      fmtime = Time.at(Integer(fmtime))

      if fname.start_with?("/data/blobs/sha256/")
        blobname = fname[("/data/blobs/sha256/".length)...]
        @repo.add_blob(name: blobname, filename: fname, size: fsize, mtime: fmtime)
      elsif fname.start_with?("/data/manifests/")
        @repo.add_manifest(name: fname)
      end
    end
  end

  def fetch_manifests
    @_manifest_tmpdir = File.join("/dev/shm", SecureRandom.hex)
    FileUtils.mkdir(@_manifest_tmpdir)

    Open3.pipeline(["kubectl", "exec", "-n", TROW_NAMESPACE, TROW_POD, "--", "/bin/bash", "-c", "find /data/manifests/ -type f -print0 | xargs --no-run-if-empty -0 tar -cf -"],
      ["tar", "-C", @_manifest_tmpdir, "-xf", "-"])
  end

  def parse_manifest(manifest_name:, contents:)
    contents = contents.strip.split("\n")

    @log.info "Parsing manifest #{manifest_name}"

    contents.each do |line|
      next unless line.start_with?("sha256:")

      hash = line[7...].split[0]
      raise "Bad hash #{hash}" unless /\A[0-9a-f]{64}\z/.match?(hash)

      @repo.set_manifest_blob(name: manifest_name, blob: hash)
      break # only parse first valid line
    end
  end

  def parse_manifests
    Dir.glob(File.join(@_manifest_tmpdir, "**/*")).filter { |fn| File.file?(fn) }.each do |filename|
      raise "Weird filename #{filename}" unless filename.start_with?(@_manifest_tmpdir)

      manifest_name = filename[@_manifest_tmpdir.length...]
      raise "Weird manifest name #{manifest_name}" unless manifest_name.start_with?("/data/manifests/")

      parse_manifest(manifest_name: manifest_name, contents: File.read(filename))
    end
  end

  def delete_manifest_tmpdir
    FileUtils.rm_r(@_manifest_tmpdir)
  end

  def fetch_jsons
    @_jsons_tmpdir = File.join("/dev/shm", SecureRandom.hex)
    FileUtils.mkdir(@_jsons_tmpdir)

    jsons_filenames = @repo.manifests.map { |manifest_name, manifest_data|
      blob = manifest_data.blob
      raise "No blob found for manifest #{manifest_name}. Terminating!" if blob.nil?
      blob
    }.uniq
    if jsons_filenames.empty?
      @log.info "No JSONs to retrieve. Skipping"
      return
    end

    @log.info "Trying to fetch: #{jsons_filenames}"

    stdin_data = jsons_filenames.join("\0")

    cmd1 = ["kubectl", "exec", "-n", TROW_NAMESPACE, TROW_POD, "-i", "--", "/bin/bash", "-c", "xargs -0 tar -C /data/blobs/sha256/ -cf -"]
    cmd2 = ["tar", "-C", @_jsons_tmpdir, "-xf", "-"]
    Open3.pipeline_w(cmd1, cmd2) do |first_stdin, wait_threads|
      first_stdin.write(stdin_data)
      first_stdin.close
      wait_threads.each(&:join)
    end
  end

  def parse_json(blob:, contents:)
    d = JSON.parse(contents)
    raise "Bad JSON" unless d.is_a?(Hash)
    raise "Bad mediaType" unless d.dig("mediaType") == "application/vnd.docker.distribution.manifest.v2+json"
    raise "Can't find config" unless d["config"].is_a?(Hash)
    raise "Can't find layers" unless d["layers"].is_a?(Array)

    @repo.add_mention(blob: d.dig("config", "digest"), from: blob)
    d["layers"].each do |layer|
      @repo.add_mention(blob: layer["digest"], from: blob)
    end
  end

  def parse_jsons
    Dir.glob(File.join(@_jsons_tmpdir, "**/*")).filter { |fn| File.file?(fn) }.each do |filename|
      parse_json(blob: File.basename(filename), contents: File.read(filename))
    end
  end

  def delete_jsons_tmpdir
    FileUtils.rm_r(@_jsons_tmpdir)
  end

  def delete_orphaned_blobs
    @log.info "Deleting orphaned blobs..."
    @repo.filenames_to_delete(dry_run: dry_run) do |filenames|
      if filenames.empty?
        @log.info "No files to delete. Skipping."
        break
      end
      result = trow_exec("/bin/bash", "-c", delete_cmd(dry_run: dry_run), stdin_data: filenames.join("\0"))
      raise "Error: #{result.status}" unless result.status.success?

      puts result.stdout
    end
  end

  def garbage_collect
    puts_df_data

    # PHASE 1: Look at /data/blobs/ and /data/manifests/
    fetch_file_sizes

    # PHASE 2: Open the files in /data/manifests/, which point from tags to manifest contents
    fetch_manifests
    parse_manifests
    delete_manifest_tmpdir

    # PHASE 3: Retrieve the manifest JSONs and mark all mentioned layers and configs
    fetch_jsons
    parse_jsons
    delete_jsons_tmpdir

    @repo.puts_summary

    # PHASE 4: Actually delete orphaned blobs
    delete_orphaned_blobs

    puts_df_data
  end

  def main_loop
    OptionParser.new { |opts|
    }.parse!

    @log.info("Starting main_loop with #{POLL_INTERVAL}s polling interval.")
    loop do
      garbage_collect
      sleep(POLL_INTERVAL)
    end
  end

  private

  attr_reader :dry_run

  def delete_cmd(dry_run:)
    cmd = "rm"
    if dry_run
      @log.info("DRY RUN -- not actually deleting")
      cmd = "stat -c '%s %Y %n'"
    end
    "xargs -0 -n 1 #{cmd}"
  end
end

TrowGarbageCollector.new.main_loop if $PROGRAM_NAME == __FILE__
