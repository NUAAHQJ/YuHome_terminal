#!/usr/bin/env python3
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
MODEL = ROOT / 'entry/src/main/resources/rawfile/planner/action_planner_v1.json'
REPORT = ROOT / 'tools/planner/generated/training_report.json'


def main() -> None:
    model = json.loads(MODEL.read_text(encoding='utf-8'))
    report = json.loads(REPORT.read_text(encoding='utf-8'))
    assert model['schema_version'] == 1
    assert model['model_id'] == 'yuhome_action_planner_mlp'
    assert model['input_size'] == len(model['feature_names']) == 33
    assert model['output_size'] == 126
    assert [head['name'] for head in model['heads']] == [
        'living_light', 'bedroom_light', 'curtain', 'ac_power', 'ac_mode', 'ac_temperature'
    ]
    assert model['security']['excluded_output_categories'] == ['door_control', 'alarm_control']
    assert report['metrics']['exact_plan_accuracy'] >= 0.96
    assert report['metrics']['unsafe_output_heads'] == 0.0
    print(json.dumps({'exact_plan_accuracy': report['metrics']['exact_plan_accuracy'], 'ok': True}))


if __name__ == '__main__':
    main()
