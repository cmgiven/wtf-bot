$stdout.sync = true

require 'rubygems'
require 'bundler'

Bundler.require

require './src/app'
run WtfBot.app
