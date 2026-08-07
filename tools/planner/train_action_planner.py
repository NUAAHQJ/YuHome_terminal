#!/usr/bin/env python3
"""Train the constrained multi-head DAYU action planner.

The dataset is intentionally structured: language and federated models provide a
canonical goal, while this model learns the desired multi-device end state from
that goal plus current local context. Security-sensitive devices are absent from
both labels and output heads.
"""

from __future__ import annotations

import argparse
import json
import math
import random
from dataclasses import asdict, dataclass
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset


GOALS = [
  'away', 'sleep', 'home', 'comfort_warmer', 'comfort_cooler',
  'light_on', 'light_off', 'curtain_open', 'curtain_close',
  'ac_on', 'ac_off', 'ac_temperature', 'ac_mode',
  'lighting_brighten_needed', 'lighting_reduce_needed',
  'thermal_cooler_needed', 'thermal_warmer_needed', 'away_candidate',
]
HEADS = [
    ('living_light', 3, ['no_change', 'on', 'off']),
    ('bedroom_light', 3, ['no_change', 'on', 'off']),
    ('curtain', 102, ['no_change'] + [str(value) for value in range(101)]),
    ('ac_power', 3, ['no_change', 'on', 'off']),
    ('ac_mode', 3, ['no_change', 'cool', 'heat']),
    ('ac_temperature', 12, ['no_change'] + [str(value) for value in range(20, 31)]),
]
FEATURE_NAMES = [f'goal_{goal}' for goal in GOALS] + [
    'source_federated', 'source_confidence', 'living_light_on', 'bedroom_light_on',
    'curtain_percent', 'ac_power', 'ac_mode_cool', 'ac_mode_heat', 'ac_temperature',
    'indoor_temperature', 'indoor_humidity', 'light_level', 'presence', 'away_mode',
    'preferred_temperature',
]


@dataclass
class State:
    living_light_on: bool
    bedroom_light_on: bool
    curtain_percent: int
    ac_power: bool
    ac_mode: str
    ac_temperature: int
    indoor_temperature: float
    indoor_humidity: float
    light_level: float
    presence: bool
    away_mode: bool
    preferred_temperature: int


def clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


def random_state(rng: random.Random) -> State:
    return State(
        living_light_on=rng.random() < 0.5,
        bedroom_light_on=rng.random() < 0.5,
        curtain_percent=rng.randrange(0, 101),
        ac_power=rng.random() < 0.55,
        ac_mode='cool' if rng.random() < 0.6 else 'heat',
        ac_temperature=rng.randrange(20, 31),
        indoor_temperature=round(rng.uniform(14.0, 33.0), 1),
        indoor_humidity=round(rng.uniform(25.0, 88.0), 1),
        light_level=round(rng.uniform(0.0, 650.0), 1),
        presence=rng.random() < 0.7,
        away_mode=rng.random() < 0.2,
        preferred_temperature=rng.randrange(22, 28),
    )


def features(goal: str, source_federated: bool, confidence: float, state: State) -> list[float]:
    values = [0.0] * len(FEATURE_NAMES)
    values[GOALS.index(goal)] = 1.0
    offset = len(GOALS)
    values[offset] = 1.0 if source_federated else 0.0
    values[offset + 1] = confidence
    values[offset + 2] = 1.0 if state.living_light_on else 0.0
    values[offset + 3] = 1.0 if state.bedroom_light_on else 0.0
    values[offset + 4] = state.curtain_percent / 100.0
    values[offset + 5] = 1.0 if state.ac_power else 0.0
    values[offset + 6] = 1.0 if state.ac_mode == 'cool' else 0.0
    values[offset + 7] = 1.0 if state.ac_mode == 'heat' else 0.0
    values[offset + 8] = (state.ac_temperature - 16) / 14.0
    values[offset + 9] = max(0.0, min(1.0, (state.indoor_temperature - 10.0) / 30.0))
    values[offset + 10] = state.indoor_humidity / 100.0
    values[offset + 11] = max(0.0, min(1.0, state.light_level / 500.0))
    values[offset + 12] = 1.0 if state.presence else 0.0
    values[offset + 13] = 1.0 if state.away_mode else 0.0
    values[offset + 14] = (state.preferred_temperature - 16) / 14.0
    return values


