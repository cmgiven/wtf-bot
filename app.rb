require 'sinatra'
require 'sinatra/contrib'
require 'sinatra/reloader'
require 'redis'
require 'yaml'
require 'json'
require 'net/http'
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

    error 404 do
      "ERROR: No definition found"
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

  namespace '/github/webhook/:dictionary' do
    before do
      @dictionary = dictionary_from_params
      error 401 unless github_signature_valid?(@dictionary.webhook_secret)
    end

    post '/?' do
      request.body.rewind
      event = JSON.parse(request.body.read)
      @dictionary.refresh! if event['ref'] == 'refs/heads/master'
    end
  end

  namespace '/slack' do
    before do
      slack_name = params[:team_domain] || JSON.parse(params[:payload])['team']['domain']
      slacks = @@settings['slacks'].select do |slack|
        Rack::Utils.secure_compare(slack_name.upcase, slack['name'].upcase)
      end
      secret = slacks[0] ? slacks[0]['secret'] : DUMMY_SECRET

      error 401 unless slack_signature_valid?(secret)

      @dictionary = @@dictionaries[slacks[0]['dictionary']]
      @access_token = slacks[0]['access_token']
    end

    post '/commands/?' do
      case params[:command]
      when '/wtf'
        acronym = params[:text]
        json slack_message(@dictionary, acronym)
      end
    end

    post '/actions/?' do
      payload = JSON.parse(params[:payload])
      type = payload['type']

      Thread.new do
        case type
        when 'block_actions'
          action = payload['actions'][0]['value'].split(':')[0]

          case action
          when 'expand'
            response_url = payload['response_url']
            acronym = payload['actions'][0]['value'][7..-1]
            message = slack_message(@dictionary, acronym, true)
            message[:replace_original] = true
            post_json(message.to_json, response_url)
          when 'define'
            trigger_id = payload['trigger_id']
            acronym = payload['actions'][0]['value'][7..-1].upcase
            modal = slack_add_definition_modal(trigger_id, acronym, @dictionary.name)
            post_json(modal.to_json, 'https://slack.com/api/views.open', @access_token)
          end
        when 'view_submission'
          callback_id = payload['view']['callback_id']

          case callback_id
          when 'definition_modal'
            trigger_id = payload['trigger_id']
            author = payload['user']['name']
            state = payload['view']['state']['values'].values.inject(:merge)
            acronym = state[Dictionary::ACRONYM]['value']
            definition = state[Dictionary::DEFINITION]['value']
            pr = @dictionary.define(acronym, definition, author)
            modal = slack_definition_proposed_modal(trigger_id, pr.html_url)
            post_json(modal.to_json, 'https://slack.com/api/views.open', @access_token)
          end
        end
      end

      200
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
    return unless auth_header
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

  def post_json(json, url, access_token = nil)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    req.body = json
    req['Authorization'] = "Bearer #{access_token}" if access_token
    http.request(req)
  end

  def slack_message(dictionary, acronym, expanded = false)
    other_dictionaries = @@dictionaries - [@dictionary]

    {
      blocks: primary_dictionary_slack_blocks(@dictionary, acronym) +
        other_dictionaries_slack_blocks(other_dictionaries, acronym, expanded)
    }
  end

  def primary_dictionary_slack_blocks(dictionary, acronym)
    entries = dictionary.lookup(acronym)
    result = entries.empty? ?
      "No definition found for *#{acronym.upcase}*." :
      mrkdwn_fmt_acronyms(entries)

    [
      {
        type: 'section',
        text: {
          type: 'mrkdwn',
          text: result
        },
        accessory: {
          type: 'button',
          text: { type: 'plain_text', text: '+ New Definition' },
          value: "define:#{acronym}"
        }
      }
    ]
  end

  def other_dictionaries_slack_blocks(dictionaries, acronym, expanded)
    return [] if dictionaries.empty?

    if expanded
      dictionaries_with_results = dictionaries.map { |d| [d.name, d.lookup(acronym)] }
        .select { |d| !d[1].empty? }

      if dictionaries_with_results.empty?
        [
          { type: 'divider' },
          {
            type: 'section',
            text: {
              type: 'mrkdwn',
              text: "No additional definitions found for *#{acronym.upcase}*."
            }
          }
        ]
      else
        dictionaries_with_results.flat_map do |dictionary|
          [
            { type: 'divider' },
            {
              type: 'context',
              elements: [{ type: 'plain_text', text: ":book: #{dictionary[0]} Acronyms" }]
            },
            {
              type: 'section',
              text: {
                type: 'mrkdwn',
                text: mrkdwn_fmt_acronyms(dictionary[1])
              }
            }
          ]
        end
      end
    else
      [
        { type: 'divider' },
        {
          type: 'actions',
          elements: [{
            type: 'button',
            text: { type: 'plain_text', text: 'Search Other Dictionaries' },
            value: "expand:#{acronym}"
          }]
        },
      ]
    end
  end

  def mrkdwn_fmt_acronyms(entries)
    entries.map { |e| "*#{e[Dictionary::ACRONYM]}:* #{e[Dictionary::DEFINITION]}" }.join("\n")
  end

  def slack_definition_proposed_modal(trigger_id, pr_url)
    {
      trigger_id: trigger_id,
      view: {
        type: 'modal',
        title: { type: 'plain_text', text: 'Definition Proposed' },
        blocks: [
          {
            type: 'section',
            text: {
              type: 'mrkdwn',
              text: ":tada: Thank you! A pull request was created with your new definition:\n\n#{pr_url}"
            }
          }
        ]
      }
    }
  end

  def slack_add_definition_modal(trigger_id, acronym, dictionary_name)
    {
      trigger_id: trigger_id,
      view: {
        type: 'modal',
        callback_id: 'definition_modal',
        title: { type: 'plain_text', text: 'New Definition' },
        submit: { type: 'plain_text', text: 'Submit' },
        close: { type: 'plain_text', text: 'Cancel' },
        blocks: [
          {
            type: 'section',
            text: {
              type: 'plain_text',
              text: "Propose a new definition for the #{dictionary_name} acronym dictionary."
            }
          },
          { type: 'divider' },
          {
            type: 'input',
            element: {
              type: 'plain_text_input',
              action_id: Dictionary::ACRONYM,
              initial_value: acronym
            },
            label: { type: 'plain_text', text: 'Acronym' }
          },
          {
            type: 'input',
            element: {
              type: 'plain_text_input',
              action_id: Dictionary::DEFINITION
            },
            label: { type: 'plain_text', text: 'Definition' }
          }
        ]
      }
    }
  end

  configure :development do
    register Sinatra::Reloader
    Dir.glob("./*.rb").each { |file| also_reload(file) }
  end
end
