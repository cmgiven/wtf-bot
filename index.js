const got = require('got')
const { csvParse } = require('d3-dsv')

require('dotenv').config()
const { RAW_URL, LINK_URL } = process.env

const templates = {
  success: function ({ defs }) {
    const text = defs.map(o => `*${o.Title}*\t${o.Meaning}`).join('\n')
    return { response_type: 'ephemeral', text }
  },
  notFound: function ({ query }) {
    return {
      response_type: 'ephemeral',
      blocks: [
        {
          type: 'section',
          text: {
            type: 'plain_text',
            text: `No definition found for ${query}.`
          },
          accessory: {
            type: 'button',
            text: {
              type: 'plain_text',
              text: 'Add a definition'
            },
            url: LINK_URL
          }
        }
      ]
    }
  },
  error: function () {
    return {
      response_type: 'ephemeral',
      text: 'Sorry, wtf-bot stumbled across a paticularly nasty acronym and needs some time to recover. Please try again later.'
    }
  }
}

exports.handler = async function (event, context) {
  const query = event.text
  const promise = new Promise(function (resolve, reject) {
    got(RAW_URL).then(response => {
      const dict = csvParse(response.body)
      const defs = dict.filter(o => o.Title.toLowerCase() === query.toLowerCase())
      if (defs.length > 0) {
        resolve(templates.success({ defs }))
      } else {
        resolve(templates.notFound({ query }))
      }
    }).catch(e => {
      resolve(templates.error())
    })
  })
  return promise
}
