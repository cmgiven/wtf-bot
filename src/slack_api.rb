require 'json'
require 'net/http'

require_relative 'base'

class SlackApi < Base
  before do
    require_valid_signature
  end

  post '/commands/?' do
    case params[:command]
    when '/wtf'
      acronym = params[:text]
      json definition_message(acronym)
    end
  end

  post '/actions/?' do
    type = payload['type']

    Thread.new do
      case type
      when 'block_actions'
        action = payload['actions'][0]['value'].split(':')[0]

        case action
        when 'expand'
          expand_action
        when 'define'
          define_action
        end
      when 'view_submission'
        callback_id = payload['view']['callback_id']

        case callback_id
        when 'definition_modal'
          definition_modal_submission
        end
      end
    end

    status 200
  end

  def payload
    @payload ||= fetch_payload
  end

  def private_metadata
    @private_metadata ||= fetch_private_metadata
  end

  def slack
    @slack ||= fetch_slack
  end

  def channel_name
    @channel_name ||= fetch_channel_name
  end

  def dictionary
    @dictionary ||= fetch_dictionary
  end

  def other_dictionaries
    settings.dictionaries - [dictionary]
  end

  def secret
    slack ? slack['secret'] : '0' * 32
  end

  def access_token
    slack['access_token']
  end

  def expand_action
    response_url = payload['response_url']
    acronym = payload['actions'][0]['value'][7..-1]

    message = definition_message(acronym, true)
    message[:replace_original] = true

    post_json(message.to_json, response_url)
  end

  def define_action
    trigger_id = payload['trigger_id']
    acronym = payload['actions'][0]['value'][7..-1].upcase

    modal = add_definition_modal(trigger_id, acronym)

    post_json(modal.to_json, 'https://slack.com/api/views.open')
  end

  def definition_modal_submission
    trigger_id = payload['trigger_id']
    author = payload['user']['name']
    state = payload['view']['state']['values'].values.inject(:merge)
    acronym = state[Dictionary::ACRONYM]['value']
    definition = state[Dictionary::DEFINITION]['value']

    pull_request = dictionary.define(acronym, definition, author)
    modal = definition_proposed_modal(trigger_id, pull_request.html_url)

    post_json(modal.to_json, 'https://slack.com/api/views.open')
  end

  def require_valid_signature
    error 401 unless valid_signature?
  end

  def valid_signature?
    request.body.rewind
    body = request.body.read
    timestamp = request.env['HTTP_X_SLACK_REQUEST_TIMESTAMP']
    signature = request.env['HTTP_X_SLACK_SIGNATURE']

    sig_basestring = "v0:#{timestamp}:#{body}"

    digest = OpenSSL::Digest.new('sha256')
    sha = OpenSSL::HMAC.hexdigest(digest, secret, sig_basestring)

    Rack::Utils.secure_compare(signature, 'v0=' + sha)
  end

  def fetch_payload
    params[:payload] && JSON.parse(params[:payload])
  end

  def fetch_private_metadata
    if payload && payload['view'] && payload['view']['private_metadata']
      JSON.parse(payload['view']['private_metadata'])
    end
  end

  def fetch_slack
    slack_name = params[:team_domain] || payload['team']['domain']
    slacks = settings.slacks.select do |slack|
      Rack::Utils.secure_compare(slack_name.upcase, slack['name'].upcase)
    end
    slacks[0]
  end

  def fetch_channel_name
    if params[:channel_name]
      params[:channel_name]
    elsif payload && payload['channel']
      payload['channel']['name']
    elsif private_metadata
      private_metadata['channel_name']
    end
  end

  def fetch_dictionary
    if slack['channels']
      slack['channels'].each do |channel|
        pattern = Regexp.new("^#{channel['pattern']}$")
        return settings.dictionaries[channel['dictionary']] if pattern.match?(channel_name)
      end
    end

    settings.dictionaries[slack['dictionary']]
  end

  def definition_message(acronym, expanded = false)
    entries = dictionary.lookup(acronym)

    blocks = default_dictionary_slack_blocks(entries, acronym)

    if settings.dictionaries.length > 1
      if !expanded
        blocks += expand_search_slack_blocks(acronym)
      else
        lookups = other_dictionaries.map do |dictionary|
          [dictionary.name, dictionary.lookup(acronym)]
        end

        results = lookups.reject { |lookup| lookup[1].empty? }

        if results.empty?
          blocks += no_additional_results_slack_blocks(acronym)
        else
          blocks += results.flat_map do |lookup|
            dictionary_name = lookup[0]
            entries = lookup[1]

            other_dictionary_slack_blocks(entries, acronym, dictionary_name)
          end
        end
      end
    end

    { blocks: blocks }
  end

  def default_dictionary_slack_blocks(entries, acronym)
    [
      {
        type: 'section',
        text: { type: 'mrkdwn', text: format_results(entries, acronym) },
        accessory: {
          type: 'button',
          text: { type: 'plain_text', text: '+ New Definition' },
          value: "define:#{acronym}"
        }
      }
    ]
  end

  def other_dictionary_slack_blocks(entries, acronym, dictionary_name)
    [
      { type: 'divider' },
      {
        type: 'context',
        elements: [{ type: 'plain_text', text: ":book: #{dictionary_name} Acronyms" }]
      },
      {
        type: 'section',
        text: { type: 'mrkdwn', text: format_results(entries, acronym) }
      }
    ]
  end

  def format_results(entries, acronym)
    return "No definition found for *#{acronym.upcase}*." if entries.empty?

    markdown_strings = entries.map do |e|
      "*#{e[Dictionary::ACRONYM]}:* #{e[Dictionary::DEFINITION]}"
    end

    markdown_strings.join("\n")
  end

  def expand_search_slack_blocks(acronym)
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

  def no_additional_results_slack_blocks(acronym)
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
  end

  def add_definition_modal(trigger_id, acronym)
    {
      trigger_id: trigger_id,
      view: {
        type: 'modal',
        callback_id: 'definition_modal',
        private_metadata: {channel_name: channel_name}.to_json,
        title: { type: 'plain_text', text: 'New Definition' },
        submit: { type: 'plain_text', text: 'Submit' },
        close: { type: 'plain_text', text: 'Cancel' },
        blocks: [
          {
            type: 'section',
            text: {
              type: 'plain_text',
              text: "Propose a new definition for the #{dictionary.name} acronym dictionary."
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

  def definition_proposed_modal(trigger_id, pr_url)
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

  def post_json(json, url)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    req.body = json
    req['Authorization'] = "Bearer #{access_token}"
    http.request(req)
  end
end
