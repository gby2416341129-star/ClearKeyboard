"""Validate the exported graph on macOS CPU. This is not an iPhone/ANE benchmark."""
import json
from pathlib import Path
import numpy as np
import coremltools as ct

ROOT=Path(__file__).resolve().parents[1]

def validate():
    reference=json.loads((ROOT/'Data/Rime/coreml25m-validation.json').read_text(encoding='utf8'))
    model=ct.models.MLModel(str(ROOT/'.rime-cache/ClearSentence25M.mlmodel'),compute_units=ct.ComputeUnit.CPU_ONLY)
    inputs={name:np.array(values,dtype=np.float32) for name,values in reference['inputs'].items()}
    actual=model.predict(inputs)['log_probs']
    assert actual.shape==(8,12288) and np.isfinite(actual).all()
    assert np.max(np.abs(np.exp(actual).sum(axis=1)-1))<0.001
    errors=[abs(float(actual[row['row'],row['token']])-row['value']) for row in reference['expected']]
    assert max(errors)<0.025,max(errors)
    result=dict(status='passed',backend='macOS Core ML CPU_ONLY',sampledValues=len(errors),
                maximumSampleError=max(errors),iPhoneRuntimeTested=False,ANEPlacementVerified=False)
    (ROOT/'.rime-cache/coreml25-validation-result.json').write_text(json.dumps(result,indent=2),encoding='utf8')
    print(json.dumps(result),flush=True)
    return result

if __name__=='__main__':validate()
