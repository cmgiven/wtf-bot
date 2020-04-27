require 'sinatra'
require 'sinatra/contrib'
require 'sinatra/reloader'
require 'redis'
require 'yaml'
require 'json'
require_relative 'dictionary'

$redis = Redis.new(
  :reconnect_attempts => 3,
  :reconnect_delay => 1.0,
  :reconnect_delay_max => 2.0,
)

class WtfBot < Sinatra::Application
  DUMMY_SECRET = ('0' * 32).freeze

  @@settings = YAML.load(File.open('settings.yml'))
  @@dictionaries = @@settings['dictionaries'].map do |config|
    Dictionary.new(
      config['name'],
      config['repo'],
      config['access_token'],
      config['webhook_secret'],
    )
  end

  namespace '/lookup' do
    get '/:dictionary/:acronym/?' do
      entries = dictionary_from_params.lookup(params[:acronym])
      error 404 if entries.empty?
      entries.map { |d| d[Dictionary::DEFINITION] }.join("\n")
    end
  end

  namespace '/define' do
    before do
      @user = api_user
      error 401 unless @user
    end

    post '/:dictionary/?' do
      request.body.rewind
      body = JSON.parse(request.body.read)
      acronym = body[Dictionary::ACRONYM]
      definition = body[Dictionary::DEFINITION]

      error 400 unless acronym.instance_of?(String) &&
                       acronym.length > 0 &&
                       definition.instance_of?(String) &&
                       definition.length > 0

      pr = dictionary_from_params.define(acronym, definition, @user)

      pr.html_url
    end
  end

  namespace '/github' do
    before do
      @dictionary = dictionary_from_params
      error 401 unless github_signature_valid?(@dictionary.webhook_secret)
    end

    post '/webhook/:dictionary/?' do
      request.body.rewind
      event = JSON.parse(request.body.read)
      @dictionary.refresh! if event['ref'] == 'refs/heads/master'
    end
  end

  namespace '/slack' do
    before do
      slack_name = params[:team_domain]
      slacks = @@settings['slacks'].select do |slack|
        Rack::Utils.secure_compare(slack_name.upcase, slack['name'].upcase)
      end
      secret = slacks[0] ? slacks[0]['secret'] : DUMMY_SECRET

      error 401 unless slack_signature_valid?(secret)

      @dictionary = @@dictionaries[slacks[0]['dictionary']]
    end

    post '/commands/?' do
      case params[:command]
      when '/wtf'
        acronym = params[:text]
        entries = @dictionary.lookup(acronym)
        return entries.map { |d| d[Dictionary::DEFINITION] }.join("\n")
      end
    end

    post '/actions/?' do
    end
  end

  def dictionary_from_params
    error 400 unless params[:dictionary]

    dictionary = @@dictionaries.find do |dictionary|
      params[:dictionary].upcase == dictionary.name.upcase
    end

    error 404 unless dictionary

    return dictionary
  end

  def api_user
    auth_header = request.env['HTTP_AUTHORIZATION']
    components = auth_header.split

    return unless components[0] == 'Token'
    return unless components[1]

    api_key = @@settings['api_keys'].find do |api_key|
      Rack::Utils.secure_compare(api_key['token'], components[1])
    end

    return api_key['name'] if api_key
  end

  def slack_signature_valid?(secret = DUMMY_SECRET)
    request.body.rewind
    body = request.body.read
    timestamp = request.env['HTTP_X_SLACK_REQUEST_TIMESTAMP']
    signature = request.env['HTTP_X_SLACK_SIGNATURE']

    sig_basestring = "v0:#{timestamp}:#{body}"

    digest = OpenSSL::Digest.new('sha256')
    sha = OpenSSL::HMAC.hexdigest(digest, secret, sig_basestring)

    Rack::Utils.secure_compare(signature, 'v0=' + sha)
  end

  def github_signature_valid?(secret = DUMMY_SECRET)
    request.body.rewind
    body = request.body.read
    signature = request.env['HTTP_X_HUB_SIGNATURE']

    digest = OpenSSL::Digest.new('sha1')
    sha = OpenSSL::HMAC.hexdigest(digest, secret, body)

    Rack::Utils.secure_compare(signature, 'sha1=' + sha)
  end

  configure :development do
    register Sinatra::Reloader
    Dir.glob("./*.rb").each { |file| also_reload(file) }
  end
end
