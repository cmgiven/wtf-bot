#!/bin/bash

# Refresh all the dictionaries

if [[ -z ${HOST} ]]
then
  echo "HOST not set. Set HOST to the host for the app itself"
  exit 1
fi

if [[ -z ${TOKEN} ]]
then
  echo "TOKEN not set. Set TOKEN to the authorization token from settings.yml"
  exit 1
fi

curl \
  --noproxy "*" \
  -H "Authorization: Token ${TOKEN}" \
  ${HOST}/text/refresh
