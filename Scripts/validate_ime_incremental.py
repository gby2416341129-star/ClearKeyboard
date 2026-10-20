"""Execute incremental Core ML on macOS CPU; compare with the full graph.

The timings cover a model prediction only. They do not measure the iPhone,
Neural Engine placement, battery consumption, or touch/host/UI latency.
"""
import json, statistics, time
from pathlib import Path
import numpy as np
import coremltools as ct

ROOT=Path(__file__).resolve().parents[1]


def validate():
    fixture=json.loads((ROOT/'Data/Rime/coreml25m-incremental-validation.json').read_text(encoding='utf8'))
    assert fixture['format']=='clear-kv-v1' and len(fixture['expected'])>=200
    model=ct.models.MLModel(str(ROOT/'.rime-cache/ClearSentence25M.mlmodel'),compute_units=ct.ComputeUnit.CPU_ONLY)
    baseline=ct.models.MLModel(str(ROOT/'.rime-cache/ClearSentence25M-full.mlmodel'),compute_units=ct.ComputeUnit.CPU_ONLY)
    vocab=json.loads(model.user_defined_metadata['vocab']);ids={v:i for i,v in enumerate(vocab)}
    sequences=np.array([[2]+[ids[c] for c in text] for text in fixture['sequences']],dtype=np.int64)
    assert sequences.shape==(8,16)
    past_k=np.zeros((8,8,16,448),dtype=np.float32);past_v=np.zeros_like(past_k)
    errors=[];full_errors=[];same_argmax=True
    for step in range(16):
        write=np.zeros((8,16),dtype=np.float32);write[:,step]=1
        attention=np.full((8,16),-10000,dtype=np.float32);attention[:,:step+1]=0
        inputs=dict(tokens=sequences[:,step:step+1].astype(np.float32),
            positions=np.full((8,1),step,dtype=np.float32),past_k=past_k,past_v=past_v,
            write_mask=write,attention_mask=attention)
        result=model.predict(inputs)
        actual=result['log_probs']
        assert actual.shape==(8,12288) and np.isfinite(actual).all()
        assert result['new_k'].shape==result['new_v'].shape==(8,8,448)
        assert np.isfinite(result['new_k']).all() and np.isfinite(result['new_v']).all()
        assert np.max(np.abs(np.exp(actual).sum(axis=1)-1))<0.001
        for item in fixture['expected']:
            if item['step']==step:errors.append(abs(float(actual[item['row'],item['token']])-item['value']))
        if step in [1,8,15]:
            old_inputs=dict(tokens=sequences.astype(np.float32),
                positions=np.stack([np.arange(8),np.full(8,step)],axis=1).astype(np.float32))
            previous=baseline.predict(old_inputs)['log_probs']
            full_errors.append(float(np.max(np.abs(previous-actual))))
            same_argmax &= bool(np.array_equal(previous.argmax(axis=1),actual.argmax(axis=1)))
        for layer in range(8):
            past_k[layer,:,step,:]=result['new_k'][:,layer,:]
            past_v[layer,:,step,:]=result['new_v'][:,layer,:]
    assert len(errors)==len(fixture['expected']) and max(errors)<0.025
    assert max(full_errors)<0.025 and same_argmax,(full_errors,same_argmax)
    # The final prediction reads only the strict ancestors. Never add a new
    # key to a slot already containing that same position's state.
    past_k[:,:,15,:]=0;past_v[:,:,15,:]=0
    previous_times=[];step_times=[]
    for iteration in range(9):
        start=time.perf_counter();baseline.predict(old_inputs);old_ms=(time.perf_counter()-start)*1000
        start=time.perf_counter();model.predict(inputs);new_ms=(time.perf_counter()-start)*1000
        if iteration>=2:previous_times.append(old_ms);step_times.append(new_ms)
    result=dict(status='passed',backend='macOS Core ML CPU_ONLY',
        sampledValues=len(errors),maximumSampleError=max(errors),
        crossGraphValues=3*8*12288,maximumCrossGraphError=max(full_errors),sameArgmax=same_argmax,
        fullPrefixPredictionMS=previous_times,incrementalPredictionMS=step_times,
        modelPredictionMedianSpeedup=statistics.median(previous_times)/statistics.median(step_times),
        timingsExcludeSwiftStateAssembly=True,iPhoneRuntimeTested=False,ANEPlacementVerified=False)
    (ROOT/'.rime-cache/coreml25-incremental-result.json').write_text(json.dumps(result,indent=2),encoding='utf8')
    print(json.dumps(result),flush=True)
    return result


if __name__=='__main__':validate()
