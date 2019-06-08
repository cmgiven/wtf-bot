# wtf-bot

Slack/Microsoft Teams bot to look up acronym definitions. Inspired by [@paultag](https://github.com/paultag/wtf).

For a more robust and easier-to-deploy tool, check out [glossary-bot](https://github.com/codeforamerica/glossary-bot). The advantages of wtf-bot are that it is less expensive (pennies or less) to deploy and that it is backed by an acronym dictionary stored in a Git repository.

## Install

You'll first need to install [Node](https://nodejs.org/en/download/package-manager/) and [Docker](https://docs.docker.com/install/). Then run:

```sh
npm install
cp .env-default .env
```

Edit `.env` to point to your acronym dictionary on GitHub. Here's an [example dictionary](https://github.com/department-of-veterans-affairs/acronyms).

## Try it out

### Slack

```sh
npm run slack '{"text": "[ACRONYM]"}'
```

## Deploy

You'll need to have configured a Lambda function with the name `wtf-bot` (documentation needed). Then, with [aws-cli](https://aws.amazon.com/cli/) installed, run:

```sh
npm run deploy
```

## Todo

* Add Microsoft Teams support
* Add the ability to define an acronym from within Slack/Teams
* Support using the Notes column in an acronym dictionary
