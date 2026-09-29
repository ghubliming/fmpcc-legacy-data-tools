"""Old checkpoint (state_<best|step>.pt of a run of record) -> a run directory the release can evaluate.

Run from the root of the old repository (so the old aligning normaliser pickles unpickle), with the release
installed:  python <this>/convert.py --env avoiding --model meanfm --old <old run>/<seed> --which best \
                --data d3il/environments/dataset/data/avoiding/data --out logs_bridge/avoiding/meanfm --seed 6
"""
import argparse
import os
import pickle

import torch
import yaml

from fmpcc import config, models
from fmpcc.data.avoiding import load_episodes as avoiding_episodes
from fmpcc.data.normalizer import LimitsNormalizer, Normalizer
from fmpcc.data.uav import load_episodes as uav_episodes
from fmpcc.data.windows import PlanWindows

RELEASE = os.path.dirname(os.path.dirname(os.path.abspath(config.__file__)))
CAMERAS = ('agentview_image', 'in_hand_image')


def unet_prefix(sd):
    tops = [k[:-len('time_mlp.1.weight')] for k in sd if k.endswith('time_mlp.1.weight')
            and not any(s in k for s in ('downs.', 'ups.', 'mid_block'))]
    assert len(tops) == 1, tops
    return tops[0]


def remap(sd):
    """Old wrapper state dict -> {'network.*', 'encoder.encoders.<cam>.*'} of the release model."""
    prefix = unet_prefix(sd)
    out = {'network.' + k[len(prefix):]: v for k, v in sd.items() if k.startswith(prefix)}
    for k, v in sd.items():
        if 'obs_encoder.key_model_map.' not in k:
            continue
        cam, rest = k.split('obs_encoder.key_model_map.')[1].split('.', 1)
        if rest.startswith('backbone.nets.'):
            out[f'encoder.encoders.{cam}.backbone.' + rest[len('backbone.nets.'):]] = v
        elif rest.startswith('pool.'):
            out[f'encoder.encoders.{cam}.' + rest] = v
        elif rest.startswith('nets.3.'):
            out[f'encoder.encoders.{cam}.linear.' + rest[len('nets.3.'):]] = v
    return out


def normalizer(env, args, train_cfg):
    if env == 'avoiding':
        d = train_cfg['dataset']
        return PlanWindows(avoiding_episodes(args.data), d['horizon'], d['max_path_length']).raw_normalizer, 0
    if env == 'uav':
        d = train_cfg['dataset']
        w = PlanWindows(uav_episodes(args.data), d['horizon'], d['max_path_length'][args.scene])
        return w.raw_normalizer, w.goal_dim
    fields = {}
    for key, name in (('observations', 'obs_normalizer.pkl'), ('actions', 'act_normalizer.pkl')):
        with open(os.path.join(args.old, name), 'rb') as f:
            old = pickle.load(f)
        fields[key] = LimitsNormalizer(old.mins, old.maxs)
    return Normalizer(fields), 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--env', required=True, choices=['avoiding', 'aligning', 'uav'])
    p.add_argument('--model', required=True, choices=models.MODELS)
    p.add_argument('--old', required=True, help='old run directory of one seed (holds state_*.pt)')
    p.add_argument('--which', default='best', help='best | <step>')
    p.add_argument('--data', help='demonstrations (avoiding: the D3IL avoiding data dir; uav: the curated scene dir)')
    p.add_argument('--scene', default='corridor')
    p.add_argument('--out', required=True, help='new run directory; the checkpoint lands in <out>/seed_<seed>/')
    p.add_argument('--seed', type=int, required=True)
    args = p.parse_args()

    old = torch.load(os.path.join(args.old, f'state_{args.which}.pt'), map_location='cpu')
    train_cfg = config.select_model(config.load(os.path.join(RELEASE, 'configs', 'train', f'{args.env}.yaml')), args.model)
    train_cfg['seed'] = args.seed
    if args.env == 'uav':
        train_cfg['dataset']['scene'] = args.scene
    if args.model == 'diffusion':
        train_cfg['objective']['steps'] = int(old['model']['betas'].shape[0])
    norm, goal_dim = normalizer(args.env, args, train_cfg)
    obs_dim, act_dim = len(norm['observations'].mins), len(norm['actions'].mins)
    visual = args.env == 'aligning'
    net = models.build(args.model, train_cfg['objective'], obs_dim, act_dim, 8, goal_dim=goal_dim, visual=visual,
                       train_steps=int(train_cfg['training']['steps']))
    own = net.state_dict()
    for key in ('model', 'ema'):
        state = remap(old[key])
        missing = sorted(set(own) - set(state))
        assert all(m in ('loss_weights',) or not m.startswith(('network.', 'encoder.')) for m in missing), missing
        for m in missing:
            state[m] = own[m]
        if 'loss_fn.weights' in old[key] and 'loss_weights' in own:
            state['loss_weights'] = old[key]['loss_fn.weights']
        for b in ('betas', 'sqrt_alphas_cumprod', 'sqrt_one_minus_alphas_cumprod', 'sqrt_recip_alphas_cumprod',
                  'sqrt_recipm1_alphas_cumprod', 'posterior_log_variance_clipped', 'posterior_mean_coef1', 'posterior_mean_coef2'):
            if b in own and b in old[key]:
                assert torch.equal(own[b], old[key][b].to(own[b].dtype)), f'{b} differs from the run of record'
        net.load_state_dict(state, strict=True)
        old[key] = {k: v.clone() for k, v in net.state_dict().items()}
    seed_dir = os.path.join(args.out, f'seed_{args.seed}')
    os.makedirs(seed_dir, exist_ok=True)
    name = f'{int(args.which):06d}' if args.which.isdigit() else args.which
    torch.save({'step': old['step'], 'model': old['model'], 'ema': old['ema'], 'config': train_cfg,
                'model_name': args.model, 'observation_dim': obs_dim, 'action_dim': act_dim, 'goal_dim': goal_dim,
                'horizon': 8, 'visual': visual, 'normalizer': norm.state()},
               os.path.join(seed_dir, f'checkpoint_{name}.pt'))
    config.save(train_cfg, os.path.join(seed_dir, 'config.yaml'))
    print(f'converted {args.old}/state_{args.which}.pt (step {old["step"]}) -> {seed_dir}/checkpoint_{name}.pt '
          f'(goal_dim {goal_dim})')


if __name__ == '__main__':
    main()
