require 'json'

require_relative 'base'

class GithubApi < Base
  before do
    require_dictionary
    require_valid_signature
  end

  post '/webhook/?' do
    dictionary.refresh! if event['ref'] == 'refs/heads/master'
  end

  def dictionary
    @dictionary ||= fetch_dictionary
  end

  def event
    @event ||= fetch_event
  end

  def secret
    dictionary.webhook_secret
  end

  def require_dictionary
    error 401 unless dictionary
  end

  def require_valid_signature
    error 401 unless valid_signature?
  end

  def valid_signature?
    request.body.rewind
    body = request.body.read
    signature = request.env['HTTP_X_HUB_SIGNATURE']

    digest = OpenSSL::Digest.new('sha1')
    sha = OpenSSL::HMAC.hexdigest(digest, secret, body)

    Rack::Utils.secure_compare(signature, 'sha1=' + sha)
  end

  def fetch_dictionary
    repo = event['repository']['full_name']

    settings.dictionaries.find do |dictionary|
      repo.upcase == repo.upcase
    end
  end

  def fetch_event
    request.body.rewind
    JSON.parse(request.body.read)
  end
end
