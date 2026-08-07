# DAYU action planner

The planner is a small multi-head MLP that maps a canonical goal plus local
device and environment state to a desired multi-device end state. It has no
door or alarm control head. The ArkTS safety gate only compiles light, curtain,
and AC calls from the result.

Train and package the current artifact:

```powershell
python tools/planner/train_action_planner.py
python tools/planner/tests/test_action_planner_artifact.py
```

The training script creates synthetic bootstrap data from documented scene
rules. Real accepted/rejected plans should be appended in a later training
cycle before claiming personalized planning quality.
