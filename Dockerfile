FROM ruby:2.7.2-alpine

RUN mkdir /app
WORKDIR /app

COPY \
  config.ru \
  Gemfile \
  Gemfile.lock \
  /app

RUN bundle install

COPY \
  config.ru \
  start.sh \
  /app

COPY src/ /app/src/

CMD RUBYOPT=-W:no-deprecated \
  bundle exec rackup config.ru \
    -o ${HOST} \
    -p ${PORT}