def labels_for(goal: str, state: State) -> list[int]:
    living = 0
    bedroom = 0
    curtain = 0
    ac_power = 0
    ac_mode = 0
    ac_temperature = 0

    def set_living(on: bool) -> None:
        nonlocal living
        if state.living_light_on != on:
            living = 1 if on else 2

    def set_bedroom(on: bool) -> None:
        nonlocal bedroom
        if state.bedroom_light_on != on:
            bedroom = 1 if on else 2

    def set_curtain(percent: int) -> None:
        nonlocal curtain
        if state.curtain_percent != percent:
            curtain = percent + 1

    def set_ac(power: bool | None = None, mode: str | None = None, temperature: int | None = None) -> None:
        nonlocal ac_power, ac_mode, ac_temperature
        if power is not None and state.ac_power != power:
            ac_power = 1 if power else 2
        if mode is not None and state.ac_mode != mode:
            ac_mode = 1 if mode == 'cool' else 2
        if temperature is not None and state.ac_temperature != temperature:
            ac_temperature = temperature - 19

    if goal == 'away':
        set_living(False)
        set_bedroom(False)
        set_curtain(0)
        set_ac(power=False)
    elif goal == 'sleep':
        set_living(False)
        set_bedroom(False)
        set_curtain(0)
        if state.indoor_temperature >= 26.0:
            set_ac(power=True, mode='cool', temperature=state.preferred_temperature)
        elif state.indoor_temperature <= 20.0:
            set_ac(power=True, mode='heat', temperature=max(23, state.preferred_temperature))
        else:
            set_ac(power=False)
    elif goal == 'home':
        set_living(True)
        set_curtain(100)
        if state.indoor_temperature >= 28.0:
            set_ac(power=True, mode='cool', temperature=state.preferred_temperature)
        elif state.indoor_temperature <= 16.0:
            set_ac(power=True, mode='heat', temperature=max(23, state.preferred_temperature))
    elif goal == 'comfort_warmer':
        set_ac(power=True, mode='heat', temperature=clamp(max(state.preferred_temperature,
            round(state.indoor_temperature + 2)), 20, 30))
    elif goal == 'comfort_cooler':
        set_ac(power=True, mode='cool', temperature=clamp(min(state.preferred_temperature,
            round(state.indoor_temperature - 2)), 20, 30))
    elif goal == 'light_on':
        set_living(True)
    elif goal == 'light_off':
        set_living(False)
    elif goal == 'curtain_open':
        set_curtain(100)
    elif goal == 'curtain_close':
        set_curtain(0)
    elif goal == 'ac_on':
        set_ac(power=True)
    elif goal == 'ac_off':
        set_ac(power=False)
    elif goal == 'ac_temperature':
        set_ac(temperature=state.preferred_temperature)
    elif goal == 'ac_mode':
        set_ac(mode='cool' if state.indoor_temperature >= 24.0 else 'heat')
    elif goal == 'lighting_brighten_needed':
        if state.curtain_percent < 80:
            set_curtain(100)
        else:
            set_living(True)
    elif goal == 'lighting_reduce_needed':
        if state.curtain_percent > 20:
            set_curtain(0)
        else:
            set_living(False)
    elif goal == 'thermal_cooler_needed':
        set_ac(power=True, mode='cool', temperature=clamp(min(state.preferred_temperature,
            round(state.indoor_temperature - 2)), 20, 30))
    elif goal == 'thermal_warmer_needed':
        set_ac(power=True, mode='heat', temperature=clamp(max(state.preferred_temperature,
            round(state.indoor_temperature + 2)), 20, 30))
    elif goal == 'away_candidate':
        set_living(False)
        set_bedroom(False)
        set_curtain(0)
        set_ac(power=False)
    else:
        raise ValueError(goal)
    return [living, bedroom, curtain, ac_power, ac_mode, ac_temperature]


