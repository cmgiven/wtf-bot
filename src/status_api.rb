require_relative 'base'

class StatusApi < Base
  get '/?' do
    'OK'
  end
end
