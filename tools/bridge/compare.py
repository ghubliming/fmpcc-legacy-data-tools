"""Old result file vs new result file of the same configuration (reading rule of CONCEPT §5.5): decisions must
agree exactly, trajectories within floating-point drift, accumulated quantities loosely; time is information.

python compare.py --env avoiding --old <old>/results/halfspace_both-hard/dpcc-t-tightened.npz \
                  --new <new>/eval/<label>/both_hard/seed_6/per_step_temporal_consistency_tightened.npz
"""
import argparse

import numpy as np

PAIRS = {
    'avoiding': {'exact': [('n_success', 'success'), ('n_success_and_constraints', 'success_and_constraints'),
                           ('n_steps', 'control_steps'), ('n_violations', 'violating_steps'),
                           ('collision_free_completed', 'constraint_satisfied')],
                 'loose': [('total_violations', 'total_violation')],
                 'info': [('avg_time', 'time_per_step')],
                 'paths': [('obs_all', 'observations', None), ('act_all', 'actions', None)]},
    'aligning': {'exact': [('n_success', 'success'), ('success_relaxed', 'in_position'), ('n_steps', 'control_steps'),
                           ('constraint_exec_n_violated_steps', 'violating_steps'),
                           ('constraint_exec_zero_violation', 'violation_free')],
                 'loose': [('mean_distance', 'mean_distance')],
                 'info': [('avg_time', 'time_per_step')],
                 'paths': [('obs_all', 'observations', slice(3, 6)), ('act_all', 'commands', None)]},
    'uav': {'exact': [('success_relaxed', 'finish'), ('success_relaxed_and_constraints', 'finish_and_constraints'),
                      ('success_strict', 'goal_reached'), ('phys_safe', 'safe'), ('n_steps', 'control_steps'),
                      ('constraint_n_violations', 'violating_steps'), ('constraint_collision_free', 'violation_free')],
            'loose': [('constraint_total_violations', 'total_violation'), ('goal_dist', 'goal_distance'),
                      ('phys_contact_frac', 'contact_fraction')],
            'info': [],
            'paths': [('obs_all', 'observations', None), ('act_all', 'actions', None)]},
}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--env', required=True, choices=sorted(PAIRS))
    p.add_argument('--old', required=True)
    p.add_argument('--new', required=True)
    p.add_argument('--episodes', type=int, default=None, help='compare only the first N episodes / flights')
    p.add_argument('--drift', type=float, default=1e-5)
    args = p.parse_args()
    old, new = np.load(args.old, allow_pickle=True), np.load(args.new, allow_pickle=True)
    rules = PAIRS[args.env]
    n = args.episodes or min(len(np.atleast_1d(old[rules['exact'][0][0]])), len(np.atleast_1d(new[rules['exact'][0][1]])))
    verdict = True
    for o, k in rules['exact']:
        a, b = np.asarray(old[o], dtype=float)[:n], np.asarray(new[k], dtype=float)[:n]
        same = np.array_equal(a, b)
        verdict &= same
        print(f'{"==" if same else "!!"} {o:>34s} | {k:<24s} old {a.tolist()}  new {b.tolist()}')
    for o, k in rules['loose']:
        a, b = np.asarray(old[o], dtype=float)[:n], np.asarray(new[k], dtype=float)[:n]
        print(f'~~ {o:>34s} | {k:<24s} max |diff| {np.max(np.abs(a - b)) if a.size else 0:.3e}')
    for o, k in rules['info']:
        a, b = np.asarray(old[o], dtype=float)[:n], np.asarray(new[k], dtype=float)[:n]
        print(f'.. {o:>34s} | {k:<24s} mean old {a.mean():.4f}  new {b.mean():.4f}')
    for o, k, cols in rules['paths']:
        worst = 0.0
        for i in range(n):
            a, b = np.asarray(old[o][i], dtype=float), np.asarray(new[k][i], dtype=float)
            a = a[:, cols] if cols is not None else a
            if a.shape != b.shape:
                print(f'!! {o} episode {i}: shapes {a.shape} vs {b.shape}')
                verdict = False
                continue
            worst = max(worst, float(np.max(np.abs(a - b))) if a.size else 0.0)
        ok = worst <= args.drift
        verdict &= ok
        print(f'{"==" if ok else "!!"} {o:>34s} | {k:<24s} max |diff| over {n} episodes {worst:.3e}')
    print('AGREE' if verdict else 'DIFFER')


if __name__ == '__main__':
    main()
