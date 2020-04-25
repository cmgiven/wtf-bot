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
  @@settings = YAML.load(File.open('settings.yml'))
  @@dictionaries = @@settings['dictionaries'].map do |config|
    Dictionary.new(
      config['name'],
      config['repo'],
      config['access_token'],
      config['webhook_secret'],
    )
  end

  namespace '/:dictionary' do
    before do
      @dictionary = @@dictionaries.find do |dictionary|
        params['dictionary'].upcase == dictionary.name.upcase
      end

      error 404 unless @dictionary
    end

    get '/lookup/:acronym/?' do
      acronym = params['acronym']
      entries = @dictionary.lookup(acronym)
      entries.map { |d| d[Dictionary::DEFINITION] }
    end

    namespace '/define' do
      before do
        auth_header = request.env['HTTP_AUTHORIZATION']
        @user = api_user_from_token(auth_header)

        error 401 unless @user
      end

      post '/?' do
        request.body.rewind
        body = JSON.parse(request.body.read)
        acronym = body['acronym']
        definition = body[Dictionary::DEFINITION]

        error 400 unless acronym.instance_of?(String) &&
                         acronym.length > 0 &&
                         definition.instance_of?(String) &&
                         definition.length > 0

        pr = @dictionary.define(acronym, definition, @user)

        pr.html_url
      end
    end
  end

  def api_user_from_token(auth_header)
    components = auth_header.split

    return unless components[0] == 'Token'
    return unless components[1]

    api_key = @@settings['api_keys'].find do |api_key|
      Rack::Utils.secure_compare(api_key['token'], components[1])
    end

    return api_key['name'] if api_key
  end

  configure :development do
    register Sinatra::Reloader
    Dir.glob("./*.rb").each { |file| also_reload(file) }
  end
end
