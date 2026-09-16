#!/usr/bin/env python3
"""Compare the baker against vendored DiVERE methods, without importing its application."""
import ast
import importlib.util
import json
from pathlib import Path
from typing import Optional, List, Tuple, Dict
import numpy as np

spec = importlib.util.spec_from_file_location('bake', Path(__file__).with_name('generate-divere-luts.py'))
bake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bake)
tree = ast.parse((bake.SOURCE/'math_ops.py').read_text())
names = {'_density_inversion_direct', '_linear_to_density_direct', '_apply_curves_pure_interpolation', '_density_to_linear_direct'}
methods = [n for cls in tree.body if isinstance(cls, ast.ClassDef) for n in cls.body if isinstance(n, ast.FunctionDef) and n.name in names]
assert len(methods) == 4
namespace = dict(np=np, Optional=Optional, List=List, Tuple=Tuple, Dict=Dict)
exec(compile(ast.Module(body=methods, type_ignores=[]), 'DiVERE reference methods', 'exec'),namespace)
Reference = type('Reference', (), {name:namespace[name] for name in names})
reference = Reference(); reference._LOG65536 = np.log10(65536.0)
inputs = np.random.default_rng(915).random((4096,1,3))
transmission = 10**(-inputs*2.048)
manifest = json.loads((bake.TARGET/"manifest.json").read_text())
report = {}
for name in bake.NAMES:
    curves = json.loads((bake.SOURCE/'curves'/f'{name}.json').read_text())['curves']
    item = next(item for item in manifest['luts'] if item['name'] == name)
    dmax = np.array(item['densityDmaxRGB'])
    for low,high in item['densityWindowRGB']:
        assert abs(high-low-2.048) < 1e-12
    assert np.max(np.abs(np.array(item['bakedGrayRGB'])-item['neutralTargetRGB'])) < 1e-9
    inverted = reference._density_inversion_direct(transmission, 1., dmax, .7)
    density = reference._linear_to_density_direct(inverted)
    curved = reference._apply_curves_pure_interpolation(density, curves['RGB'], {c.lower():curves[c] for c in 'RGB'})
    linear = reference._density_to_linear_direct(curved).reshape(-1,3)
    expected = np.clip(np.linalg.solve(bake.DST, (bake.SRC @ linear.T)).T,0,1)**(1/bake.GAMMA)
    actual = bake.evaluate(inputs.reshape(-1,3),curves,dmax)
    error = float(np.max(np.abs(expected-actual)))
    assert error < 1e-12, (name,error)
    report[name] = {'sourceMethodComparisonMax':error}
# ICC source and destination matrices already include white adaptation to D50.
assert np.max(np.abs(bake.SRC.sum(axis=1)-np.array([.9642,1,.8249]))) < 3e-5
assert np.max(np.abs(bake.DST.sum(axis=1)-np.array([.9642,1,.8249]))) < 5e-5
report['iccWhiteResidual'] = float(np.max(np.abs(bake.MATRIX @ np.ones(3)-1)))
(bake.TARGET/'reference-validation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
