#!/bin/bash

npm install
rm -f wtf-bot.zip
zip -r wtf-bot.zip . -x "*.git*"
aws lambda update-function-code --function-name wtf-bot --zip-file fileb://wtf-bot.zip
