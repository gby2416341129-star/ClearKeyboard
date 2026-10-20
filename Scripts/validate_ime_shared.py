"""Execute the shared functions on macOS CPU and compare pinned numerical data."""
import json,statistics,subprocess,time
from pathlib import Path
import numpy as np
import coremltools as ct

ROOT=Path(__file__).resolve().parents[1]

def validate():
    directory=ROOT/'.rime-cache/shared25m'
    asset=directory/'ClearSentence25M.mlpackage'
    fixture=json.loads((ROOT/'Data/Rime/coreml25m-incremental-validation.json').read_text(encoding='utf8'))
    references=json.loads((ROOT/'Tests/Evaluation/coreml-score-reference.json').read_text(encoding='utf8'))
    step=ct.models.MLModel(str(asset),compute_units=ct.ComputeUnit.CPU_ONLY,function_name='step')
    scorer=ct.models.MLModel(str(asset),compute_units=ct.ComputeUnit.CPU_ONLY,function_name='score')
    assert step.user_defined_metadata['source_sha256']==references['sourceSHA256']
    vocab=json.loads(step.user_defined_metadata['vocab']);ids={text:index for index,text in enumerate(vocab)}
    sequences=np.array([[2]+[ids[c] for c in text] for text in fixture['sequences']],dtype=np.int32)
    k=np.zeros((8,8,16,448),dtype=np.float32);v=np.zeros_like(k);errors=[]
    for position in range(16):
        write=np.zeros((8,16),dtype=np.float32);write[:,position]=1
        mask=np.full((8,16),-10000,dtype=np.float32);mask[:,:position+1]=0
        result=step.predict(dict(tokens=sequences[:,position:position+1].astype(np.float32),positions=np.full((8,1),position,dtype=np.float32),past_k=k,past_v=v,write_mask=write,attention_mask=mask))
        assert result['log_probs'].shape==(8,12288) and np.isfinite(result['log_probs']).all()
        assert np.max(np.abs(np.exp(result['log_probs']).sum(axis=1)-1))<0.001
        for item in fixture['expected']:
            if item['step']==position:errors.append(abs(float(result['log_probs'][item['row'],item['token']])-item['value']))
        assert result['new_k'].shape==result['new_v'].shape==(8,8,448)
        for layer in range(8):k[layer,:,position,:]=result['new_k'][:,layer,:];v[layer,:,position,:]=result['new_v'][:,layer,:]
    assert len(errors)==len(fixture['expected']) and max(errors)<0.025,(len(errors),max(errors))

    def inputs(texts):
        tokens=np.zeros((4,16),dtype=np.int32);targets=np.zeros_like(tokens);valid=np.zeros((4,16),dtype=np.float32)
        for row,text in enumerate(texts):
            values=[ids[c] for c in text];tokens[row,:len(values)]=[2]+values[:-1];targets[row,:len(values)]=values;valid[row,:len(values)]=1
        return dict(tokens=tokens,targets=targets,valid_mask=valid)
    texts=[row['text'] for row in references['rows'][:4]];data=inputs(texts)
    scores=scorer.predict(data)['mean_scores'];expected=np.array([row['score'] for row in references['rows'][:4]])
    score_error=float(np.max(np.abs(scores-expected)));assert score_error<0.025,(scores,expected)
    reversed_scores=scorer.predict(inputs(list(reversed(texts))))['mean_scores'];assert np.max(np.abs(reversed_scores-scores[::-1]))<0.0001
    partial=inputs([texts[row][:row+1] for row in range(4)]);original=scorer.predict(partial)['mean_scores']
    for row in range(4):
        partial['tokens'][row,row+1:]=ids['我'];partial['targets'][row,row+1:]=ids['你']
    altered=scorer.predict(partial)['mean_scores'];assert np.max(np.abs(original-altered))<0.0001
    zero=inputs([]);empty=scorer.predict(zero)['mean_scores'];assert np.isfinite(empty).all() and np.max(np.abs(empty))<0.0001
    paired_path=ROOT/'Tests/Evaluation/candidate-score-parity.json'
    paired=json.loads(paired_path.read_text(encoding='utf8'));paired_scores={};paired_error=0.0
    assert paired['sourceSHA256']==references['sourceSHA256']
    for start in range(0,len(paired['rows']),4):
        group=paired['rows'][start:start+4]
        predicted=scorer.predict(inputs([row['text'] for row in group]))['mean_scores']
        for row,score in zip(group,predicted):
            paired_scores[row['text']]=float(score);paired_error=max(paired_error,abs(float(score)-row['nativeMean']))
    assert paired_error<0.025,paired_error

    # Compare a complete cold candidate batch against causal state filling.
    # Same candidate-length workload and weights; existing step has eight lanes,
    # the shipping first-screen pool is capped at four. No phone/NPU timing claim.
    score_ms=[];causal_ms=[]
    for repeat in range(7):
        started=time.perf_counter();scorer.predict(data);full=(time.perf_counter()-started)*1000
        k.fill(0);v.fill(0);started=time.perf_counter()
        for position in range(15):
            write=np.zeros((8,16),dtype=np.float32);write[:,position]=1
            mask=np.full((8,16),-10000,dtype=np.float32);mask[:,:position+1]=0
            result=step.predict(dict(tokens=sequences[:,position:position+1].astype(np.float32),positions=np.full((8,1),position,dtype=np.float32),past_k=k,past_v=v,write_mask=write,attention_mask=mask))
            for layer in range(8):k[layer,:,position,:]=result['new_k'][:,layer,:];v[layer,:,position,:]=result['new_v'][:,layer,:]
        causal=(time.perf_counter()-started)*1000
        if repeat:score_ms.append(full);causal_ms.append(causal)
    report={'status':'passed','scope':'macOS real Core ML CPU_ONLY; no iOS runtime, physical phone, ANE placement or end-to-end input latency',
        'stepSamples':len(errors),'maximumStepError':max(errors),'scoreRows':4,'incrementalRows':8,'maximumScoreError':score_error,
        'rowPermutationIndependent':True,'causalPaddingInvariant':True,'zeroMaskFinite':True,
        'pairedScoreRows':len(paired_scores),'maximumPairedScoreError':paired_error,'pairedScores':paired_scores,
        'scoreFunctionCalls':1,'incrementalFunctionCalls':15,'scoreMS':score_ms,'causalMS':causal_ms,
        'predictionMedianSpeedup':statistics.median(causal_ms)/statistics.median(score_ms),
        'export':json.loads((directory/'export-result.json').read_text(encoding='utf8'))}
    (directory/'validation-result.json').write_text(json.dumps(report,indent=2),encoding='utf8');print(json.dumps(report),flush=True)
    return report

if __name__=='__main__':validate()
