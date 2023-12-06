#!/bin/bash

# Get a definition via command line

if [[ $# -lt 2 ]]
then
  echo "Usage:   $0 <dictionary> <acronym>"
  echo "Example: $0 default USDS"
  exit 1
fi

if [[ -z ${HOST} ]]
then
  echo "HOST not set. Set HOST to the host for the app itself"
  exit 1
fi

dictionary=$1
acronym=$2

curl \
  --noproxy "*" \
  ${HOST}/text/${dictionary}/${acronym}
