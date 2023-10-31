FROM ruby:2.7.2-alpine

RUN mkdir /app
WORKDIR /app

COPY \
  config.ru \
  Gemfile \
  Gemfile.lock \
  /app

COPY src/ /app/src/

RUN bundle install

CMD RUBYOPT=-W:no-deprecated bundle exec rackup config.ru -o 0.0.0.0 -p 5000
