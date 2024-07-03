require_relative 'text_api'
require_relative 'slack_api'
require_relative 'github_api'
require_relative 'status_api'

module WtfBot
  def self.app
    Rack::Builder.app do
      map '/text' do
        run TextApi
      end

      map '/slack' do
        run SlackApi
      end

      map '/github' do
        run GithubApi
      end

      map '/status' do
        run StatusApi
      end
    end
  end
end
