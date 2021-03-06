require_relative 'base'
require_relative 'errors'

class TextApi < Base
  get '/refresh/?' do
    require_api_key
    settings.dictionaries.each(&:refresh!)
    200
  rescue CouldNotObtainDatabaseLock
    error 503
  end

  namespace '/:dictionary/:acronym/?' do
    get do
      entries = dictionary.lookup(acronym)

      format_results(entries)
    end

    post do
      require_api_key

      pull_request = dictionary.define(acronym, definition, user)

      pull_request.html_url
    end
  end

  def dictionary
    @dictionary ||= fetch_dictionary
  end

  def user
    @user ||= fetch_user
  end

  def acronym
    error 400 unless params[:acronym]
    params[:acronym]
  end

  def definition
    error 400 unless params[:definition]
    params[:definition]
  end

  def require_api_key
    error 401 unless user
  end

  def fetch_dictionary
    error 400 unless params[:dictionary]

    dictionary = settings.dictionaries.find do |dictionary|
      params[:dictionary].upcase == dictionary.name.upcase
    end

    error 404 unless dictionary

    dictionary
  end

  def fetch_user
    auth_header = request.env['HTTP_AUTHORIZATION']
    return unless auth_header
    components = auth_header.split
    return unless components[0] == 'Token'
    return unless components[1]

    api_key = settings.api_keys.find do |api_key|
      Rack::Utils.secure_compare(api_key['token'], components[1])
    end

    return api_key['name'] if api_key
  end

  def format_results(entries)
    definitions = entries.map { |entry| entry[Dictionary::DEFINITION] }
    definitions.join("\n")
  end
end
