#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

import torch
import torchaudio


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seed', type=int, default=20260802)
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--dayu-gain-db', type=float, default=-4.0)
    parser.add_argument('--dayu-sample-rate', type=int, default=48000)
    parser.add_argument('--prompt-id', action='append', default=[])
    args = parser.parse_args()

    repo = args.repo.resolve()
    sys.path.insert(0, str(repo))
    sys.path.insert(0, str(repo / 'third_party' / 'Matcha-TTS'))

    from cosyvoice.cli.cosyvoice import CosyVoice2

    with args.manifest.open('r', encoding='utf-8') as source:
        manifest = json.load(source)

    native_dir = args.output / 'native'
    dayu_dir = args.output / 'dayu'
    native_dir.mkdir(parents=True, exist_ok=True)
    dayu_dir.mkdir(parents=True, exist_ok=True)

    reference = manifest['reference']
    reference_audio = (args.manifest.parent / reference['audio']).resolve()
    if not reference_audio.is_file():
        raise FileNotFoundError(reference_audio)

    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)

    model = CosyVoice2(
        str(args.model.resolve()),
        load_jit=False,
        load_trt=False,
        load_vllm=False,
        fp16=torch.cuda.is_available(),
    )

    report = {
        'voiceId': manifest['voiceId'],
        'model': str(args.model.resolve()),
        'referenceAudio': str(reference_audio),
        'referenceSha256': sha256(reference_audio),
        'sampleRateNative': model.sample_rate,
        'sampleRateDayu': args.dayu_sample_rate,
        'seed': args.seed,
        'dayuGainDb': args.dayu_gain_db,
        'cuda': torch.cuda.is_available(),
        'outputs': [],
    }

    selected_outputs = manifest['outputs']
    if args.prompt_id:
        selected_ids = set(args.prompt_id)
        selected_outputs = [item for item in manifest['outputs'] if item['id'] in selected_ids]
        missing_ids = selected_ids - {item['id'] for item in selected_outputs}
        if missing_ids:
            raise ValueError(f'Unknown prompt IDs: {sorted(missing_ids)}')

    progress_path = args.output / 'generation_progress.jsonl'
    total = len(selected_outputs)
    for index, item in enumerate(selected_outputs, start=1):
        native_path = native_dir / item['file']
        dayu_path = dayu_dir / item['file']
        native_path.parent.mkdir(parents=True, exist_ok=True)
        dayu_path.parent.mkdir(parents=True, exist_ok=True)

        if args.resume and native_path.is_file() and dayu_path.is_file():
            waveform, saved_rate = torchaudio.load(str(native_path))
            if saved_rate != model.sample_rate:
                raise RuntimeError(f'Unexpected sample rate in {native_path}: {saved_rate}')
            status = 'SKIPPED'
        else:
            chunks = []
            for result in model.inference_zero_shot(
                item['text'],
                reference['text'],
                str(reference_audio),
                stream=False,
                speed=1.0,
            ):
                chunks.append(result['tts_speech'].detach().cpu())
            if not chunks:
                raise RuntimeError(f"No audio generated for {item['id']}")

            waveform = torch.cat(chunks, dim=1)
            torchaudio.save(
                str(native_path), waveform, model.sample_rate,
                encoding='PCM_S', bits_per_sample=16,
            )

            dayu_gain = 10 ** (args.dayu_gain_db / 20)
            dayu_source = waveform * dayu_gain
            dayu_waveform = torchaudio.functional.resample(
                dayu_source, model.sample_rate, args.dayu_sample_rate,
            )
            torchaudio.save(
                str(dayu_path), dayu_waveform, args.dayu_sample_rate,
                encoding='PCM_S', bits_per_sample=16,
            )
            status = 'GENERATED'

        rms = math.sqrt(float(torch.mean(waveform.float() ** 2)))
        output_report = {
            'id': item['id'],
            'text': item['text'],
            'nativeFile': str(native_path),
            'dayuFile': str(dayu_path),
            'durationSeconds': round(waveform.shape[1] / model.sample_rate, 3),
            'peak': round(float(torch.max(torch.abs(waveform))), 6),
            'rms': round(rms, 6),
            'nativeSha256': sha256(native_path),
            'dayuSha256': sha256(dayu_path),
        }
        report['outputs'].append(output_report)
        with progress_path.open('a', encoding='utf-8') as progress:
            progress.write(json.dumps({
                'index': index,
                'total': total,
                'status': status,
                **output_report,
            }, ensure_ascii=False) + '\n')
        print(f"{status} {index}/{total} {item['id']} duration={output_report['durationSeconds']}s", flush=True)

    if torch.cuda.is_available():
        report['maxCudaMemoryMiB'] = round(torch.cuda.max_memory_allocated() / (1024 ** 2), 1)

    report_path = args.output / 'generation_report.json'
    with report_path.open('w', encoding='utf-8') as target:
        json.dump(report, target, ensure_ascii=False, indent=2)
        target.write('\n')
    print(f'REPORT {report_path}')


if __name__ == '__main__':
    main()