class ActionPlanner(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.network = nn.Sequential(
            nn.Linear(len(FEATURE_NAMES), 128),
            nn.ReLU(),
            nn.Linear(128, 128),
            nn.ReLU(),
            nn.Linear(128, sum(size for _, size, _ in HEADS)),
        )

    def forward(self, value: torch.Tensor) -> torch.Tensor:
        return self.network(value)


def build_dataset(samples: int, seed: int) -> tuple[torch.Tensor, torch.Tensor, list[dict[str, object]]]:
    rng = random.Random(seed)
    rows: list[dict[str, object]] = []
    feature_rows: list[list[float]] = []
    label_rows: list[list[int]] = []
    for _ in range(samples):
        goal = rng.choice(GOALS)
        source_federated = goal in {'lighting_brighten_needed', 'lighting_reduce_needed',
            'thermal_cooler_needed', 'thermal_warmer_needed', 'away_candidate'}
        confidence = round(rng.uniform(0.65, 0.99) if source_federated else 1.0, 4)
        state = random_state(rng)
        feature_row = features(goal, source_federated, confidence, state)
        label_row = labels_for(goal, state)
        feature_rows.append(feature_row)
        label_rows.append(label_row)
        rows.append({
            'goal': goal,
            'source': 'federated' if source_federated else 'voice',
            'confidence': confidence,
            'state': asdict(state),
            'targets': dict(zip([name for name, _, _ in HEADS], label_row)),
        })
    return torch.tensor(feature_rows, dtype=torch.float32), torch.tensor(label_rows, dtype=torch.long), rows


def loss_for(logits: torch.Tensor, labels: torch.Tensor) -> torch.Tensor:
    losses: list[torch.Tensor] = []
    offset = 0
    # Penalize spurious device actions more strongly than a no-op prediction.
    weights = [1.5, 1.5, 1.0, 1.8, 1.2, 1.2]
    for index, (_, size, _) in enumerate(HEADS):
        losses.append(weights[index] * nn.functional.cross_entropy(logits[:, offset:offset + size], labels[:, index]))
        offset += size
    return sum(losses)


def evaluate(model: ActionPlanner, features_value: torch.Tensor, labels: torch.Tensor,
             device: torch.device) -> dict[str, float]:
    model.eval()
    with torch.inference_mode():
        logits = model(features_value.to(device)).cpu()
    offset = 0
    predictions: list[torch.Tensor] = []
    metrics: dict[str, float] = {}
    for index, (name, size, _) in enumerate(HEADS):
        predicted = logits[:, offset:offset + size].argmax(dim=1)
        predictions.append(predicted)
        metrics[f'{name}_accuracy'] = float((predicted == labels[:, index]).float().mean().item())
        offset += size
    matrix = torch.stack(predictions, dim=1)
    metrics['exact_plan_accuracy'] = float((matrix == labels).all(dim=1).float().mean().item())
    metrics['unsafe_output_heads'] = 0.0
    return metrics


def model_package(model: ActionPlanner, metrics: dict[str, float], seed: int) -> dict[str, object]:
    linear_layers = [layer for layer in model.network if isinstance(layer, nn.Linear)]
    layers = []
    for layer in linear_layers:
        layers.append({
            'weight': layer.weight.detach().cpu().tolist(),
            'bias': layer.bias.detach().cpu().tolist(),
        })
    heads = []
    offset = 0
    for name, size, labels in HEADS:
        heads.append({'name': name, 'offset': offset, 'size': size, 'labels': labels})
        offset += size
    return {
        'schema_version': 1,
        'model_id': 'yuhome_action_planner_mlp',
        'version': 1,
        'training_seed': seed,
        'feature_names': FEATURE_NAMES,
        'input_size': len(FEATURE_NAMES),
        'output_size': offset,
        'layers': layers,
        'heads': heads,
        'metrics': metrics,
        'security': {
            'excluded_output_categories': ['door_control', 'alarm_control'],
            'allowed_write_tools': ['light.set', 'curtain.set', 'ac.set'],
        },
    }


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', encoding='utf-8') as output:
        for row in rows:
            output.write(json.dumps(row, ensure_ascii=False, separators=(',', ':')))
            output.write('\n')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--samples', type=int, default=40000)
    parser.add_argument('--epochs', type=int, default=180)
    parser.add_argument('--batch-size', type=int, default=512)
    parser.add_argument('--seed', type=int, default=20260803)
    parser.add_argument('--output', type=Path, default=Path('entry/src/main/resources/rawfile/planner/action_planner_v1.json'))
    parser.add_argument('--report', type=Path, default=Path('tools/planner/generated/training_report.json'))
    parser.add_argument('--dataset', type=Path, default=Path('tools/planner/data/action_planner_v1.jsonl'))
    args = parser.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    all_features, all_labels, rows = build_dataset(args.samples, args.seed)
    validation_count = max(1000, args.samples // 10)
    test_count = max(1000, args.samples // 10)
    train_count = args.samples - validation_count - test_count
    train_features, validation_features, test_features = torch.split(
        all_features, [train_count, validation_count, test_count])
    train_labels, validation_labels, test_labels = torch.split(
        all_labels, [train_count, validation_count, test_count])
    model = ActionPlanner().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=3e-3, weight_decay=1e-4)
    loader = DataLoader(TensorDataset(train_features, train_labels), batch_size=args.batch_size, shuffle=True)
    best_state: dict[str, torch.Tensor] | None = None
    best_exact = -1.0
    history: list[dict[str, float]] = []
    for epoch in range(1, args.epochs + 1):
        model.train()
        epoch_loss = 0.0
        for batch_features, batch_labels in loader:
            optimizer.zero_grad()
            logits = model(batch_features.to(device))
            loss = loss_for(logits, batch_labels.to(device))
            loss.backward()
            optimizer.step()
            epoch_loss += float(loss.item())
        validation_metrics = evaluate(model, validation_features, validation_labels, device)
        history.append({'epoch': float(epoch), 'loss': epoch_loss / max(1, len(loader)),
                        'validation_exact_plan_accuracy': validation_metrics['exact_plan_accuracy']})
        if validation_metrics['exact_plan_accuracy'] > best_exact:
            best_exact = validation_metrics['exact_plan_accuracy']
            best_state = {name: value.detach().cpu().clone() for name, value in model.state_dict().items()}
    if best_state is None:
        raise RuntimeError('training did not produce a model')
    model.load_state_dict(best_state)
    test_metrics = evaluate(model, test_features, test_labels, device)
    if test_metrics['exact_plan_accuracy'] < 0.96:
        raise RuntimeError(f"planner exact plan accuracy too low: {test_metrics['exact_plan_accuracy']:.4f}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    package = model_package(model, test_metrics, args.seed)
    args.output.write_text(json.dumps(package, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    write_jsonl(args.dataset, rows)
    report = {
        'device': str(device),
        'samples': args.samples,
        'train_samples': train_count,
        'validation_samples': validation_count,
        'test_samples': test_count,
        'epochs': args.epochs,
        'seed': args.seed,
        'metrics': test_metrics,
        'history': history,
        'model_path': str(args.output),
        'dataset_path': str(args.dataset),
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'device': str(device), 'metrics': test_metrics, 'model': str(args.output)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
