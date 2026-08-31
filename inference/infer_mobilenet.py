#!/usr/bin/env python3
# End-to-end NPU inference demo: MobileNet-V2 ImageNet classification.
#
# Loads a CixBuilder-compiled .cix graph, runs one image through the NPU via
# libnoe (/dev/aipu -> aipu.ko), prints the top-5 ImageNet classes.
#
# Preprocessing matches ai_model_hub's imagenet_transforms: resize shorter
# side to 256, center-crop 224, /255, normalise (ImageNet mean/std), NCHW.
import argparse
import time

import numpy as np
from PIL import Image

from NOE_Engine import EngineInfer
from imagenet_classes import id2class

MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


def preprocess(path, size=224):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    short = size + 32
    if w <= h:
        nw, nh = short, round(h * short / w)
    else:
        nw, nh = round(w * short / h), short
    img = img.resize((nw, nh), Image.BILINEAR)
    left, top = (nw - size) // 2, (nh - size) // 2
    img = img.crop((left, top, left + size, top + size))
    x = np.asarray(img, dtype=np.float32) / 255.0
    x = (x - MEAN) / STD
    x = x.transpose(2, 0, 1)[None]  # 1x3x224x224
    return np.ascontiguousarray(x, dtype=np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--image", required=True)
    ap.add_argument("--runs", type=int, default=10, help="timed repeats")
    args = ap.parse_args()

    x = preprocess(args.image)
    engine = EngineInfer(args.model)
    try:
        logits = engine.forward(x)[0].reshape(-1)
        top5 = np.argsort(logits)[::-1][:5]

        print(f"\nimage: {args.image}")
        for rank, idx in enumerate(top5, 1):
            label = id2class.get(int(idx), f"<class {int(idx)}>")
            print(f"  {rank}. [{idx:3d}] {label}   ({logits[idx]:.3f})")

        if args.runs > 0:
            # Exclude the classification pass above (cold start) from the
            # averages: snapshot the engine's cumulative NPU counters and
            # measure only the deltas over the timed loop.
            npu_acc0, npu_cnt0 = engine._acc_time, engine._cnt_time
            t0 = time.perf_counter()
            for _ in range(args.runs):
                engine.forward(x)
            e2e_ms = (time.perf_counter() - t0) / args.runs * 1000
            # engine tracks the noe_job_infer_sync span only (NPU compute)
            npu_ms = (engine._acc_time - npu_acc0) / (engine._cnt_time - npu_cnt0) * 1000
            print(f"\n{args.runs} runs:  NPU compute {npu_ms:.2f} ms/inf   "
                  f"end-to-end forward() {e2e_ms:.2f} ms/inf")
    finally:
        engine.clean()


if __name__ == "__main__":
    main()
