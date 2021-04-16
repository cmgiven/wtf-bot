require 'redis'
require 'octokit'
require 'base64'
require 'json'
require 'csv'

require_relative 'errors'

$redis = Redis.new(
  :url => ENV['DATABASE_URL'],
  :reconnect_attempts => 3,
  :reconnect_delay => 1.0,
  :reconnect_delay_max => 2.0,
)

class Dictionary
  PATH = 'acronyms.csv'.freeze
  ACRONYM = 'acronym'.freeze
  DEFINITION = 'definition'.freeze
  HEADERS = [ACRONYM, DEFINITION].freeze
  RETRY_DELAY = 1.5.freeze
  RETRY_DELAY_MAX = 10.0.freeze
  LOCK_TTL = 30000.freeze
  UNLOCK_SCRIPT = <<-LUA.freeze
  if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
  else
    return 0
  end
  LUA

  attr_reader :name, :repo, :default_branch, :webhook_secret

  def initialize(name, repo, access_token, webhook_secret, default_branch)
    @name = name
    @repo = repo
    @access_token = access_token
    @webhook_secret = webhook_secret
    @default_branch = default_branch || 'main'

    retrieve_from_github_if_needed
  end

  def lookup(acronym)
    raise DictionaryNotLoadedError unless file_sha
    entries = $redis.lrange(acronym_cache_key(acronym), 0, -1)
    entries.map { |entry| JSON.parse(entry) }
  end

  def define(acronym, definition, author)
    with_lock(retries: 1) do
      array = to_a << { ACRONYM => acronym, DEFINITION => definition }
      sorted = array.sort_by { |entry| [entry[ACRONYM], entry[DEFINITION]] }
      csv = hashes_to_csv_string(sorted)

      create_pull_request(csv, acronym, definition, author)
    end
  end

  def refresh!
    with_lock(retries: 10) do
      clear_cache
      retrieve_from_github
    end
  end

  def to_a
    entries = []

    with_lock do
      $redis.smembers(defined_keys_cache_key).each do |key|
        entries += $redis.lrange(acronym_cache_key(key), 0, 1)
      end
    end

    entries.map { |entry| JSON.parse(entry) }
  end

  def to_csv
    hashes_to_csv_string(to_a)
  end

  private

  def github
    @github ||= Octokit::Client.new(:access_token => @access_token)
  end

  def file_sha
    $redis.get(file_sha_cache_key)
  end

  def head_sha
    $redis.get(head_sha_cache_key)
  end

  def clear_cache
    $redis.del(file_sha_cache_key)
    $redis.del(head_sha_cache_key)

    $redis.smembers(defined_keys_cache_key).each do |key|
      $redis.del(acronym_cache_key(key))
    end

    $redis.del(defined_keys_cache_key)
  end

  def retrieve_from_github_if_needed
    return false if file_sha

    with_lock do
      retrieve_from_github
    end
  rescue CouldNotObtainDatabaseLock
    false
  end

  def retrieve_from_github
    file = github.contents(@repo, :path => PATH)
    csv = Base64.decode64(file.content)
    without_headers = csv.split("\n")[1..-1].join("\n")
    rows = CSV.parse(without_headers, headers: HEADERS)

    rows.each do |row|
      key = compare_string(row[ACRONYM])
      value = row.to_h.slice(*HEADERS).to_json
      $redis.sadd(defined_keys_cache_key, key)
      $redis.lpush(acronym_cache_key(key), value)
    end

    $redis.set(head_sha_cache_key, github.ref(@repo, "heads/#{@default_branch}").object.sha)
    $redis.set(file_sha_cache_key, file.sha)
  end

  def create_pull_request(content, acronym, definition, author)
    message = "#{author}'s definition of #{acronym}"
    timestamp = Time.now.strftime('%Y%m%dT%H%M%S')
    branch = "define-#{compare_string(acronym)}-#{timestamp}"

    github.create_ref(@repo, "refs/heads/#{branch}", head_sha)
    github.update_contents(@repo, PATH, message, file_sha, content, :branch => branch)
    github.create_pull_request(@repo, @default_branch, branch, message, definition)
  end

  def with_lock(retries: 0)
    lock_tries = 0

    begin
      lock = obtain_lock
      result = yield
      release_lock if lock
      result
    rescue CouldNotObtainDatabaseLock
      raise if (lock_tries += 1) > retries
      sleep [RETRY_DELAY * 2**(lock_tries - 1), RETRY_DELAY_MAX].min
      retry
    end
  end

  def obtain_lock
    return false if @lock
    @lock = get_unique_lock_id
    $redis.call([:set, cache_lock_key, @lock, :nx, :px, LOCK_TTL])
  rescue
    raise CouldNotObtainDatabaseLock
  end

  def release_lock
    $redis.call([:eval, UNLOCK_SCRIPT, 1, cache_lock_key, @lock])
  rescue
    false
  ensure
    @lock = nil
  end

  def get_unique_lock_id
    val = ''
    bytes = urandom.read(20)
    bytes.each_byte do |b|
      val << b.to_s(32)
    end
    val
  end

  def compare_string(acronym)
    acronym.gsub(/[\W_]/, '').downcase
  end

  def cache_key_prefix
    "wtf:dictionary:#{compare_string(@name)}"
  end

  def cache_lock_key
    "#{cache_key_prefix}:lock"
  end

  def file_sha_cache_key
    "#{cache_key_prefix}:file_sha"
  end

  def head_sha_cache_key
    "#{cache_key_prefix}:head_sha"
  end

  def defined_keys_cache_key
    "#{cache_key_prefix}:defined_keys"
  end

  def acronym_cache_key(acronym)
    "#{cache_key_prefix}:acronyms:#{compare_string(acronym)}"
  end

  def urandom
    @urandom ||= File.new('/dev/urandom')
  end

  def hashes_to_csv_string(hashes)
    lines = [HEADERS.to_csv]
    hashes.each do |hash|
      lines << [hash[ACRONYM], hash[DEFINITION]].to_csv
    end
    lines.join('')
  end
end
