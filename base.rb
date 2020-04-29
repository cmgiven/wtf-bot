require 'sinatra/base'
require 'sinatra/contrib'
require 'sinatra/reloader'
require 'json'
require 'yaml'

require_relative 'dictionary'

class Base < Sinatra::Base
  register Sinatra::Namespace

  configure do
    if ENV['WTF_BOT_SETTINGS']
      config = JSON.parse(ENV['WTF_BOT_SETTINGS'])
    else
      config = YAML.load(File.open('settings.yml'))
    end

    dictionaries = config['dictionaries'].map do |d|
      Dictionary.new(
        d['name'],
        d['repo'],
        d['access_token'],
        d['webhook_secret'],
      )
    end

    set :dictionaries, dictionaries
    set :api_keys, config['api_keys']
    set :slacks, config['slacks']
  end

  configure :development do
    register Sinatra::Reloader
    Dir.glob("./*.rb").each { |file| also_reload(file) }
  end
end
