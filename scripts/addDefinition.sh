#!/bin/bash

# Adds a definition via command line

if [[ $# -lt 3 ]]
then
  echo "Usage:   $0 <dictionary> <acronym> <definition>"
  echo "Example: $0 default USDS US Digital Service"
  exit 1
fi

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

dictionary=$1
acronym=$2
definition=${@:3}

curl \
  --noproxy "*" \
  -X POST \
  -H "Authorization: Token ${TOKEN}" \
  --data-urlencode "definition=${definition}" \
  ${HOST}/text/${dictionary}/${acronym}
