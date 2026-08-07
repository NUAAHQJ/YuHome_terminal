'use strict'

const fs = require('fs')
const path = require('path')

if (process.argv.length !== 4) {
  throw new Error('usage: node test_runtime_intent_parser.js <compiled-parser.js> <data-dir>')
}

const parserModule = require(path.resolve(process.argv[2]))
const parser = new parserModule.VoiceIntentParser()
const dataDir = path.resolve(process.argv[3])
const splits = ['train', 'validation', 'test', 'asr_noise_test', 'boundary_test', 'safety_adversarial_test']
const runtimeType = {
  ac_power_set: 'ac_set'
}
let rows = 0
let hardRuleChecks = 0
let modelContractChecks = 0
let fallbackRegressionChecks = 0
const errors = []

for (const split of splits) {
  const lines = fs.readFileSync(path.join(dataDir, `${split}.jsonl`), 'utf8').trim().split(/\r?\n/)
  for (const line of lines) {
    const row = JSON.parse(line)
    rows += 1
    const hard = parser.parseHardRule(row.text)
    const actualHard = hard === null ? null : hard.type
    const expectedType = row.slot_valid ? (runtimeType[row.intent] ?? row.intent) : 'unknown'
    if (row.hard_rule_expected !== null && actualHard !== row.hard_rule_expected) {
      errors.push(`${row.id} hard expected=${row.hard_rule_expected} actual=${actualHard} text=${row.text}`)
    } else if (row.hard_rule_expected === null && actualHard !== null && actualHard !== expectedType) {
      errors.push(`${row.id} hard changed intent expected=${expectedType} actual=${actualHard} text=${row.text}`)
    }
    hardRuleChecks += 1
    if (row.route !== 'in_domain' || hard !== null) {
      continue
    }
    const intent = parser.parseModelLabel(row.text, row.intent)
    if (intent.type !== expectedType) {
      errors.push(`${row.id} intent expected=${expectedType} actual=${intent.type} text=${row.text}`)
      continue
    }
    if (!row.slot_valid) {
      modelContractChecks += 1
      continue
    }
    if (row.intent === 'light_set' || row.intent === 'ac_power_set') {
      if (intent.power !== row.slots.power) {
        errors.push(`${row.id} power expected=${row.slots.power} actual=${intent.power}`)
      }
    } else if (row.intent === 'curtain_set' && intent.percentage !== row.slots.percentage) {
      errors.push(`${row.id} percentage expected=${row.slots.percentage} actual=${intent.percentage}`)
    } else if (row.intent === 'ac_temperature_set' && intent.temperature !== row.slots.temperature) {
      errors.push(`${row.id} temperature expected=${row.slots.temperature} actual=${intent.temperature}`)
    } else if (row.intent === 'ac_mode_set' && intent.mode !== row.slots.mode) {
      errors.push(`${row.id} mode expected=${row.slots.mode} actual=${intent.mode}`)
    }
    modelContractChecks += 1
  }
}

const fallbackRegressions = [
  { text: '\u4f60\u5e2e\u6211\u628a\u706f\u6253\u5f00', type: 'light_set', power: true },
  { text: '\u73b0\u5728\u706f\u662f\u5f00\u7740\u7684\u5417', type: 'light_status_query' }
]
for (const regression of fallbackRegressions) {
  const intent = parser.parse(regression.text)
  if (intent.type !== regression.type ||
    (regression.power !== undefined && intent.power !== regression.power)) {
    errors.push(`fallback expected=${regression.type} actual=${intent.type} text=${regression.text}`)
  }
  fallbackRegressionChecks += 1
}

console.log(JSON.stringify({ rows, hardRuleChecks, modelContractChecks, fallbackRegressionChecks,
  errors: errors.length }))
if (errors.length > 0) {
  console.error(errors.slice(0, 30).join('\n'))
  process.exit(1)
}
